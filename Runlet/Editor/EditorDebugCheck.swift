#if DEBUG
import AppKit

/// The `editor-check` step (RUNLET_DEBUG_STEPS): checks that a failed line's red background
/// (#87) and the bracket match (#113) never outlive an edit, a caret move, or a new run, and that
/// text loaded or inserted into the editor, even an empty one, or put back by undo, has the
/// editor's font, line height, tab stops, and color (#114). Each case uses an editor of its own in
/// a window that is never shown, and edits through the text view's own typing, deletion, and
/// undo, as a user's keys do (so its delegate callbacks run in the same order). Prints
/// `RUNLET_DEBUG_EDITOR_CHECK: <case>: ok` or `… FAILED: <why>` per case, then a summary.
@MainActor
enum EditorDebugCheck {
    private static let code = "<?php\n$a = 1;\nthrow new Exception(strlen('x'));\n$b = 2;\necho $a + $b;\n"
    /// Settings other than the defaults the harness starts with: a larger font, taller lines,
    /// wider tabs, dark colors.
    private static let otherSettings: EditorPreferences = {
        var settings = EditorPreferences()
        settings.fontSize = 17
        settings.lineHeight = 1.5
        settings.tabWidth = 8
        settings.dark = true
        return settings
    }()

    @discardableResult
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, text: String = code, _ body: (Harness) -> String?) {
            let harness = Harness(text)
            if let problem = body(harness) {
                failures += 1
                log("\(name): FAILED: \(problem)")
            } else {
                log("\(name): ok")
            }
        }

        // MARK: The failed line's red background (#87)

        check("insert lines above, then a successful run") { h in
            h.editor.showExecutionError(line: 3)
            if let problem = h.expectError(line: 3) { return "marking: " + problem }
            h.caret(line: 2)
            h.type("// a\n// b\n")
            if let problem = h.expectNoError() { return "after the edit: " + problem }
            h.editor.clearExecutionError() // the next run starts, and succeeds
            return h.expectNoError().map { "after the run: " + $0 }
        }

        check("delete the failed line") { h in
            h.editor.showExecutionError(line: 3)
            h.select(h.lineRange(3))
            h.edit { h.editor.textView.deleteBackward(nil) }
            if let problem = h.expectText(code.replacingOccurrences(of: "throw new Exception(strlen('x'));\n", with: "")) { return problem }
            return h.expectNoError()
        }

        check("edit inside the failed line") { h in
            h.editor.showExecutionError(line: 3)
            h.caret(line: 3, column: 7)
            h.type("X")
            if let problem = h.expectNoError() { return "after typing: " + problem }
            h.editor.showExecutionError(line: 3)
            h.caret(line: 3, column: 3)
            h.edit { h.editor.textView.deleteBackward(nil) }
            return h.expectNoError().map { "after deleting: " + $0 }
        }

        check("undo and redo") { h in
            h.caret(line: 3)
            h.type("// c\n")
            h.editor.showExecutionError(line: 4) // the run after the edit fails on the moved line
            h.undo.undo()
            if let problem = h.expectText(code) { return "undo: " + problem }
            if let problem = h.expectNoError() { return "after undo: " + problem }
            h.editor.showExecutionError(line: 3)
            h.undo.redo()
            if let problem = h.expectNoError() { return "after redo: " + problem }
            h.editor.showExecutionError(line: 4)
            h.undo.undo()
            return h.expectNoError().map { "after undo again: " + $0 }
        }

        check("a new failure on another line") { h in
            h.editor.showExecutionError(line: 3)
            h.editor.showExecutionError(line: 5)
            if let problem = h.expectError(line: 5) { return "without edits: " + problem }
            h.caret(line: 1)
            h.type("// d\n")
            h.editor.showExecutionError(line: 2)
            return h.expectError(line: 2).map { "after an edit above: " + $0 }
        }

        check("other highlights stay") { h in
            h.editor.showExecutionError(line: 3)
            // The caret after `Exception(` highlights that bracket and its match, over the red.
            guard let open = h.position(after: "Exception(") else { return "the fixture has no `Exception(`" }
            h.select(NSRange(location: open, length: 0))
            if h.backgrounds("bracket").count != 2 { return "no bracket match inside the failed line: \(h.describe())" }
            h.caret(line: 1)
            if let problem = h.expectError(line: 3) { return "after the caret left the brackets: " + problem }
            h.select(NSRange(location: open, length: 0))
            h.editor.clearExecutionError()
            if let problem = h.expectNoError() { return problem }
            if h.backgrounds("bracket").count != 2 { return "the bracket match went with the red: \(h.describe())" }
            let start = h.lineRange(3).location
            if h.editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: start, effectiveRange: nil) == nil {
                return "syntax colors went with the red"
            }
            return nil
        }

        // MARK: The bracket match (#113)

        check("type after an opening bracket") { h in
            guard let open = h.position(after: "strlen(") else { return "the fixture has no `strlen(`" }
            h.select(NSRange(location: open, length: 0))
            if let problem = h.expectBracketsForCaret(pair: true) { return "caret after `(`: " + problem }
            h.type("x")
            return h.expectBracketsForCaret().map { "after typing: " + $0 }
        }

        check("move the caret between pairs and away") { h in
            guard let outer = h.position(after: "Exception("), let inner = h.position(after: "strlen(") else { return "the fixture has no `Exception(strlen(`" }
            h.select(NSRange(location: outer, length: 0))
            if let problem = h.expectBracketsForCaret(pair: true) { return "after `Exception(`: " + problem }
            h.select(NSRange(location: inner, length: 0))
            if let problem = h.expectBracketsForCaret(pair: true) { return "after `strlen(`: " + problem }
            h.caret(line: 1)
            return h.expectBracketsForCaret().map { "on line 1: " + $0 }
        }

        check("delete a bracket") { h in
            guard let open = h.position(after: "strlen(") else { return "the fixture has no `strlen(`" }
            h.select(NSRange(location: open, length: 0))
            h.edit { h.editor.textView.deleteBackward(nil) }
            if let problem = h.expectText(code.replacingOccurrences(of: "strlen(", with: "strlen")) { return problem }
            return h.expectBracketsForCaret().map { "after deleting `(`: " + $0 }
        }

        check("bracket match through undo and redo") { h in
            h.caret(line: 1)
            h.type("// u\n")
            guard let open = h.position(after: "strlen(") else { return "the fixture has no `strlen(`" }
            h.select(NSRange(location: open, length: 0))
            if let problem = h.expectBracketsForCaret(pair: true) { return "before undo: " + problem }
            h.undo.undo() // removes the line above: the highlighted pair moves up
            if let problem = h.expectText(code) { return "undo: " + problem }
            if let problem = h.expectBracketsForCaret() { return "after undo: " + problem }
            guard let again = h.position(after: "strlen(") else { return "no `strlen(` after undo" }
            h.select(NSRange(location: again, length: 0))
            h.undo.redo() // puts it back: the pair moves down
            if let problem = h.expectBracketsForCaret() { return "after redo: " + problem }
            h.caret(line: 1)
            return h.expectBracketsForCaret().map { "on line 1 after redo: " + $0 }
        }

        check("edits elsewhere move the pair, and its lookup") { h in
            guard let open = h.position(after: "Exception(") else { return "the fixture has no `Exception(`" }
            h.select(NSRange(location: open, length: 0))
            // A line inserted above, the caret kept after `Exception(` (as a reload does).
            h.edit { h.editor.textView.replace(range: NSRange(location: 0, length: 0), with: "// top\n", selectAfter: NSRange(location: open + 7, length: 0)) }
            if let problem = h.expectBracketsForCaret(pair: true) { return "after an edit above: " + problem }
            if let problem = h.expectBracketLookupOnHighlights() { return "after an edit above: " + problem }
            // Text inserted between the brackets, the caret left where it is.
            guard let quote = h.position(after: "'x") else { return "the fixture has no `'x`" }
            let caret = h.editor.selectedRange
            h.edit { h.editor.textView.replace(range: NSRange(location: quote, length: 0), with: "yz", selectAfter: caret) }
            if let problem = h.expectBracketsForCaret(pair: true) { return "after an edit inside: " + problem }
            if let problem = h.expectBracketLookupOnHighlights() { return "after an edit inside: " + problem }
            h.caret(line: 1)
            return h.expectBracketsForCaret().map { "on line 1: " + $0 }
        }

        // MARK: Loaded and inserted text has the editor's attributes (#114)

        check("load into an empty editor", text: "") { h in
            h.edit { h.editor.replaceAll(with: code) } // a new tab, then Open, History, or `code:`
            return h.expectText(code) ?? h.expectEditorAttributes()
        }

        check("insert into an empty editor", text: "") { h in
            h.edit { h.editor.insert(code) }
            return h.expectText(code) ?? h.expectEditorAttributes()
        }

        check("reload an empty editor", text: "") { h in
            h.edit { h.editor.reload(with: code) } // its file changed on disk
            return h.expectText(code) ?? h.expectEditorAttributes()
        }

        check("load over text, after a settings change") { h in
            h.apply(otherSettings)
            let other = "<?php\n\tif ($a) {\n\t\techo 'tab stops';\n\t}\n"
            h.edit { h.editor.replaceAll(with: other) }
            return h.expectText(other) ?? h.expectEditorAttributes()
        }

        check("insert at the end") { h in
            h.select(NSRange(location: (code as NSString).length, length: 0))
            h.edit { h.editor.insert("$c = 3;\n") }
            return h.expectText(code + "$c = 3;\n") ?? h.expectEditorAttributes()
        }

        check("undo and redo a load into an empty editor", text: "") { h in
            h.edit { h.editor.replaceAll(with: code) }
            h.undo.undo()
            if let problem = h.expectText("") { return "undo: " + problem }
            h.undo.redo()
            if let problem = h.expectText(code) ?? h.expectEditorAttributes() { return "redo: " + problem }
            h.undo.undo()
            h.type("$") // typing into the editor the undo emptied
            return h.expectText("$") ?? h.expectEditorAttributes().map { "typing after undo: " + $0 }
        }

        check("undo after a settings change") { h in
            h.select(h.lineRange(3))
            h.edit { h.editor.textView.deleteBackward(nil) }
            h.apply(otherSettings)
            h.undo.undo() // puts back the line, deleted while the old settings applied
            return h.expectText(code) ?? h.expectEditorAttributes()
        }

        log("\(failures == 0 ? "passed" : "FAILED") (\(failures) failed)")
        return failures == 0
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_EDITOR_CHECK: \(message)\n".utf8))
    }

    /// One editor in a window that is never ordered in (the window supplies the undo manager).
    /// Each edit is its own undo group, like separate key presses.
    @MainActor
    final class Harness {
        let editor: EditorController
        let window: NSWindow
        let undo: UndoManager
        /// What the editor was last given (the defaults, as it starts with).
        private(set) var settings = EditorPreferences()

        init(_ code: String) {
            editor = EditorController(text: code, selection: NSRange(location: 0, length: 0))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = editor.scrollView
            undo = window.undoManager ?? UndoManager()
            undo.groupsByEvent = false
            editor.highlightNow()
        }

        func edit(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
            editor.textView.breakUndoCoalescing()
        }

        /// Typed at the caret (one character goes through the editor's bracket pairing).
        func type(_ text: String) {
            edit { editor.textView.insertText(text, replacementRange: editor.textView.selectedRange()) }
        }

        func lineRange(_ line: Int) -> NSRange {
            let text = editor.text as NSString
            var start = 0
            for _ in 1..<line { start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0))) }
            return text.lineRange(for: NSRange(location: start, length: 0))
        }

        /// The location just after the first `needle` in the text, or nil (the fixture changed).
        func position(after needle: String) -> Int? {
            let found = (editor.text as NSString).range(of: needle)
            return found.location == NSNotFound ? nil : NSMaxRange(found)
        }

        func caret(line: Int, column: Int = 1) {
            select(NSRange(location: lineRange(line).location + column - 1, length: 0))
        }

        func select(_ range: NSRange) {
            editor.textView.setSelectedRange(range)
        }

        func backgrounds(_ kind: String) -> [NSRange] {
            editor.debugBackgrounds.filter { $0.kind == kind }.map(\.range)
        }

        func describe() -> String {
            let text = editor.text as NSString
            let backgrounds = editor.debugBackgrounds.map { "\($0.kind) \(NSStringFromRange($0.range)) \"\(text.substring(with: $0.range).replacingOccurrences(of: "\n", with: "\\n"))\"" }
            return "backgrounds=[\(backgrounds.joined(separator: ", "))] ruler=\(editor.debugRulerErrorLine.map(String.init) ?? "none") caret=\(editor.selectedRange.location)"
        }

        func expectNoError() -> String? {
            backgrounds("error").isEmpty && editor.debugRulerErrorLine == nil ? nil : "red remains: \(describe())"
        }

        /// The whole line, and nothing else, is red, with the ruler's dot on it, and the red is
        /// looked up on that line only.
        func expectError(line: Int) -> String? {
            let range = lineRange(line)
            guard backgrounds("error") == [range], editor.debugRulerErrorLine == line else { return "expected line \(line) only: \(describe())" }
            return editor.debugHighlightSpans.error == [range] ? nil : "the red is looked up in \(editor.debugHighlightSpans.error.map(NSStringFromRange)), not line \(line)"
        }

        func expectText(_ expected: String) -> String? {
            editor.text == expected ? nil : "unexpected text \"\(editor.text.replacingOccurrences(of: "\n", with: "\\n"))\""
        }

        /// Settings changed, as Settings or the appearance does.
        func apply(_ settings: EditorPreferences) {
            self.settings = settings
            editor.applySettings(settings)
        }

        /// Every character has the editor's font, paragraph style (line height, tab stops), and
        /// color, and the lines are as tall as in an editor opened with this text (#114).
        func expectEditorAttributes() -> String? {
            guard let storage = editor.textView.textStorage else { return "no text storage" }
            let base = editor.debugBaseAttributes
            guard let font = base[.font] as? NSFont, let paragraph = base[.paragraphStyle] as? NSParagraphStyle,
                  let color = base[.foregroundColor] as? NSColor else { return "no base attributes" }
            var problem: String?
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, stop in
                let place = "\(NSStringFromRange(range)) \"\(storage.mutableString.substring(with: range).prefix(20).replacingOccurrences(of: "\n", with: "\\n"))\""
                let actualFont = attributes[.font] as? NSFont
                let actualParagraph = attributes[.paragraphStyle] as? NSParagraphStyle
                let actualColor = attributes[.foregroundColor] as? NSColor
                if actualFont != font {
                    problem = "font \(actualFont.map { "\($0.fontName) \($0.pointSize)" } ?? "none") at \(place), expected \(font.fontName) \(font.pointSize)"
                } else if actualParagraph != paragraph {
                    problem = "paragraph style at \(place): line height \(actualParagraph.map { "\($0.lineHeightMultiple)" } ?? "none"), tab interval \(actualParagraph.map { "\($0.defaultTabInterval)" } ?? "none"), expected \(paragraph.lineHeightMultiple), \(paragraph.defaultTabInterval)"
                } else if actualColor != color {
                    problem = "color \(actualColor.map { "\($0)" } ?? "none") at \(place), expected \(color)"
                }
                if problem != nil { stop.pointee = true }
            }
            if let problem { return problem }
            let reference = Harness(editor.text)
            reference.apply(settings)
            let (heights, expected) = (lineHeights(), reference.lineHeights())
            return heights == expected ? nil : "line heights \(heights), expected \(expected) as in a newly opened editor"
        }

        /// The height of each laid-out line (the ruler numbers these).
        func lineHeights() -> [CGFloat] {
            guard let layoutManager = editor.textView.layoutManager, let container = editor.textView.textContainer else { return [] }
            layoutManager.ensureLayout(for: container)
            var heights: [CGFloat] = []
            layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { rect, _, _, _, _ in
                heights.append((rect.height * 100).rounded() / 100)
            }
            return heights
        }

        /// Exactly the bracket before the caret and its match are highlighted (none when there's
        /// no such pair). With `pair`, the caret must be at a pair (the fixture is as expected).
        func expectBracketsForCaret(pair: Bool = false) -> String? {
            let expected = Set(caretPair())
            if pair, expected.count != 2 { return "no bracket pair at the caret: \(describe())" }
            let highlighted = Set(backgrounds("bracket").flatMap { Array($0.location..<NSMaxRange($0)) })
            return highlighted == expected ? nil : "expected brackets at \(expected.sorted()): \(describe())"
        }

        /// The bracket lookup is limited to the highlighted characters, wherever edits moved them.
        func expectBracketLookupOnHighlights() -> String? {
            let spans = Set(editor.debugHighlightSpans.bracket.flatMap { Array($0.location..<NSMaxRange($0)) })
            let highlighted = Set(backgrounds("bracket").flatMap { Array($0.location..<NSMaxRange($0)) })
            return spans == highlighted ? nil : "the bracket match is looked up at \(spans.sorted()), not \(highlighted.sorted())"
        }

        /// The bracket before the caret and its match, worked out from the text alone.
        private func caretPair() -> [Int] {
            let selection = editor.selectedRange
            let characters = Array(editor.text.utf16)
            guard selection.length == 0, selection.location > 0, selection.location <= characters.count else { return [] }
            let index = selection.location - 1
            let pairs: [UInt16: (UInt16, Int)] = [40: (41, 1), 91: (93, 1), 123: (125, 1), 41: (40, -1), 93: (91, -1), 125: (123, -1)]
            guard let (match, direction) = pairs[characters[index]] else { return [] }
            var depth = 0
            var cursor = index
            while cursor >= 0 && cursor < characters.count {
                if characters[cursor] == characters[index] { depth += 1 }
                if characters[cursor] == match { depth -= 1 }
                if depth == 0 { return [index, cursor] }
                cursor += direction
            }
            return []
        }
    }
}
#endif
