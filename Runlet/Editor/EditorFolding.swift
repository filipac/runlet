import AppKit
import RunletLanguage

/// Code folding from PHPantom's folding ranges (#22). The gutter shows a control on each
/// foldable line; a folded block shows as `{⋯}` on its first line.
///
/// Folding never changes the text: the folded characters stay in the text storage (Run, Copy,
/// Save, and Format Code see everything) and are only left out of layout, through the layout
/// manager's glyph generation (null glyphs) and control-character actions (newlines with no
/// advance). The first folded character, the newline after the block's first line, becomes the
/// `⋯` placeholder. Typing inside a folded block, or moving the caret into one, unfolds it; a
/// fold moves with the text above it. Foldable ranges are asked for the whole tab a moment after
/// typing stops.
@MainActor
final class EditorFolding {
    typealias Region = EditorFoldRegion

    private weak var textView: CodeTextView?
    var theme = EditorTheme.resolve(dark: false)
    weak var binding: LanguageBinding? {
        didSet {
            unfoldAll()
            regions = []
            if binding != nil { scheduleRefresh(after: .milliseconds(500)) }
            onChange?()
        }
    }
    /// The gutter needs drawing again (regions or folds changed).
    var onChange: (() -> Void)?
    private(set) var regions: [Region] = []
    /// Folded (hidden) character ranges, sorted, never overlapping.
    private(set) var folded: [NSRange] = []
    private var refreshTask: Task<Void, Never>?
    private var generation = 0

    init(textView: CodeTextView) {
        self.textView = textView
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
    }

    var hasRegions: Bool { !regions.isEmpty }

    // MARK: Asking PHPantom

    @objc private func textChanged() { scheduleRefresh(after: .milliseconds(700)) }

    func scheduleRefresh(after delay: Duration) {
        refreshTask?.cancel()
        guard binding != nil else { return }
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard let binding, let textView else { return }
        let text = textView.string
        let generation = generation
        guard let ranges = try? await binding.foldingRanges(), !Task.isCancelled, self.generation == generation, textView.string == text else { return }
        let next = FoldingPlacement.regions(ranges, mapping: binding.mapping, editorLineCount: TextLineIndex(text).lineCount)
        guard next != regions else { return }
        regions = next
        onChange?()
    }

    // MARK: Folding

    static func hiddenRange(for region: Region, in text: String) -> NSRange? {
        FoldingPlacement.hiddenRange(for: region, in: text)
    }

    /// The region starting on `line`, folded or not.
    func region(startingOn line: Int) -> Region? { regions.first { $0.startLine == line } }

    func isFolded(_ region: Region) -> Bool {
        guard let textView, let range = Self.hiddenRange(for: region, in: textView.string) else { return false }
        return folded.contains(range)
    }

    func fold(_ region: Region) {
        guard let textView, let range = Self.hiddenRange(for: region, in: textView.string), !folded.contains(range) else { return }
        // A fold inside it is replaced; a fold around it already hides it.
        guard !folded.contains(where: { NSIntersectionRange($0, range) == range }) else { return }
        let removed = folded.filter { NSIntersectionRange($0, range) == $0 }
        folded.removeAll { NSIntersectionRange($0, range) == $0 }
        folded.append(range)
        folded.sort { $0.location < $1.location }
        // The caret leaves the folded text for the line the fold starts on.
        let selection = textView.selectedRange()
        if contains(range, selection.location) || contains(range, NSMaxRange(selection)) {
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
        }
        invalidate([range] + removed)
    }

    func unfold(_ range: NSRange) {
        guard let index = folded.firstIndex(of: range) else { return }
        folded.remove(at: index)
        invalidate([range])
    }

    func unfoldAll() {
        guard !folded.isEmpty else { return }
        let all = folded
        folded = []
        invalidate(all)
    }

    /// Folds every block (the outermost ones hide the rest).
    func foldAll() {
        for region in regions.sorted(by: { ($0.endLine - $0.startLine) > ($1.endLine - $1.startLine) }) { fold(region) }
    }

    /// Folds the innermost unfolded block around the caret's line.
    func foldAtCaret() {
        guard let textView else { return }
        let line = TextLineIndex(textView.string).position(at: textView.selectedRange().location).line
        let around = regions.filter { $0.startLine <= line && line <= $0.endLine && !isFolded($0) }
        if let innermost = around.min(by: { ($0.endLine - $0.startLine) < ($1.endLine - $1.startLine) }) { fold(innermost) }
    }

    /// Unfolds the folds on the caret's line.
    func unfoldAtCaret() {
        guard let textView else { return }
        let string = textView.string as NSString
        let line = string.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0))
        for range in folded where NSIntersectionRange(NSRange(location: line.location, length: line.length + 1), range).length > 0 || range.location == NSMaxRange(line) - 1 {
            unfold(range)
        }
    }

    /// Toggles the region that starts on the line beginning at `lineStart` (a gutter click).
    func toggle(lineStart: Int) {
        guard let textView else { return }
        let line = TextLineIndex(textView.string).position(at: lineStart).line
        guard let region = region(startingOn: line), let range = Self.hiddenRange(for: region, in: textView.string) else { return }
        if folded.contains(range) { unfold(range) } else { fold(region) }
    }

    /// Folds character ranges again after an edit opened them (#234: a folded block that lines
    /// moved over stays folded at its new place).
    func refold(_ ranges: [NSRange]) {
        guard let textView else { return }
        let length = (textView.string as NSString).length
        let valid = ranges.filter { range in
            range.length > 1 && NSMaxRange(range) <= length && !folded.contains { NSIntersectionRange($0, range).length > 0 }
        }
        guard !valid.isEmpty else { return }
        folded = (folded + valid).sorted { $0.location < $1.location }
        invalidate(valid)
    }

    /// Unfolds whatever hides `index`, so it can be shown (an error line, a search result).
    func reveal(_ index: Int) {
        for range in folded where contains(range, index) { unfold(range) }
    }

    private func contains(_ range: NSRange, _ index: Int) -> Bool {
        index > range.location && index < NSMaxRange(range)
    }

    /// Whether `index` is hidden (the placeholder character is not).
    func isHidden(_ index: Int) -> Bool {
        folded.contains { index > $0.location && index < NSMaxRange($0) }
    }

    /// Whether the line starting at `lineStart` is drawn on a fold's row: hidden, or the
    /// block's last line, whose closing `}` follows the placeholder.
    func isLineFolded(_ lineStart: Int) -> Bool {
        folded.contains { lineStart > $0.location && lineStart <= NSMaxRange($0) }
    }

    private func invalidate(_ ranges: [NSRange]) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let string = textView.string as NSString
        for range in ranges where NSMaxRange(range) <= string.length {
            // Text inside a fold is laid out again from the fold's first line: a paragraph laid
            // out on its own would start a row of its own (#234: a moved block folded again).
            let whole = folded.reduce(range) { $1.location <= NSMaxRange($0) && $0.location <= NSMaxRange($1) ? NSUnionRange($0, $1) : $0 }
            let paragraphs = string.paragraphRange(for: NSIntersectionRange(whole, NSRange(location: 0, length: string.length)))
            layoutManager.invalidateGlyphs(forCharacterRange: paragraphs, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: paragraphs, actualCharacterRange: nil)
        }
        textView.needsDisplay = true
        onChange?()
    }

    // MARK: Layout (from the layout manager's delegate)

    func generateGlyphs(_ layoutManager: NSLayoutManager, glyphs: UnsafePointer<CGGlyph>, properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                        characterIndexes: UnsafePointer<Int>, font: NSFont, glyphRange: NSRange) -> Int {
        guard !folded.isEmpty else { return 0 }
        var changed = false
        var adjusted = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        for index in 0..<glyphRange.length {
            adjusted[index] = properties[index]
            if isHidden(characterIndexes[index]), !properties[index].contains(.controlCharacter) {
                adjusted[index] = .null
                changed = true
            }
        }
        guard changed else { return 0 }
        adjusted.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func controlCharacterAction(_ action: NSLayoutManager.ControlCharacterAction, at index: Int) -> NSLayoutManager.ControlCharacterAction {
        guard !folded.isEmpty else { return action }
        if folded.contains(where: { $0.location == index }) { return .whitespace }
        return isHidden(index) ? .zeroAdvancement : action
    }

    /// The placeholder's width, in the editor's font.
    private var placeholderWidth: CGFloat {
        let font = textView?.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        return ceil(("⋯" as NSString).size(withAttributes: [.font: font]).width) + 14
    }

    func placeholderBox(proposedLineFragment: NSRect, glyphPosition: NSPoint) -> NSRect {
        let font = textView?.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        return NSRect(x: glyphPosition.x, y: 0, width: placeholderWidth, height: font.ascender - font.descender)
    }

    // MARK: Edits and the caret

    /// An edit replaced `edited.length - delta` characters at `edited.location`: folds it
    /// touches open, folds after it move.
    func textStorage(willProcessEditing edited: NSRange, changeInLength delta: Int) {
        generation += 1
        refreshTask?.cancel()
        guard !folded.isEmpty else { return }
        let (kept, opened) = FoldingPlacement.adjust(folded, edited: edited, changeInLength: delta)
        folded = kept
        if !opened.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, let length = self.textView?.textStorage?.length else { return }
                self.invalidate(opened.map { NSIntersectionRange($0, NSRange(location: 0, length: length)) })
            }
        }
    }

    /// The caret or a selection end inside a fold unfolds it.
    func selectionChanged(_ selection: NSRange) {
        guard !folded.isEmpty else { return }
        for range in folded where contains(range, selection.location) || contains(range, NSMaxRange(selection)) {
            unfold(range)
        }
    }

    // MARK: Drawing

    /// Draws `⋯` placeholders over the folded blocks.
    func draw(in dirtyRect: NSRect) {
        guard !folded.isEmpty, let textView, let layoutManager = textView.layoutManager else { return }
        let origin = textView.textContainerOrigin
        let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let length = (textView.string as NSString).length
        for range in folded where range.location < length {
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            guard glyph < layoutManager.numberOfGlyphs else { continue }
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = layoutManager.location(forGlyphAt: glyph)
            let baseline = origin.y + fragment.minY + location.y
            let pill = NSRect(x: origin.x + fragment.minX + location.x + 3, y: baseline - font.ascender - 1, width: placeholderWidth - 6, height: font.ascender - font.descender + 2)
            guard pill.intersects(dirtyRect) else { continue }
            theme.inlineBackground.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            theme.inlineText.withAlphaComponent(0.5).setStroke()
            let border = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            border.lineWidth = 0.5
            border.stroke()
            let label = "⋯" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.inlineText]
            let size = label.size(withAttributes: attributes)
            label.draw(with: NSRect(x: pill.midX - size.width / 2, y: baseline - font.ascender, width: size.width, height: size.height), options: [.usesLineFragmentOrigin], attributes: attributes)
        }
    }

    /// The folded range whose placeholder is at `point` (a click on it unfolds).
    func placeholder(at point: NSPoint) -> NSRange? {
        guard !folded.isEmpty, let textView, let layoutManager = textView.layoutManager else { return nil }
        let origin = textView.textContainerOrigin
        for range in folded where range.location < (textView.string as NSString).length {
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            guard glyph < layoutManager.numberOfGlyphs else { continue }
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x = origin.x + fragment.minX + layoutManager.location(forGlyphAt: glyph).x
            let rect = NSRect(x: x, y: origin.y + fragment.minY, width: placeholderWidth, height: fragment.height)
            if rect.contains(point) { return range }
        }
        return nil
    }

    // MARK: Gutter

    private var markerCache: (key: String, markers: [Int: Bool])?

    /// Foldable lines by where they start, and whether they are folded (cached until an edit,
    /// a fold, or new regions).
    func markers() -> [Int: Bool] {
        guard let textView, !regions.isEmpty else { return [:] }
        let key = "\(generation)|\(folded)|\(regions.count)|\(regions.first?.startLine ?? -1)|\(regions.last?.endLine ?? -1)"
        if let markerCache, markerCache.key == key { return markerCache.markers }
        let text = textView.string
        let index = TextLineIndex(text)
        var result: [Int: Bool] = [:]
        for region in regions {
            let start = index.offset(of: LSPPosition(line: region.startLine, character: 0))
            guard !isLineFolded(start) else { continue }
            let range = Self.hiddenRange(for: region, in: text)
            result[start] = range.map { folded.contains($0) } ?? false
        }
        markerCache = (key, result)
        return result
    }
}

extension LanguageBinding {
    func foldingRanges() async throws -> [LSPFoldingRange] {
        await flush()
        return try await session.foldingRanges(uri: uri)
    }
}
