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

    @Test func droppedPlaceholdersLeaveTheCursorAtTheFirstTabStop() {
        // PHPantom 0.10.0 call snippets: required parameters become placeholders.
        #expect(SnippetText.plain("split(${1:\\$pattern})$0", placeholders: .drop) == ("split()", 6))
        #expect(SnippetText.plain("replace(${1:\\$search}, ${2:\\$replace})$0", placeholders: .drop) == ("replace(, )", 8))
        // No tab stop: `$0`, else nil (the caller uses the end).
        #expect(SnippetText.plain("count()$0", placeholders: .drop) == ("count()", 7))
        #expect(SnippetText.plain("count()", placeholders: .drop) == ("count()", nil))
        #expect(SnippetText.plain("$widget", placeholders: .drop) == ("$widget", nil))
        // The lowest-numbered stop wins over text order and `$0`.
        #expect(SnippetText.plain("f($0, ${2:b}, $1)", placeholders: .drop) == ("f(, , )", 6))
        #expect(SnippetText.plain("f(${1})", placeholders: .drop) == ("f()", 2))
        // Choices and nested placeholders collapse to nothing.
        #expect(SnippetText.plain("x(${1|a,b|})", placeholders: .drop) == ("x()", 2))
        #expect(SnippetText.plain("g(${1:outer ${2:inner} \\} end})$0", placeholders: .drop) == ("g()", 2))
        // Escapes outside placeholders still unescape; keep mode is unchanged.
        #expect(SnippetText.plain("cost: \\$5 ${1:x}", placeholders: .drop).text == "cost: $5 ")
        #expect(SnippetText.plain("split(${1:\\$pattern})$0") == ("split($pattern)", 15))
    }

    @Test func injectedVariableDeclarationsShiftOnlyLines() {
        let mapping = ScratchDocumentMapping(editorText: "$_app->", declarations: ["_app": "Slim\\App", "db": "Acme\\Db", "bad name": "X", "x": "evil */ code"])
        #expect(mapping.lineOffset == 3)
        let text = mapping.lspText(for: "$_app->")
        #expect(text.hasPrefix("<?php\n/** @var \\Slim\\App $_app */\n/** @var \\Acme\\Db $db */\n$_app->"))
        #expect(mapping.toLSP(LSPPosition(line: 0, character: 7)) == LSPPosition(line: 3, character: 7))
        #expect(mapping.toEditor(LSPPosition(line: 2, character: 4)) == LSPPosition(line: 0, character: 0))
        // Snippets with their own <?php get no hidden declarations.
        #expect(ScratchDocumentMapping(editorText: "<?php $_app", declarations: ["_app": "Slim\\App"]).lineOffset == 0)
    }
}
