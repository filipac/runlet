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

    @objc private func refresh() {
        let lines = max(1, (codeView?.string as NSString?)?.components(separatedBy: "\n").count ?? 1)
        let digits = max(2, String(lines).count)
        let thickness = CGFloat(digits) * 8 + 26
        if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        theme.gutterBackground.setFill()
        bounds.fill()

        let text = textView.string as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, (textView.font?.pointSize ?? 13) - 2), weight: .regular)
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Numbers are for logical lines. With soft wrap the visible area can begin inside a
        // wrapped line, so start from the beginning of the line holding the first visible character.
        let firstLineStart = text.lineRange(for: NSRange(location: min(characterRange.location, text.length), length: 0)).location
        var lineNumber = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: firstLineStart), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        let relativeY = convert(NSPoint.zero, from: textView).y
        let selectedLine = text.substring(to: min(textView.selectedRange().location, text.length)).components(separatedBy: "\n").count - 1
        // Baseline offset of a line's first glyph within its fragment, reused for the empty last line.
        var lastBaseline: CGFloat?

        func draw(line: Int, fragmentRect: NSRect, baseline: CGFloat?, lineStart: Int = -1) {
            let top = fragmentRect.minY + relativeY + textView.textContainerOrigin.y
            let color = line == selectedLine ? theme.text : theme.gutterText
            let label = "\(line + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = label.size(withAttributes: attributes)
            // Align the number with the text's baseline: the gutter font is smaller, and extra
            // line height is not split evenly above and below the glyphs.
            let labelBaseline = baseline.map { top + $0 } ?? top + (fragmentRect.height + size.height) / 2 + font.descender
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: labelBaseline - font.ascender), withAttributes: attributes)
            var markerColor: NSColor?
            if executionErrorLine == line { markerColor = .systemRed }
            else if let severity = diagnosticLines[line] { markerColor = severity == 1 ? .systemRed.withAlphaComponent(0.7) : .systemYellow }
            if let markerColor {
                markerColor.setFill()
                let diameter: CGFloat = executionErrorLine == line ? 7 : 5
                let centerY = labelBaseline - font.capHeight / 2
                NSBezierPath(ovalIn: NSRect(x: 4, y: centerY - diameter / 2, width: diameter, height: diameter)).fill()
            }
            // A bar between the number and the code: the line's magic comments ran (or one
            // shows nothing, in the warning color).
            if let marker = inlineMarkers[lineStart] {
                (marker == .warning ? theme.inlineWarning : theme.magicComment).withAlphaComponent(0.9).setFill()
                let height = max(8, font.capHeight + 6)
                let centerY = labelBaseline - font.capHeight / 2
                NSBezierPath(roundedRect: NSRect(x: ruleThickness - 4.5, y: centerY - height / 2, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }

        // Empty document: only the extra line fragment exists.
        if text.length == 0 || layoutManager.numberOfGlyphs == 0 {
            draw(line: 0, fragmentRect: layoutManager.extraLineFragmentRect, baseline: nil)
            return
        }
        var index = firstLineStart
        while index < NSMaxRange(characterRange) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            guard glyphIndex < layoutManager.numberOfGlyphs else { break }
            // A wrapped line is numbered once, on its first fragment.
            let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let baseline = layoutManager.location(forGlyphAt: glyphIndex).y
            lastBaseline = baseline
            draw(line: lineNumber, fragmentRect: fragmentRect, baseline: baseline, lineStart: lineRange.location)
            lineNumber += 1
            index = NSMaxRange(lineRange)
        }
        // A trailing newline leaves an empty last line drawn in the extra fragment.
        if NSMaxRange(characterRange) >= text.length, text.hasSuffix("\n") {
            draw(line: lineNumber, fragmentRect: layoutManager.extraLineFragmentRect, baseline: lastBaseline)
        }
    }
}
