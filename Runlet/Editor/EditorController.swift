import AppKit
import RunletLanguage

/// Owns one tab's native editor. The scroll view and text view are created once and kept
/// for the tab's lifetime, so undo history, selection, scroll position, and input-method
/// state survive SwiftUI updates and tab switches.
@MainActor
final class EditorController: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate, CodeTextViewDelegate {
    let scrollView: NSScrollView
    let textView: CodeTextView
    private let ruler: LineNumberRulerView
    private var theme = EditorTheme.resolve(dark: false)
    private var fontSize: CGFloat = 13
    private var highlightWork: DispatchWorkItem?
    private var bracketRanges: [NSRange] = []
    private var errorLineRange: NSRange?
    private var suppressCallbacks = false

    /// Called with the full text after every user or programmatic edit.
    var onTextChange: ((String) -> Void)?
    var onSelectionChange: ((NSRange) -> Void)?

    // Language service
    private var language: LanguageBinding?
    private let completion = CompletionPopup()
    private let hoverPopup = InfoPopup(identifier: "hover-popup")
    private let signaturePopup = InfoPopup(identifier: "signature-popup")
    private var completionTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var signatureTask: Task<Void, Never>?
    private var completionAnchor: Int?
    private var rawCompletionItems: [CompletionItem] = []
    private(set) var diagnostics: [(range: NSRange, diagnostic: LSPDiagnostic)] = []

    init(text: String, selection: NSRange) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.configureForCode()
        scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        super.init()
        textView.delegate = self
        textView.codeDelegate = self
        layoutManager.delegate = self
        textView.string = text
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        completion.onAccept = { [weak self] item in self?.accept(item) }
        completion.onSelectionChange = { [weak self] item in self?.resolveForDetail(item) }
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewGeometryChanged), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewGeometryChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        applySettings(EditorPreferences())
    }

    var text: String { textView.string }
    var selectedRange: NSRange { textView.selectedRange() }

    /// The selected text, or nil when the selection is empty.
    var selectedText: String? {
        let range = selectedRange
        guard range.length > 0 else { return nil }
        return (text as NSString).substring(with: range)
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: Settings

    private var preferences = EditorPreferences()

    func applySettings(_ preferences: EditorPreferences) {
        self.preferences = preferences
        let fontSize = preferences.fontSize
        let dark = preferences.dark
        self.fontSize = fontSize
        theme = EditorTheme.resolve(dark: dark)
        textView.tabWidth = preferences.tabWidth
        textView.insertSpaces = preferences.insertSpaces
        let font = EditorFonts.font(family: preferences.fontName, size: fontSize, ligatures: preferences.ligatures)
        let paragraph = NSMutableParagraphStyle()
        let characterWidth = ("m" as NSString).size(withAttributes: [.font: font]).width
        paragraph.defaultTabInterval = characterWidth * CGFloat(preferences.tabWidth)
        paragraph.tabStops = []
        paragraph.lineHeightMultiple = preferences.lineHeight
        // Wrapped lines break at word boundaries, like other code editors.
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: theme.text,
            .ligature: preferences.ligatures ? 1 : 0,
        ]
        textView.font = font
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = attributes
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.text
        textView.selectedTextAttributes = [.backgroundColor: dark ? NSColor(srgbRed: 0.25, green: 0.35, blue: 0.55, alpha: 1) : NSColor(srgbRed: 0.70, green: 0.82, blue: 1, alpha: 1)]
        scrollView.backgroundColor = theme.background
        ruler.theme = theme
        setSoftWrap(preferences.softWrap)
        highlightNow()
    }

    // MARK: Soft wrap

    /// The wrap mode the text view is configured for (reconfigured only when it changes,
    /// since unwrapping lays out the whole document to size the text view).
    private var appliedSoftWrap: Bool?

    /// Wraps long lines to the visible width (no horizontal scroller) or lets the text view
    /// grow horizontally. The ruler numbers logical lines either way.
    private func setSoftWrap(_ wrap: Bool) {
        guard let container = textView.textContainer else { return }
        guard wrap != appliedSoftWrap else {
            if wrap { fitTextViewToVisibleWidth() }
            return
        }
        appliedSoftWrap = wrap
        if wrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            fitTextViewToVisibleWidth()
            // Nothing is off to the side any more: scroll back to the leading edge, which is
            // at -contentInsets.left (the clip view extends under the line-number ruler).
            let clip = scrollView.contentView
            let leading = -clip.contentInsets.left
            if clip.bounds.origin.x != leading {
                clip.scroll(to: NSPoint(x: leading, y: clip.bounds.origin.y))
                scrollView.reflectScrolledClipView(clip)
            }
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            scrollView.hasHorizontalScroller = true
            textView.sizeToFit()
            if textView.frame.width < visibleWidth {
                textView.setFrameSize(NSSize(width: visibleWidth, height: textView.frame.height))
            }
        }
        ruler.needsDisplay = true
    }

    /// Width of the area that shows text: the clip view minus the insets for the ruler and
    /// overlay scrollers (macOS 26 scroll views extend the clip view under them).
    private var visibleWidth: CGFloat {
        let clip = scrollView.contentView
        return clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right
    }

    /// While wrapping, the text view (and so its container) is exactly as wide as the visible area.
    private func fitTextViewToVisibleWidth() {
        let width = visibleWidth
        guard width > 0, abs(textView.frame.width - width) > 0.5 else { return }
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
    }

    /// The clip view resized, or its insets changed (the ruler widens past 99 lines).
    @objc private func clipViewGeometryChanged(_ notification: Notification) {
        guard preferences.softWrap else { return }
        fitTextViewToVisibleWidth()
    }

    /// Characters that form PHP operators (`->`, `=>`, `::`, `!==`, `?->`, `<=>`, `**=`, `...`).
    private static let operatorCharacters = Set("-=>!<:?&|+*/%.^~".utf16)

    /// Soft wrap never splits an operator across lines (the default rules break after `-`,
    /// which turns `->` into `-` and `>` on separate rows).
    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        let string = (layoutManager.textStorage?.string ?? "") as NSString
        guard charIndex > 0, charIndex < string.length else { return true }
        let previous = string.character(at: charIndex - 1)
        let next = string.character(at: charIndex)
        return !(Self.operatorCharacters.contains(previous) && Self.operatorCharacters.contains(next))
    }

    // MARK: Programmatic edits (undoable, never execute code)

    func replaceAll(with newText: String) {
        textView.replace(range: NSRange(location: 0, length: (text as NSString).length), with: newText, selectAfter: NSRange(location: 0, length: 0))
    }

    func goTo(line: Int, column: Int = 1) {
        let index = TextLineIndex(text)
        let offset = index.offset(of: LSPPosition(line: max(0, line - 1), character: max(0, column - 1)))
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        focus()
    }

    /// Marks a 1-based editor line as the location of an execution error.
    func showExecutionError(line: Int?) {
        clearExecutionError()
        guard let line, let layoutManager = textView.layoutManager else { return }
        let index = TextLineIndex(text)
        let start = index.offset(of: LSPPosition(line: line - 1, character: 0))
        let range = (text as NSString).lineRange(for: NSRange(location: min(start, (text as NSString).length), length: 0))
        layoutManager.addTemporaryAttribute(.backgroundColor, value: theme.errorLine, forCharacterRange: range)
        errorLineRange = range
        ruler.executionErrorLine = line - 1
    }

    func clearExecutionError() {
        if let range = errorLineRange, let layoutManager = textView.layoutManager {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: (text as NSString).length))
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: clamped)
        }
        errorLineRange = nil
        ruler.executionErrorLine = nil
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        clearExecutionError()
        scheduleHighlight()
        language?.documentChanged(text)
        onTextChange?(text)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateBracketMatch()
        onSelectionChange?(selectedRange)
        if completion.isVisible, let anchor = completionAnchor, selectedRange.location < anchor {
            completion.hide()
        }
        if signaturePopup.isVisible, let open = enclosingOpenParen(), open < 0 {
            signaturePopup.hide()
        }
    }

    // MARK: Highlighting

    private func scheduleHighlight() {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlightNow() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    func highlightNow() {
        guard let layoutManager = textView.layoutManager else { return }
        let string = textView.string as NSString
        let full = NSRange(location: 0, length: string.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        for token in PHPHighlighter.tokenize(string) where NSMaxRange(token.range) <= string.length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: theme.color(for: token.kind), forCharacterRange: token.range)
        }
        applyDiagnosticDecorations()
    }

    private func updateBracketMatch() {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (text as NSString).length
        for range in bracketRanges where NSMaxRange(range) <= length && range != errorLineRange {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        bracketRanges = []
        if let errorLineRange, NSMaxRange(errorLineRange) <= length {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: theme.errorLine, forCharacterRange: errorLineRange)
        }
        let selection = selectedRange
        guard selection.length == 0, selection.location > 0 else { return }
        let characters = Array((text as NSString).substring(to: length).utf16)
        let index = selection.location - 1
        let pairs: [UInt16: (UInt16, Int)] = [40: (41, 1), 91: (93, 1), 123: (125, 1), 41: (40, -1), 93: (91, -1), 125: (123, -1)]
        guard index < characters.count, let (match, direction) = pairs[characters[index]] else { return }
        let open = characters[index]
        var depth = 0
        var cursor = index
        while cursor >= 0 && cursor < characters.count {
            if characters[cursor] == open { depth += 1 }
            if characters[cursor] == match { depth -= 1 }
            if depth == 0 {
                bracketRanges = [NSRange(location: index, length: 1), NSRange(location: cursor, length: 1)]
                for range in bracketRanges {
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: theme.bracketMatch, forCharacterRange: range)
                }
                return
            }
            cursor += direction
            if abs(cursor - index) > 20_000 { return }
        }
    }

    // MARK: Language service binding

    func bindLanguage(session: LanguageServerSession, uri: String, declarations: [String: String] = [:]) {
        unbindLanguage()
        let binding = LanguageBinding(session: session, uri: uri, text: text, declarations: declarations)
        binding.onDiagnostics = { [weak self] diagnostics in self?.receiveDiagnostics(diagnostics) }
        language = binding
    }

    /// Types for variables the target's driver injects (learned from the last run).
    func setLanguageDeclarations(_ declarations: [String: String]) {
        language?.setDeclarations(declarations, text: text)
    }

    func unbindLanguage() {
        language?.close()
        language = nil
        completion.hide()
        signaturePopup.hide()
        hoverPopup.hide()
        receiveDiagnostics([])
    }

    private func receiveDiagnostics(_ items: [LSPDiagnostic]) {
        let index = TextLineIndex(text)
        let length = (text as NSString).length
        diagnostics = items.map { diagnostic in
            var range = index.nsRange(of: diagnostic.range)
            if range.length == 0 {
                // Make zero-width diagnostics visible on the neighbouring character.
                if range.location < length { range.length = 1 } else if range.location > 0 { range = NSRange(location: range.location - 1, length: 1) }
            }
            return (NSIntersectionRange(range, NSRange(location: 0, length: length)), diagnostic)
        }
        var lines: [Int: Int] = [:]
        for item in diagnostics {
            let line = item.diagnostic.range.start.line
            lines[line] = min(lines[line] ?? 4, item.diagnostic.severity ?? 1)
        }
        ruler.diagnosticLines = lines
        applyDiagnosticDecorations()
    }

    private func applyDiagnosticDecorations() {
        guard let layoutManager = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: (text as NSString).length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        for item in diagnostics where NSMaxRange(item.range) <= full.length {
            let color: NSColor = (item.diagnostic.severity ?? 1) == 1 ? .systemRed : ((item.diagnostic.severity ?? 1) == 2 ? .systemYellow : .systemBlue)
            layoutManager.addTemporaryAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: color,
            ], forCharacterRange: item.range)
        }
    }

    // MARK: CodeTextViewDelegate

    func codeTextView(_ view: CodeTextView, handleCommand selector: Selector) -> Bool {
        if completion.isVisible {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                completion.moveSelection(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                completion.moveSelection(by: 1)
                return true
            case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
                completion.moveSelection(by: -8)
                return true
            case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
                completion.moveSelection(by: 8)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let item = completion.selectedItem {
                    accept(item)
                    return true
                }
            case #selector(NSResponder.cancelOperation(_:)):
                completion.hide()
                return true
            case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
                completion.hide()
            default:
                break
            }
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if signaturePopup.isVisible || hoverPopup.isVisible {
                signaturePopup.hide()
                hoverPopup.hide()
                return true
            }
        }
        return false
    }

    func codeTextView(_ view: CodeTextView, didType typed: String) {
        hoverPopup.hide()
        guard language != nil else { return }
        let before = characterBeforeCursor(offset: 2)
        if typed == "(" || typed == "," {
            requestSignatureHelp()
        } else if typed == ")" {
            signaturePopup.hide()
        }
        let isTrigger = typed == "$" || typed == "\\" || (typed == ">" && before == "->") || (typed == ":" && before == "::")
        if isTrigger {
            requestCompletion(explicit: false)
            return
        }
        if typed.count == 1, let scalar = typed.unicodeScalars.first, CharacterSet.alphanumerics.contains(scalar) || typed == "_" {
            if completion.isVisible {
                refilterCompletion()
            } else if currentWordPrefix().count >= 2 {
                requestCompletion(explicit: false, delay: .milliseconds(120))
            }
            return
        }
        if typed.isEmpty {
            if completion.isVisible { refilterCompletion() }
            return
        }
        completion.hide()
    }

    func codeTextViewRequestedCompletion(_ view: CodeTextView) {
        requestCompletion(explicit: true)
    }

    func codeTextView(_ view: CodeTextView, mouseRestedAt characterIndex: Int?, point: NSPoint) {
        guard let characterIndex else {
            if !hoverPopupContainsMouse() { hoverPopup.hide() }
            hoverTask?.cancel()
            return
        }
        showHover(at: characterIndex)
    }

    private func hoverPopupContainsMouse() -> Bool { false }

    // MARK: Completion

    private func characterBeforeCursor(offset: Int) -> String {
        let location = selectedRange.location
        let start = max(0, location - offset)
        return (text as NSString).substring(with: NSRange(location: start, length: location - start))
    }

    /// Identifier characters (including a leading `$`) before the cursor.
    private func currentWordPrefix() -> String {
        let string = text as NSString
        var start = selectedRange.location
        while start > 0 {
            let character = string.character(at: start - 1)
            let isIdentifier = (character >= 48 && character <= 57) || (character >= 65 && character <= 90) || (character >= 97 && character <= 122) || character == 95 || character > 127
            if isIdentifier {
                start -= 1
            } else {
                if character == 36 { start -= 1 }
                break
            }
        }
        return string.substring(with: NSRange(location: start, length: selectedRange.location - start))
    }

    private func requestCompletion(explicit: Bool, delay: Duration = .zero) {
        guard let language else { return }
        completionTask?.cancel()
        let cursor = selectedRange.location
        let prefix = currentWordPrefix()
        completionAnchor = cursor - (prefix as NSString).length
        let position = TextLineIndex(text).position(at: cursor)
        let trigger = explicit ? nil : String(characterBeforeCursor(offset: 1))
        completionTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            do {
                let items = try await language.completion(at: position, trigger: trigger.flatMap { ["$", ">", ":", "\\"].contains($0) ? $0 : nil })
                guard !Task.isCancelled, let self else { return }
                self.rawCompletionItems = items
                self.resolvedItemIds = []
                self.refilterCompletion()
            } catch {
                // Superseded or server unavailable: nothing to show.
            }
        }
    }

    private func refilterCompletion() {
        guard let anchor = completionAnchor, selectedRange.location >= anchor else {
            completion.hide()
            return
        }
        let typed = (text as NSString).substring(with: NSRange(location: anchor, length: selectedRange.location - anchor)).lowercased()
        let normalizedTyped = typed.hasPrefix("$") ? String(typed.dropFirst()) : typed
        let scored: [(CompletionItem, Int)] = rawCompletionItems.compactMap { item in
            let key = (item.filterText ?? item.label).lowercased()
            let normalizedKey = key.hasPrefix("$") ? String(key.dropFirst()) : key
            if normalizedTyped.isEmpty { return (item, 1) }
            if normalizedKey.hasPrefix(normalizedTyped) { return (item, 0) }
            if Self.fuzzyMatch(normalizedTyped, normalizedKey) { return (item, 2) }
            return nil
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return (lhs.0.sortText ?? lhs.0.label) < (rhs.0.sortText ?? rhs.0.label)
        }.prefix(300).map(\.0)
        if sorted.isEmpty {
            completion.hide()
            return
        }
        let rect = textView.screenRect(forCharacterAt: anchor)
        completion.show(items: Array(sorted), below: rect, parent: textView.window)
    }

    static func fuzzyMatch(_ needle: String, _ haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle {
            var found = false
            while let next = iterator.next() {
                if next == character { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    /// Items already resolved (or being resolved) for the current completion list.
    private var resolvedItemIds = Set<Int>()

    private func resolveForDetail(_ item: CompletionItem) {
        guard let language, item.documentation == nil, resolvedItemIds.insert(item.id).inserted else { return }
        Task { [weak self] in
            if let resolved = try? await language.resolve(item) {
                self?.completion.replaceItem(resolved)
            }
        }
    }

    private func accept(_ item: CompletionItem) {
        completion.hide()
        completionTask?.cancel()
        guard let language, let anchor = completionAnchor else { return }
        let cursor = selectedRange.location
        let index = TextLineIndex(text)
        let insert = SnippetText.plain(item.textEdit?.newText ?? item.insertText ?? item.label)

        // Main edit: the server's range (mapped), extended to the current cursor.
        var mainRange = NSRange(location: anchor, length: cursor - anchor)
        if let edit = item.textEdit {
            let mapped = index.nsRange(of: language.mapping.toEditor(edit.range))
            let start = min(mapped.location, anchor)
            mainRange = NSRange(location: start, length: max(cursor, NSMaxRange(mapped)) - start)
        }
        var edits: [(range: NSRange, text: String, isMain: Bool)] = [(mainRange, insert.text, true)]
        for additional in item.additionalTextEdits {
            let range = index.nsRange(of: language.mapping.toEditor(additional.range))
            if NSIntersectionRange(range, mainRange).length == 0 { edits.append((range, additional.newText, false)) }
        }
        // Apply back to front so earlier ranges stay valid; one undo group for the whole insertion.
        edits.sort { $0.range.location > $1.range.location }
        textView.undoManager?.beginUndoGrouping()
        var mainLocation = mainRange.location
        for edit in edits {
            textView.replace(range: edit.range, with: edit.text)
            if !edit.isMain, edit.range.location <= mainRange.location {
                mainLocation += (edit.text as NSString).length - edit.range.length
            }
        }
        textView.undoManager?.endUndoGrouping()
        let cursorOffset = insert.cursor ?? (insert.text as NSString).length
        textView.setSelectedRange(NSRange(location: mainLocation + cursorOffset, length: 0))
        if insert.text.hasSuffix("(") || (insert.cursor != nil && insert.text.contains("(")) {
            requestSignatureHelp()
        }
    }

    // MARK: Signature help

    /// Offset of the innermost unclosed `(` on the current statement, or nil.
    private func enclosingOpenParen() -> Int? {
        let string = text as NSString
        var depth = 0
        var index = selectedRange.location - 1
        var scanned = 0
        while index >= 0 && scanned < 4000 {
            let character = string.character(at: index)
            if character == 41 { depth += 1 }
            if character == 40 {
                if depth == 0 { return index }
                depth -= 1
            }
            if character == 59 || character == 123 || character == 125 { return nil }
            index -= 1
            scanned += 1
        }
        return nil
    }

    private func requestSignatureHelp() {
        guard let language else { return }
        signatureTask?.cancel()
        let position = TextLineIndex(text).position(at: selectedRange.location)
        let anchor = enclosingOpenParen() ?? selectedRange.location
        signatureTask = Task { [weak self] in
            let help = try? await language.signatureHelp(at: position)
            guard !Task.isCancelled, let self else { return }
            guard let help, let signature = help.signatures[safe: help.activeSignature] else {
                self.signaturePopup.hide()
                return
            }
            let rendered = NSMutableAttributedString(string: signature.label, attributes: [.font: NSFont.monospacedSystemFont(ofSize: self.fontSize - 1, weight: .regular), .foregroundColor: NSColor.labelColor])
            if let active = signature.parameterRanges[safe: help.activeParameter], active.upperBound <= (signature.label as NSString).length {
                rendered.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: self.fontSize - 1, weight: .bold), .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: active.lowerBound, length: active.count))
                if let doc = signature.parameterDocs[safe: help.activeParameter] ?? nil, !doc.isEmpty {
                    rendered.append(NSAttributedString(string: "\n"))
                    rendered.append(InfoPopup.render(markdown: doc, fontSize: self.fontSize))
                }
            }
            self.signaturePopup.show(rendered, near: self.textView.screenRect(forCharacterAt: anchor), above: true, parent: self.textView.window)
        }
    }

    // MARK: Hover

    private func showHover(at characterIndex: Int) {
        hoverTask?.cancel()
        let messages = diagnostics.filter { NSLocationInRange(characterIndex, $0.range) }.map { item -> String in
            let source = [item.diagnostic.source, item.diagnostic.codeString].compactMap { $0 }.joined(separator: " ")
            return "⚠︎ " + item.diagnostic.message + (source.isEmpty ? "" : "  (\(source))")
        }
        let position = TextLineIndex(text).position(at: characterIndex)
        let rect = textView.screenRect(forCharacterAt: characterIndex)
        let language = self.language
        hoverTask = Task { [weak self] in
            var hover: HoverInfo?
            if let language { hover = try? await language.hover(at: position) }
            guard !Task.isCancelled, let self else { return }
            let content = NSMutableAttributedString()
            if !messages.isEmpty {
                content.append(NSAttributedString(string: messages.joined(separator: "\n"), attributes: [.font: NSFont.systemFont(ofSize: self.fontSize - 1, weight: .medium), .foregroundColor: NSColor.systemRed]))
            }
            if let hover {
                if content.length > 0 { content.append(NSAttributedString(string: "\n\n")) }
                content.append(InfoPopup.render(markdown: hover.markdown, fontSize: self.fontSize))
            }
            if content.length == 0 {
                self.hoverPopup.hide()
            } else {
                self.hoverPopup.show(content, near: rect, above: false, parent: self.textView.window)
            }
        }
    }
}

/// Connects one editor document to a PHPantom session (scratch URI + synthetic tag mapping).
@MainActor
final class LanguageBinding {
    let session: LanguageServerSession
    let uri: String
    private(set) var mapping: ScratchDocumentMapping
    private var version = 1
    private var diagnosticsTask: Task<Void, Never>?
    private var pendingText: String?
    private var syncTask: Task<Void, Never>?
    var onDiagnostics: (([LSPDiagnostic]) -> Void)?

    private var declarations: [String: String]

    init(session: LanguageServerSession, uri: String, text: String, declarations: [String: String] = [:]) {
        self.session = session
        self.uri = uri
        self.declarations = declarations
        mapping = ScratchDocumentMapping(editorText: text, declarations: declarations)
        let lspText = mapping.lspText(for: text)
        let version = version
        Task { await session.open(uri: uri, text: lspText, version: version) }
        diagnosticsTask = Task { [weak self] in
            let stream = await session.diagnosticsUpdates()
            for await update in stream where update.uri == uri {
                guard let self else { return }
                // Ignore diagnostics explicitly tagged with an older document version.
                if let updateVersion = update.version, updateVersion < self.version { continue }
                let mapping = self.mapping
                self.onDiagnostics?(update.diagnostics.map { diagnostic in
                    var mapped = diagnostic
                    mapped.range = mapping.toEditor(diagnostic.range)
                    return mapped
                })
            }
        }
    }

    func setDeclarations(_ declarations: [String: String], text: String) {
        guard declarations != self.declarations else { return }
        self.declarations = declarations
        documentChanged(text)
    }

    /// Coalesces keystrokes: the server re-analyses at most every ~120 ms while typing.
    /// Requests (completion, hover, signature help) flush pending text first.
    func documentChanged(_ text: String) {
        mapping = ScratchDocumentMapping(editorText: text, declarations: declarations)
        pendingText = text
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Sends the latest text to the server if it changed since the last sync.
    func flush() async {
        guard let text = pendingText else { return }
        pendingText = nil
        version += 1
        let lspText = ScratchDocumentMapping(editorText: text, declarations: declarations).lspText(for: text)
        await session.change(uri: uri, text: lspText, version: version)
    }

    func close() {
        diagnosticsTask?.cancel()
        syncTask?.cancel()
        let session = session
        let uri = uri
        Task { await session.close(uri: uri) }
    }

    func completion(at editorPosition: LSPPosition, trigger: String?) async throws -> [CompletionItem] {
        await flush()
        return try await session.completion(uri: uri, position: mapping.toLSP(editorPosition), triggerCharacter: trigger)
    }

    func resolve(_ item: CompletionItem) async throws -> CompletionItem {
        try await session.resolve(item)
    }

    func hover(at editorPosition: LSPPosition) async throws -> HoverInfo? {
        await flush()
        return try await session.hover(uri: uri, position: mapping.toLSP(editorPosition))
    }

    func signatureHelp(at editorPosition: LSPPosition) async throws -> SignatureHelpInfo? {
        await flush()
        return try await session.signatureHelp(uri: uri, position: mapping.toLSP(editorPosition))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
