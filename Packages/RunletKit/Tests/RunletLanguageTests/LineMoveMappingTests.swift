import Foundation
import RunletCore
import Testing
@testable import RunletLanguage

/// Move Line (#234) and the hidden lines PHPantom sees before a tagless snippet (`<?php` and a
/// driver's `@var` declarations): they are not in the editor's text, so lines never move into
/// or out of them, and the editor's first line stays the first line after them.
struct LineMoveMappingTests {
    private let declarations = ["app": "Illuminate\\Foundation\\Application"]

    @Test func theFirstEditorLineNeverMovesIntoTheHiddenLines() {
        let text = "$a = 1;\n$b = 2;"
        #expect(LineMove.move(.up, in: text, selection: NSRange(location: 2, length: 0)) == nil)
        let mapping = ScratchDocumentMapping(editorText: text, declarations: declarations)
        #expect(mapping.lineOffset == 2)
        let prefix = String(mapping.lspText(for: text).split(separator: "\n", omittingEmptySubsequences: false).prefix(2).joined(separator: "\n"))

        let result = LineMove.move(.up, in: text, selection: NSRange(location: 10, length: 0))!
        let moved = LineMove.apply(result.edits, to: text)
        #expect(moved == "$b = 2;\n$a = 1;")
        let after = ScratchDocumentMapping(editorText: moved, declarations: declarations)
        #expect(after.lineOffset == mapping.lineOffset)
        #expect(after.lspText(for: moved).hasPrefix(prefix + "\n$b = 2;\n$a = 1;"))
        // The moved line is the editor's first line, right after the hidden lines.
        #expect(after.toLSP(LSPPosition(line: 0, character: 0)) == LSPPosition(line: 2, character: 0))
    }

    @Test func movingTheLastLineDownLeavesTheSyntheticSuffixAfterTheText() {
        let text = "$a = 1;\n$b = 2"
        let result = LineMove.move(.down, in: text, selection: NSRange(location: 0, length: 0))!
        let moved = LineMove.apply(result.edits, to: text)
        #expect(moved == "$b = 2\n$a = 1;")
        #expect(ScratchDocumentMapping(editorText: moved).lspText(for: moved).hasSuffix("$a = 1;" + ScratchDocumentMapping.syntheticSuffix))
    }
}
