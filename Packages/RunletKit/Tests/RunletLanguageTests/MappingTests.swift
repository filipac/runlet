import Foundation
import Testing
@testable import RunletLanguage

struct MappingTests {
    @Test func syntheticTagAddsOneLineWithoutShiftingColumns() {
        let mapping = ScratchDocumentMapping(editorText: "$x = 1;")
        #expect(mapping.hasSyntheticTag)
        #expect(mapping.lspText(for: "$x = 1;") == "<?php\n$x = 1;\n;")
        #expect(mapping.toLSP(LSPPosition(line: 0, character: 3)) == LSPPosition(line: 1, character: 3))
        #expect(mapping.toEditor(LSPPosition(line: 1, character: 3)) == LSPPosition(line: 0, character: 3))
        // An import edit at the start of the first real line maps to the top of the snippet.
        #expect(mapping.toEditor(LSPPosition(line: 1, character: 0)) == LSPPosition(line: 0, character: 0))
        // Positions inside the synthetic tag clamp to the start.
        #expect(mapping.toEditor(LSPPosition(line: 0, character: 5)) == LSPPosition(line: 0, character: 0))
    }

    @Test func existingOpenTagIsUsedAsIs() {
        for text in ["<?php\necho 1;", "  <?php echo 1;", "<?= 1 ?>"] {
            let mapping = ScratchDocumentMapping(editorText: text)
            #expect(!mapping.hasSyntheticTag)
            #expect(mapping.lspText(for: text) == text)
            #expect(mapping.toEditor(LSPPosition(line: 1, character: 2)) == LSPPosition(line: 1, character: 2))
        }
    }

    @Test func lineIndexUsesUTF16AndHandlesLineEndings() {
        let text = "ä😀b\r\nsecond\nthird"
        let index = TextLineIndex(text)
        #expect(index.lineCount == 3)
        // "ä" is 1 UTF-16 unit, "😀" is 2.
        #expect(index.position(at: 3) == LSPPosition(line: 0, character: 3))
        #expect(index.offset(of: LSPPosition(line: 1, character: 0)) == 6)
        #expect(index.offset(of: LSPPosition(line: 2, character: 2)) == 15)
        #expect(index.position(at: 15) == LSPPosition(line: 2, character: 2))
        // Characters past the end of a line clamp to the line end, before the newline.
        #expect(index.offset(of: LSPPosition(line: 1, character: 99)) == 12)
        #expect(index.offset(of: LSPPosition(line: 9, character: 0)) == (text as NSString).length)
    }

    @Test func snippetSyntaxBecomesPlainText() {
        #expect(SnippetText.plain("PriceFormatter()$0") == ("PriceFormatter()", 16))
        #expect(SnippetText.plain("format(${1:\\$cents})$0") == ("format($cents)", 14))
        #expect(SnippetText.plain("$user").text == "$user")
        #expect(SnippetText.plain("where(${1:column}, ${2:value})").text == "where(column, value)")
        #expect(SnippetText.plain("where(${1:column}, ${2:value})").cursor == 6)
        #expect(SnippetText.plain("x ${1|a,b|} y").text == "x a y")
        #expect(SnippetText.plain("cost: \\$5").text == "cost: $5")
    }
}
