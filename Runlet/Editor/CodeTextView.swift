import AppKit

/// Callbacks the text view uses to coordinate with its controller.
@MainActor
protocol CodeTextViewDelegate: AnyObject {
    /// Lets the completion popup consume navigation keys. Returns true if handled.
    func codeTextView(_ view: CodeTextView, handleCommand selector: Selector) -> Bool
    func codeTextView(_ view: CodeTextView, didType text: String)
    func codeTextView(_ view: CodeTextView, mouseRestedAt characterIndex: Int?, point: NSPoint)
    func codeTextViewRequestedCompletion(_ view: CodeTextView)
}

/// An NSTextView configured for PHP code: no smart substitutions, auto-indentation,
/// bracket pairing, soft tabs, line comments, and hooks for completion and hover.
final class CodeTextView: NSTextView {
    weak var codeDelegate: CodeTextViewDelegate?
    var tabWidth = 4
    var insertSpaces = true
    private var hoverTimer: Timer?
    private var trackingArea: NSTrackingArea?

    static let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]
    static let closers: Set<String> = [")", "]", "}", "\"", "'"]

    func configureForCode() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        displaysLinkToolTips = false
        allowsCharacterPickerTouchBarItem = false
        writingToolsBehavior = .none
        isAutomaticSpellingCorrectionEnabled = false
        inlinePredictionType = .no
        textContainerInset = NSSize(width: 4, height: 8)
        isHorizontallyResizable = true
        isVerticallyResizable = true
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setAccessibilityIdentifier("code-editor")
        setAccessibilityLabel("PHP editor")
    }

    var indentUnit: String { insertSpaces ? String(repeating: " ", count: tabWidth) : "\t" }

    private var nsText: NSString { string as NSString }

    private func character(at index: Int) -> String? {
        guard index >= 0, index < nsText.length else { return nil }
        return nsText.substring(with: NSRange(location: index, length: 1))
    }

    // MARK: Key handling

    override func doCommand(by selector: Selector) {
        if codeDelegate?.codeTextView(self, handleCommand: selector) == true { return }
        super.doCommand(by: selector)
    }

    override func keyDown(with event: NSEvent) {
        // Ctrl+Space or Option+Escape requests completion explicitly.
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == " " {
            codeDelegate?.codeTextViewRequestedCompletion(self)
            return
        }
        super.keyDown(with: event)
    }

    override func complete(_ sender: Any?) {
        codeDelegate?.codeTextViewRequestedCompletion(self)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string,
              hasMarkedText() == false, text.count == 1 else {
            super.insertText(insertString, replacementRange: replacementRange)
            if let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string {
                codeDelegate?.codeTextView(self, didType: text)
            }
            return
        }
        let selection = selectedRange()
        let next = character(at: selection.location)

        // Typing a closer that is already next: step over it.
        if selection.length == 0, Self.closers.contains(text), next == text, !(text == "\"" || text == "'") || isInsideAutoPair(selection.location, quote: text) {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            codeDelegate?.codeTextView(self, didType: text)
            return
        }

        if let closer = Self.pairs[text], shouldAutoPair(text, at: selection) {
            if selection.length > 0 {
                // Wrap the selection.
                let selected = nsText.substring(with: selection)
                replace(range: selection, with: text + selected + closer, selectAfter: NSRange(location: selection.location + 1, length: selection.length))
            } else {
                replace(range: selection, with: text + closer, selectAfter: NSRange(location: selection.location + 1, length: 0))
            }
            codeDelegate?.codeTextView(self, didType: text)
            return
        }

        super.insertText(insertString, replacementRange: replacementRange)
        codeDelegate?.codeTextView(self, didType: text)
    }

    private func isInsideAutoPair(_ location: Int, quote: String) -> Bool {
        // Count quotes earlier on the line; odd means we are inside a string.
        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        let before = nsText.substring(with: NSRange(location: lineRange.location, length: location - lineRange.location))
        return before.filter { String($0) == quote }.count % 2 == 1
    }

    private func shouldAutoPair(_ opener: String, at selection: NSRange) -> Bool {
        if selection.length > 0 { return true }
        let next = character(at: selection.location)
        let nextAllows = next == nil || next == "\n" || next == " " || next == "\t" || next.map { Self.closers.contains($0) || $0 == ";" || $0 == "," } == true
        guard nextAllows else { return false }
        if opener == "\"" || opener == "'" {
            // Avoid pairing after identifier characters (e.g. don't, it's) or an escape.
            let previous = character(at: selection.location - 1)
            if let previous, previous.rangeOfCharacter(from: .alphanumerics) != nil || previous == "\\" { return false }
            if isInsideAutoPair(selection.location, quote: opener) { return false }
        }
        return true
    }

    /// Replaces text through the text system so undo, delegates, and LSP sync all see it.
    func replace(range: NSRange, with text: String, selectAfter: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let selectAfter { setSelectedRange(selectAfter) }
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = nsText.substring(with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        let previous = line.trimmingCharacters(in: .whitespaces).last.map(String.init)
        let next = character(at: selection.location + selection.length)
        var insert = "\n" + indentation
        var cursorOffset = insert.utf16.count
        if let previous, ["{", "[", "("].contains(previous) {
            insert += indentUnit
            cursorOffset = insert.utf16.count
            if let next, let opener = Self.pairs[previous], opener == next {
                insert += "\n" + indentation
            }
        }
        replace(range: selection, with: insert, selectAfter: NSRange(location: selection.location + cursorOffset, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, nsText.substring(with: selection).contains("\n") {
            shiftLines(in: selection, indent: true)
            return
        }
        if insertSpaces {
            let lineStart = nsText.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let column = selection.location - lineStart
            let spaces = tabWidth - (column % tabWidth)
            replace(range: selection, with: String(repeating: " ", count: spaces), selectAfter: NSRange(location: selection.location + spaces, length: 0))
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        shiftLines(in: selectedRange(), indent: false)
    }

    /// Indents or outdents every line touched by `range` as a single undoable edit.
    func shiftLines(in range: NSRange, indent: Bool) {
        let lines = nsText.lineRange(for: range)
        let original = nsText.substring(with: lines)
        var parts = original.components(separatedBy: "\n")
        let trailingNewline = original.hasSuffix("\n")
        if trailingNewline { parts.removeLast() }
        let shifted = parts.map { line -> String in
            if indent { return line.isEmpty ? line : indentUnit + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(spaces, tabWidth)))
        }
        let replacement = shifted.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        replace(range: lines, with: replacement, selectAfter: NSRange(location: lines.location, length: (replacement as NSString).length - (trailingNewline ? 1 : 0)))
    }

    /// Toggles `// ` line comments on the selected lines.
    @objc func toggleLineComment(_ sender: Any?) {
        let lines = nsText.lineRange(for: selectedRange())
        let original = nsText.substring(with: lines)
        var parts = original.components(separatedBy: "\n")
        let trailingNewline = original.hasSuffix("\n")
        if trailingNewline { parts.removeLast() }
        let nonEmpty = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let minIndent = nonEmpty.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let toggled = parts.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allCommented {
                guard let range = line.range(of: "//") else { return line }
                var result = line
                result.removeSubrange(range)
                if result[range.lowerBound...].hasPrefix(" ") { result.remove(at: range.lowerBound) }
                return result
            }
            let index = line.index(line.startIndex, offsetBy: minIndent)
            return String(line[..<index]) + "// " + String(line[index...])
        }
        let replacement = toggled.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        replace(range: lines, with: replacement, selectAfter: NSRange(location: lines.location, length: (replacement as NSString).length - (trailingNewline ? 1 : 0)))
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, selection.location > 0,
           let previous = character(at: selection.location - 1), let closer = Self.pairs[previous],
           character(at: selection.location) == closer {
            replace(range: NSRange(location: selection.location - 1, length: 2), with: "", selectAfter: NSRange(location: selection.location - 1, length: 0))
            codeDelegate?.codeTextView(self, didType: "")
            return
        }
        super.deleteBackward(sender)
        codeDelegate?.codeTextView(self, didType: "")
    }

    // MARK: Paste as plain text

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoverTimer?.invalidate()
        let point = convert(event.locationInWindow, from: nil)
        codeDelegate?.codeTextView(self, mouseRestedAt: nil, point: point)
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.codeDelegate?.codeTextView(self, mouseRestedAt: self.characterIndexForHover(at: point), point: point)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverTimer?.invalidate()
        codeDelegate?.codeTextView(self, mouseRestedAt: nil, point: .zero)
    }

    private func characterIndexForHover(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// Screen rect of the character at `index`, for anchoring popups.
    func screenRect(forCharacterAt index: Int) -> NSRect {
        let rect = firstRect(forCharacterRange: NSRange(location: max(0, min(index, nsText.length)), length: 0), actualRange: nil)
        return rect
    }
}
