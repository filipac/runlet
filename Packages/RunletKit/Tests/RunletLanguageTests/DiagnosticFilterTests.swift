import Foundation
import Testing
@testable import RunletLanguage

struct DiagnosticFilterTests {
    func diagnostic(line: Int, code: String, severity: Int = 1) -> LSPDiagnostic {
        LSPDiagnostic(range: LSPRange(start: LSPPosition(line: line, character: 0), end: LSPPosition(line: line, character: 3)), severity: severity, code: .string(code), source: "phpantom", message: code)
    }

    @Test func hiddenLinesAndLimitedUnknownsAreDropped() {
        // Two hidden prefix lines (<?php + one @var), editor has 3 lines, then the hidden `;` line.
        let mapping = ScratchDocumentMapping(editorText: "a\nb\nc", declarations: ["_app": "Slim\\App"])
        let all = [
            diagnostic(line: 1, code: "unknown_class"),          // on the hidden @var line
            diagnostic(line: 2, code: "unknown_class"),          // editor line 0
            diagnostic(line: 3, code: "syntax_error"),           // editor line 1
            diagnostic(line: 5, code: "syntax_error"),           // hidden trailing `;` line
        ]
        let full = DiagnosticFilter.visible(all, mapping: mapping, editorLineCount: 3, limitedWorkspace: false)
        #expect(full.map(\.range.start.line) == [0, 1, 2], "EOF errors move to the last editor line")
        let limited = DiagnosticFilter.visible(all, mapping: mapping, editorLineCount: 3, limitedWorkspace: true)
        #expect(limited.map(\.codeString) == ["syntax_error", "syntax_error"])
    }
}
