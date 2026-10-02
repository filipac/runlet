import AppKit

/// Gutter with line numbers, a static-diagnostic marker, and the execution-error marker.
final class LineNumberRulerView: NSRulerView {
    weak var codeView: CodeTextView?
    var theme = EditorTheme.resolve(dark: false) { didSet { needsDisplay = true } }
    /// 0-based lines with static diagnostics: severity 1 error, 2 warning.
    var diagnosticLines: [Int: Int] = [:] { didSet { needsDisplay = true } }
    /// 0-based line of the last execution error.
    var executionErrorLine: Int? { didSet { needsDisplay = true } }

    init(textView: CodeTextView) {
        self.codeView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
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

        // Count lines before the visible range.
        var lineNumber = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: characterRange.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        let relativeY = convert(NSPoint.zero, from: textView).y
        let selectedLine = text.substring(to: min(textView.selectedRange().location, text.length)).components(separatedBy: "\n").count - 1

        func draw(line: Int, fragmentRect: NSRect) {
            let y = fragmentRect.minY + relativeY + textView.textContainerOrigin.y
            let color = line == selectedLine ? theme.text : theme.gutterText
            let label = "\(line + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragmentRect.height - size.height) / 2), withAttributes: attributes)
            var markerColor: NSColor?
            if executionErrorLine == line { markerColor = .systemRed }
            else if let severity = diagnosticLines[line] { markerColor = severity == 1 ? .systemRed.withAlphaComponent(0.7) : .systemYellow }
            if let markerColor {
                markerColor.setFill()
                let diameter: CGFloat = executionErrorLine == line ? 7 : 5
                NSBezierPath(ovalIn: NSRect(x: 4, y: y + (fragmentRect.height - diameter) / 2, width: diameter, height: diameter)).fill()
            }
        }

        var index = characterRange.location
        var drewLast = false
        while index < NSMaxRange(characterRange) || (index == text.length && !drewLast) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(lineRange.location, max(0, text.length - 1)))
            var fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            if text.length == 0 || (index == text.length && text.hasSuffix("\n")) {
                fragmentRect = layoutManager.extraLineFragmentRect
            }
            draw(line: lineNumber, fragmentRect: fragmentRect)
            lineNumber += 1
            if index == text.length { drewLast = true; break }
            index = NSMaxRange(lineRange)
            if index == text.length && !text.hasSuffix("\n") { break }
        }
    }
}
