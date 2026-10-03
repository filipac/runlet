import AppKit
import RunletCore
import RunletLanguage

/// Owns one tab's native editor. The scroll view and text view are created once and kept
/// for the tab's lifetime, so undo history, selection, scroll position, and input-method
/// state survive SwiftUI updates and tab switches.
@MainActor
final class EditorController: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate, NSTextStorageDelegate, CodeTextViewDelegate {
    let scrollView: NSScrollView
    let textView: CodeTextView
    private let ruler: LineNumberRulerView
    private var theme = EditorTheme.resolve(dark: false)
    private var fontSize: CGFloat = 13
    private var highlightWork: DispatchWorkItem?
    /// Where to look for the failed line's and the bracket match's markers (see `markedRanges`).
    private var errorLineSpans: [NSRange] = []
    private var bracketMatchSpans: [NSRange] = []
    private var isLoadingCode = false
    /// Magic comments' values from the last run (#10), and the comments' ranges for highlighting.
    let inlineValues: InlineValueOverlay
    private var magicCommentRanges: [NSRange] = []

    /// Full text and origin after an editor edit or a programmatic code load.
    enum TextChangeOrigin { case edit, load }
    var onTextChange: ((String, TextChangeOrigin) -> Void)?
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
        // Keeps column 1 just right of the gutter when the ruler's inset changes (#78).
        scrollView = EditorScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        ruler = LineNumberRulerView(textView: textView)
        inlineValues = InlineValueOverlay(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        // Views stopped clipping by default in macOS 14: without this, the gutter's edge line
        // draws up through the banners above the editor (and into the tab strip, #1).
        scrollView.clipsToBounds = true
        ruler.clipsToBounds = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        super.init()
        textView.delegate = self
        textView.codeDelegate = self
        layoutManager.delegate = self
        textStorage.delegate = self
        textView.backgroundDecorations = { [weak self] rect in
            guard let self else { return }
            self.inlineValues.drawCommentHighlights(self.magicCommentRanges, in: rect)
        }
        textView.overlayDecorations = { [weak self] rect in self?.inlineValues.draw(in: rect) }
        inlineValues.onMarkersChange = { [weak self] markers in self?.ruler.inlineMarkers = markers }
        inlineValues.onWidthNeeded = { [weak self] width in self?.fitInlineValues(width) }
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

    /// Replaces the selection with `text` (undoable), puts the caret after it, and focuses
    /// the editor.
    func insertAtSelection(_ text: String) {
        let range = selectedRange
        textView.replace(range: range, with: text, selectAfter: NSRange(location: range.location + (text as NSString).length, length: 0))
        focus()
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
        inlineValues.theme = theme
        // Turned off, magic comments are ordinary comments: no values, no highlight.
        inlineValues.isEnabled = preferences.magicComments
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

    /// Without soft wrap the text view is only as wide as its longest line: keep it wide enough
    /// for the inline values drawn after lines (nil: back to fitting the text).
    private func fitInlineValues(_ width: CGFloat?) {
        guard appliedSoftWrap == false else { return }
        textView.minSize = NSSize(width: width ?? 0, height: textView.minSize.height)
        if width == nil { textView.sizeToFit() }
        let target = max(width ?? 0, visibleWidth)
        if textView.frame.width < target {
            textView.setFrameSize(NSSize(width: target, height: textView.frame.height))
        }
    }

    /// The clip view resized, or its insets changed (the ruler widens past 99 lines).
    @objc private func clipViewGeometryChanged(_ notification: Notification) {
        inlineValues.hidePanel()
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

    // MARK: Code loads and editor insertions (undoable)

    /// Replacing the document is a load; opted-in auto-run must be disarmed.
    func replaceAll(with newText: String) {
        isLoadingCode = true
        defer { isLoadingCode = false }
        textView.replace(range: NSRange(location: 0, length: (text as NSString).length), with: newText, selectAfter: NSRange(location: 0, length: 0))
    }

    /// Replaces the selection with `newText` and puts the caret after it.
    func insert(_ newText: String) {
        let range = selectedRange
        let caret = NSRange(location: range.location + (newText as NSString).length, length: 0)
        textView.replace(range: range, with: newText, selectAfter: caret)
        textView.scrollRangeToVisible(caret)
    }

    /// Shows the file's new contents (an external change), keeping the caret near where it
    /// was and the scroll position. Undoable like any edit.
    func reload(with newText: String) {
        isLoadingCode = true
        defer { isLoadingCode = false }
        let caret = selectedRange.location
        let origin = scrollView.contentView.bounds.origin
        let length = (newText as NSString).length
        textView.replace(range: NSRange(location: 0, length: (text as NSString).length), with: newText, selectAfter: NSRange(location: min(caret, length), length: 0))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func goTo(line: Int, column: Int = 1) {
        let index = TextLineIndex(text)
        let offset = index.offset(of: LSPPosition(line: max(0, line - 1), character: max(0, column - 1)))
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        focus()
    }

    // MARK: Marked highlights (#87, #113)
    //
    // The failed line's red background and the bracket match are NSLayoutManager temporary
    // attributes. Those move with the text when it's edited (and split around text typed inside
    // them), so a range stored when highlighting goes stale. Each highlight also carries a
    // marker attribute of its own, which says where it is now. `errorLineSpans` and
    // `bracketMatchSpans` only say where to look: every edit moves them (`didProcessEditing`),
    // so finding a highlight never walks the whole document.
    private static let executionErrorMarker = NSAttributedString.Key("RunletExecutionErrorLine")
    private static let bracketMatchMarker = NSAttributedString.Key("RunletBracketMatch")

    /// Marks a 1-based editor line as the location of an execution error (one line at a time).
    func showExecutionError(line: Int?) {
        clearExecutionError()
        guard let line, let layoutManager = textView.layoutManager else { return }
        let index = TextLineIndex(text)
        let start = index.offset(of: LSPPosition(line: line - 1, character: 0))
        let range = (text as NSString).lineRange(for: NSRange(location: min(start, (text as NSString).length), length: 0))
        layoutManager.addTemporaryAttributes([.backgroundColor: theme.errorLine, Self.executionErrorMarker: true], forCharacterRange: range)
        errorLineSpans = [range]
        ruler.executionErrorLine = line - 1
        // The caret's bracket match stays visible over the red.
        updateBracketMatch()
    }

    /// Removes the failed line's background wherever edits have moved it, and only that: the
    /// bracket match is drawn again for the current caret.
    func clearExecutionError() {
        ruler.executionErrorLine = nil
        guard !errorLineSpans.isEmpty, let layoutManager = textView.layoutManager else { return }
        for range in markedRanges(Self.executionErrorMarker, in: errorLineSpans) {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layoutManager.removeTemporaryAttribute(Self.executionErrorMarker, forCharacterRange: range)
        }
        errorLineSpans = []
        updateBracketMatch()
    }

    /// The ranges within `spans` whose characters carry `marker` (several after typing inside a
    /// highlight).
    private func markedRanges(_ marker: NSAttributedString.Key, in spans: [NSRange]) -> [NSRange] {
        guard let layoutManager = textView.layoutManager else { return [] }
        let document = NSRange(location: 0, length: (text as NSString).length)
        var ranges: [NSRange] = []
        for span in spans {
            let span = NSIntersectionRange(span, document)
            var location = span.location
            while location < NSMaxRange(span) {
                var effective = NSRange()
                if layoutManager.temporaryAttribute(marker, atCharacterIndex: location, longestEffectiveRange: &effective, in: span) != nil {
                    ranges.append(effective)
                }
                location = max(NSMaxRange(effective), location + 1)
            }
        }
        return ranges
    }

    /// Where a highlight that was within `span` can be after an edit that replaced
    /// `edited.length - delta` characters at `edited.location` with `edited.length` new ones (or
    /// several edits within `edited`). Inserted text never gets a highlight's attributes, so the
    /// result may be wider than the highlight, never narrower.
    private static func span(_ span: NSRange, afterEdit edited: NSRange, changeInLength delta: Int) -> NSRange {
        let replacedEnd = edited.location + edited.length - delta
        if NSMaxRange(span) <= edited.location { return span }
        if span.location >= replacedEnd { return NSRange(location: span.location + delta, length: span.length) }
        let start = min(span.location, edited.location)
        let end = max(NSMaxRange(span) + delta, NSMaxRange(edited))
        return NSRange(location: start, length: max(0, end - start))
    }

    #if DEBUG
    /// Ranges with a temporary background, by kind (`error`, `bracket`, or `other`), and the
    /// ruler's 1-based error line, for the `editor-check` step (EditorDebugCheck, #87).
    var debugBackgrounds: [(range: NSRange, kind: String)] {
        guard let layoutManager = textView.layoutManager else { return [] }
        let full = NSRange(location: 0, length: (text as NSString).length)
        var backgrounds: [(range: NSRange, kind: String)] = []
        var location = 0
        while location < full.length {
            var effective = NSRange()
            if let color = layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: location, longestEffectiveRange: &effective, in: full) as? NSColor {
                backgrounds.append((effective, color == theme.errorLine ? "error" : color == theme.bracketMatch ? "bracket" : "other"))
            }
            location = max(NSMaxRange(effective), location + 1)
        }
        return backgrounds
    }

    var debugRulerErrorLine: Int? { ruler.executionErrorLine.map { $0 + 1 } }

    /// Where the failed line's and the bracket match's markers are looked up (#113 review: never
    /// the whole document).
    var debugHighlightSpans: (error: [NSRange], bracket: [NSRange]) { (errorLineSpans, bracketMatchSpans) }
    #endif

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        clearExecutionError()
        scheduleHighlight()
        language?.documentChanged(text)
        onTextChange?(text, isLoadingCode ? .load : .edit)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if !showingInlineValueAtCaret { inlineValues.hidePanel() }
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
        var magic: [NSRange] = []
        for var token in PHPHighlighter.tokenize(string) where NSMaxRange(token.range) <= string.length {
            if token.kind == .magicComment, !preferences.magicComments { token.kind = .comment }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: theme.color(for: token.kind), forCharacterRange: token.range)
            if token.kind == .magicComment { magic.append(token.range) }
        }
        if magic != magicCommentRanges {
            magicCommentRanges = magic
            textView.setNeedsDisplay(textView.visibleRect)
        }
        applyDiagnosticDecorations()
    }

    // MARK: Inline values (magic comments)

    /// A run of `code` (the whole text, or the selection starting at `selection`) is starting.
    func beginInlineValues(code: String, selection: SourceSelection?) {
        inlineValues.begin(code: code, selection: selection, editorText: text)
    }

    func applyInline(_ event: InlineEvent, editorLine: (Int) -> Int) {
        inlineValues.apply(event, editorLine: editorLine)
    }

    func clearInlineValues() {
        inlineValues.clear()
    }

    private var showingInlineValueAtCaret = false

    /// Shows the hover panel for the caret's line (Edit ▸ Show Inline Value), or for an
    /// editor line. False when the line has no inline values.
    @discardableResult
    func showInlineValue(line: Int? = nil) -> Bool {
        var location = selectedRange.location
        if let line {
            location = TextLineIndex(text).offset(of: LSPPosition(line: max(0, line - 1), character: 0))
        }
        guard let original = inlineValues.line(containing: location) else { return false }
        if let range = inlineValues.currentRange(ofLine: original) {
            showingInlineValueAtCaret = true
            textView.scrollRangeToVisible(range)
            showingInlineValueAtCaret = false
        }
        inlineValues.showPanel(forLine: original)
        return true
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Lines with inline values move with their text; an edited line loses its values.
        inlineValues.textDidChange(range: NSRange(location: editedRange.location, length: editedRange.length - delta), replacementLength: editedRange.length, newText: textStorage.mutableString)
        // Highlights move with their text, and so do the places to look for them.
        errorLineSpans = errorLineSpans.map { Self.span($0, afterEdit: editedRange, changeInLength: delta) }
        bracketMatchSpans = bracketMatchSpans.map { Self.span($0, afterEdit: editedRange, changeInLength: delta) }
    }

    /// Highlights the bracket before the caret and its match, after removing the previous pair
    /// wherever edits have moved it (#113).
    private func updateBracketMatch() {
        guard let layoutManager = textView.layoutManager else { return }
        for range in markedRanges(Self.bracketMatchMarker, in: bracketMatchSpans) {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layoutManager.removeTemporaryAttribute(Self.bracketMatchMarker, forCharacterRange: range)
            // Inside the failed line, the bracket covered its red: put the red back there.
            guard !errorLineSpans.isEmpty else { continue }
            for red in markedRanges(Self.executionErrorMarker, in: [range]) {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: theme.errorLine, forCharacterRange: red)
            }
        }
        bracketMatchSpans = []
        let length = (text as NSString).length
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
                bracketMatchSpans = [NSRange(location: index, length: 1), NSRange(location: cursor, length: 1)]
                for range in bracketMatchSpans {
                    layoutManager.addTemporaryAttributes([.backgroundColor: theme.bracketMatch, Self.bracketMatchMarker: true], forCharacterRange: range)
                }
                return
            }
            cursor += direction
            if abs(cursor - index) > 20_000 { return }
        }
    }

    // MARK: Language service binding

    func bindLanguage(session: LanguageServerSession, uri: String, declarations: [String: String] = [:], limited: Bool = false) {
        unbindLanguage()
        let binding = LanguageBinding(session: session, uri: uri, text: text, declarations: declarations, limited: limited)
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
            if inlineValues.panelLine != nil {
                inlineValues.hidePanel()
                return true
            }
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
        inlineValues.hidePanel()
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

    /// Resting over a line's inline values shows their panel; resting elsewhere hides it.
    func codeTextView(_ view: CodeTextView, mouseRestedOn point: NSPoint) {
        if let line = inlineValues.line(at: point) {
            hoverPopup.hide()
            if inlineValues.panelLine != line { inlineValues.showPanel(forLine: line) }
        } else if inlineValues.panelLine != nil, !inlineValues.panelContainsMouse() {
            inlineValues.hidePanel()
        }
    }

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

        // Main edit: the server's range (mapped), extended to the current cursor.
        var mainRange = NSRange(location: anchor, length: cursor - anchor)
        if let edit = item.textEdit {
            let mapped = index.nsRange(of: language.mapping.toEditor(edit.range))
            let start = min(mapped.location, anchor)
            mainRange = NSRange(location: start, length: max(cursor, NSMaxRange(mapped)) - start)
        }
        let string = text as NSString
        let following = NSMaxRange(mainRange) < string.length ? string.substring(with: NSRange(location: NSMaxRange(mainRange), length: 1)).first : nil
        let insert = CompletionInsertion.make(item: item, followingCharacter: following)
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
        let caret = mainLocation + insert.cursor
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        if insert.showsSignatureHelp {
            requestSignatureHelp(emptyCallCaret: insert.parametersUnknown ? caret : nil)
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

    /// - Parameter emptyCallCaret: the caret an accepted completion just put between the empty
    ///   parentheses of a call whose parameters were unknown. If the signature has none and the
    ///   caret has not moved, it steps past `)` instead of showing the popup.
    private func requestSignatureHelp(emptyCallCaret: Int? = nil) {
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
            if let emptyCallCaret, signature.parameterRanges.isEmpty, self.selectedRange == NSRange(location: emptyCallCaret, length: 0),
               emptyCallCaret < (self.text as NSString).length, (self.text as NSString).character(at: emptyCallCaret) == 41 {
                self.textView.setSelectedRange(NSRange(location: emptyCallCaret + 1, length: 0))
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

    /// No project source (unmapped Docker container): unknown-symbol warnings are hidden.
    let limited: Bool
    private var editorLineCount: Int

    init(session: LanguageServerSession, uri: String, text: String, declarations: [String: String] = [:], limited: Bool = false) {
        self.session = session
        self.uri = uri
        self.declarations = declarations
        self.limited = limited
        self.editorLineCount = TextLineIndex(text).lineCount
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
                self.onDiagnostics?(DiagnosticFilter.visible(update.diagnostics, mapping: self.mapping, editorLineCount: self.editorLineCount, limitedWorkspace: self.limited))
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
        editorLineCount = TextLineIndex(text).lineCount
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
