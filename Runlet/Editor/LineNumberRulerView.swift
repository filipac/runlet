import AppKit

/// Gutter with line numbers, a static-diagnostic marker, the execution-error marker, and a
/// marker on lines whose magic comments ran (#10).
final class LineNumberRulerView: NSRulerView {
    weak var codeView: CodeTextView?
    var theme = EditorTheme.resolve(dark: false) { didSet { needsDisplay = true } }
    /// 0-based lines with static diagnostics: severity 1 error, 2 warning.
    var diagnosticLines: [Int: Int] = [:] { didSet { needsDisplay = true } }
    /// 0-based line of the last execution error.
    var executionErrorLine: Int? { didSet { needsDisplay = true } }
    /// Lines with magic comments, by the character offset where the line starts.
    var inlineMarkers: [Int: InlineMarker] = [:] { didSet { if inlineMarkers != oldValue { needsDisplay = true } } }
    /// A quick fix is available on this 0-based line (#22): a light bulb replaces its marker.
    var lightBulbLine: Int? { didSet { needsDisplay = true } }
    var onLightBulbClick: (() -> Void)?
    /// Code folding (#22): folded lines get no number, and foldable lines a control.
    weak var folding: EditorFolding?
    /// Width of the fold controls' column (between the numbers and the code), when there are any.
    private var foldColumn: CGFloat { folding?.hasRegions == true ? 12 : 0 }

    init(textView: CodeTextView) {
        self.codeView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
        // Re-wrapping (soft wrap, resizing, font or line-height changes) moves line fragments.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.frameDidChangeNotification, object: textView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Folds or foldable regions changed.
    func foldingChanged() { refresh() }

    @objc private func refresh() {
        let lines = max(1, (codeView?.string as NSString?)?.components(separatedBy: "\n").count ?? 1)
        let digits = max(2, String(lines).count)
        let thickness = CGFloat(digits) * 8 + 26 + foldColumn
        if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeView else { return }
        theme.gutterBackground.setFill()
        bounds.fill()

        let text = textView.string as NSString
        let font = numberFont
        foldMarkers = folding?.markers() ?? [:]
        let selectedLine = text.substring(to: min(textView.selectedRange().location, text.length)).components(separatedBy: "\n").count - 1
        for number in numberPlacements() {
            let line = number.line
            let color = line == selectedLine ? theme.text : theme.gutterText
            let label = "\(line + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = label.size(withAttributes: attributes)
            // Without `.usesLineFragmentOrigin` the rect's origin is the baseline (`draw(at:)`
            // would put it at the rounded line height's baseline, a fraction of a point lower).
            label.draw(with: NSRect(x: ruleThickness - size.width - 8 - foldColumn, y: number.baseline, width: size.width, height: size.height), options: [], attributes: attributes)
            var markerColor: NSColor?
            if lightBulbLine == line, executionErrorLine != line {
                drawLightBulb(centerY: number.baseline - font.capHeight / 2)
            } else if executionErrorLine == line { markerColor = .systemRed }
            else if let severity = diagnosticLines[line] { markerColor = severity == 1 ? .systemRed.withAlphaComponent(0.7) : .systemYellow }
            if let markerColor {
                markerColor.setFill()
                let diameter: CGFloat = executionErrorLine == line ? 7 : 5
                let centerY = number.baseline - font.capHeight / 2
                NSBezierPath(ovalIn: NSRect(x: 4, y: centerY - diameter / 2, width: diameter, height: diameter)).fill()
            }
            // A bar between the number and the code: the line's magic comments ran (or one
            // shows nothing, in the warning color).
            if let lineStart = number.lineStart, let marker = inlineMarkers[lineStart] {
                (marker == .warning ? theme.inlineWarning : theme.magicComment).withAlphaComponent(0.9).setFill()
                let height = max(8, font.capHeight + 6)
                let centerY = number.baseline - font.capHeight / 2
                NSBezierPath(roundedRect: NSRect(x: ruleThickness - 4.5, y: centerY - height / 2, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
            }
            // A fold control: ▸ when folded, ▾ when it can fold.
            if let lineStart = number.lineStart, let isFolded = foldMarkers[lineStart] {
                drawFoldControl(folded: isFolded, centerY: number.baseline - font.capHeight / 2)
            }
        }
    }

    private var foldMarkers: [Int: Bool] = [:]

    private func drawLightBulb(centerY: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: max(8, numberFont.pointSize - 1), weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemYellow]))
        guard let image = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: "Code actions")?.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: 2, y: centerY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawFoldControl(folded: Bool, centerY: CGFloat) {
        let centerX = ruleThickness - 6 - foldColumn / 2
        let size: CGFloat = 4
        let path = NSBezierPath()
        if folded {
            path.move(to: NSPoint(x: centerX - size / 2, y: centerY - size))
            path.line(to: NSPoint(x: centerX + size, y: centerY))
            path.line(to: NSPoint(x: centerX - size / 2, y: centerY + size))
        } else {
            path.move(to: NSPoint(x: centerX - size, y: centerY - size / 2))
            path.line(to: NSPoint(x: centerX + size, y: centerY - size / 2))
            path.line(to: NSPoint(x: centerX, y: centerY + size))
        }
        path.close()
        (folded ? theme.text : theme.gutterText).withAlphaComponent(folded ? 0.8 : 0.6).setFill()
        path.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < 16, let bulb = lightBulbLine, let placement = numberPlacements().first(where: { $0.line == bulb }),
           abs(point.y - (placement.baseline - numberFont.capHeight / 2)) <= max(10, numberFont.pointSize) {
            onLightBulbClick?()
            return
        }
        guard foldColumn > 0, point.x >= ruleThickness - 6 - foldColumn, point.x <= ruleThickness - 4,
              let textView = codeView, let folding else {
            super.mouseDown(with: event)
            return
        }
        // The line at the click: the placement whose row holds it.
        let font = numberFont
        let rowHeight = max(font.pointSize, (textView.font?.pointSize ?? 13) * 1.6)
        for number in numberPlacements() {
            guard let lineStart = number.lineStart, foldMarkers[lineStart] != nil else { continue }
            let centerY = number.baseline - font.capHeight / 2
            if abs(point.y - centerY) <= rowHeight / 2 {
                folding.toggle(lineStart: lineStart)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// The numbers' font: the editor's size less 2 points, with digits of one width.
    private var numberFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(9, (codeView?.font?.pointSize ?? 13) - 2), weight: .regular)
    }

    /// A line number to draw: its 0-based line, where the line starts (nil for the empty last
    /// line after a trailing newline), and the baseline it sits on, in the ruler's coordinates.
    struct NumberPlacement: Equatable {
        let line: Int
        let lineStart: Int?
        let baseline: CGFloat
    }

    /// The numbers of the lines in the visible part of the text view. Each sits on its line's
    /// text baseline: the top of the line's first fragment plus the baseline offset of a row in
    /// the editor's font and line height (`rowMetrics`), the same for every line, blank or not.
    /// A blank line's only glyph is its newline, which TextKit places at the bottom of the
    /// fragment, so glyph locations can't be used for it (#124). A wrapped line is numbered
    /// once, on its first fragment.
    func numberPlacements() -> [NumberPlacement] {
        guard let textView = codeView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return [] }
        let text = textView.string as NSString
        let row = rowMetrics(layoutManager: layoutManager)
        let originY = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y
        func baseline(_ fragment: NSRect, firstGlyph: Int? = nil) -> CGFloat {
            // A row that a fallback font (emoji, CJK) made taller has its text lower: follow it.
            if let firstGlyph, fragment.height > row.height + 0.5 {
                return originY + fragment.minY + layoutManager.location(forGlyphAt: firstGlyph).y
            }
            return originY + fragment.minY + row.baseline
        }

        // Empty document: only the extra line fragment exists.
        if text.length == 0 || layoutManager.numberOfGlyphs == 0 {
            return [NumberPlacement(line: 0, lineStart: nil, baseline: baseline(layoutManager.extraLineFragmentRect))]
        }
        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        // Numbers are for logical lines. With soft wrap the visible area can begin inside a
        // wrapped line, so start from the beginning of the line holding the first visible character.
        let firstLineStart = text.lineRange(for: NSRange(location: min(characterRange.location, text.length), length: 0)).location
        var lineNumber = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: firstLineStart), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        var placements: [NumberPlacement] = []
        var index = firstLineStart
        while index < NSMaxRange(characterRange) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            // A folded line (#22) shares its fold's row: no number of its own.
            if folding?.isLineFolded(lineRange.location) == true {
                lineNumber += 1
                index = NSMaxRange(lineRange)
                continue
            }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            guard glyphIndex < layoutManager.numberOfGlyphs else { break }
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            placements.append(NumberPlacement(line: lineNumber, lineStart: lineRange.location, baseline: baseline(fragment, firstGlyph: glyphIndex)))
            lineNumber += 1
            index = NSMaxRange(lineRange)
        }
        // A trailing newline leaves an empty last line drawn in the extra fragment.
        if NSMaxRange(characterRange) >= text.length, text.hasSuffix("\n") {
            placements.append(NumberPlacement(line: lineNumber, lineStart: nil, baseline: baseline(layoutManager.extraLineFragmentRect)))
        }
        return placements
    }

    /// A row of text in the editor's font and paragraph style: its line fragment's height, and
    /// its baseline's offset from the fragment's top. TextKit puts a taller line height's extra
    /// space above the text, and rounds a font's line height, so this lays out one character
    /// the way the editor does rather than working it out from the font's metrics.
    private struct RowMetrics {
        let font: NSFont
        let paragraph: NSParagraphStyle
        let height: CGFloat
        let baseline: CGFloat
    }

    private var cachedRowMetrics: RowMetrics?

    private func rowMetrics(layoutManager: NSLayoutManager) -> RowMetrics {
        let font = codeView?.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let paragraph = codeView?.defaultParagraphStyle ?? .default
        if let cached = cachedRowMetrics, cached.font == font, cached.paragraph == paragraph { return cached }
        let storage = NSTextStorage(string: "0", attributes: [.font: font, .paragraphStyle: paragraph])
        let sample = NSLayoutManager()
        sample.usesFontLeading = layoutManager.usesFontLeading
        sample.typesetterBehavior = layoutManager.typesetterBehavior
        storage.addLayoutManager(sample)
        sample.addTextContainer(NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)))
        let fragment = sample.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let metrics = RowMetrics(font: font, paragraph: paragraph, height: fragment.height, baseline: sample.location(forGlyphAt: 0).y)
        cachedRowMetrics = metrics
        return metrics
    }
}
