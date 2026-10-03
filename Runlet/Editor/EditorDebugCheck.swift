#if DEBUG
import AppKit

/// The `editor-check` step (RUNLET_DEBUG_STEPS, #87): checks that a failed line's red background
/// never outlives an edit or a new run. Each case uses an editor of its own in a window that is
/// never shown, and edits through the text view's own typing, deletion, and undo, as a user's
/// keys do (so its delegate callbacks run in the same order). Prints
/// `RUNLET_DEBUG_EDITOR_CHECK: <case>: ok` or `… FAILED: <why>` per case, then a summary.
@MainActor
enum EditorDebugCheck {
    private static let code = "<?php\n$a = 1;\nthrow new Exception(strlen('x'));\n$b = 2;\necho $a + $b;\n"

    @discardableResult
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ body: (Harness) -> String?) {
            let harness = Harness(code)
            if let problem = body(harness) {
                failures += 1
                log("\(name): FAILED: \(problem)")
            } else {
                log("\(name): ok")
            }
        }

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
            let open = (h.editor.text as NSString).range(of: "Exception(").location + 10
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
            return "backgrounds=[\(backgrounds.joined(separator: ", "))] ruler=\(editor.debugRulerErrorLine.map(String.init) ?? "none")"
        }

        func expectNoError() -> String? {
            backgrounds("error").isEmpty && editor.debugRulerErrorLine == nil ? nil : "red remains: \(describe())"
        }

        /// The whole line, and nothing else, is red, with the ruler's dot on it.
        func expectError(line: Int) -> String? {
            backgrounds("error") == [lineRange(line)] && editor.debugRulerErrorLine == line ? nil : "expected line \(line) only: \(describe())"
        }

        func expectText(_ expected: String) -> String? {
            editor.text == expected ? nil : "unexpected text \"\(editor.text.replacingOccurrences(of: "\n", with: "\\n"))\""
        }
    }
}
#endif
