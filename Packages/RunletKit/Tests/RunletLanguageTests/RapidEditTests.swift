import Foundation
import Testing
@testable import RunletLanguage

/// Acceptance 13: rapid edits must leave diagnostics that describe the latest text.
@Suite(.enabled(if: LanguageTestSupport.hasBinary, "run scripts/fetch-phpantom.sh"))
struct RapidEditTests {
    @Test func latestDiagnosticsReflectFinalText() async throws {
        let root = LanguageTestSupport.fixtures.appendingPathComponent("lsp-a")
        let session = await LanguageTestSupport.session(root)
        defer { Task { await session.stop() } }
        let updates = await session.diagnosticsUpdates()
        let uri = LanguageService.scratchURI(root: root, documentId: UUID())
        var mapping = ScratchDocumentMapping(editorText: "$a = ;")
        await session.open(uri: uri, text: mapping.lspText(for: "$a = ;"), version: 1)

        // 30 quick keystroke-sized edits alternating between broken and valid code, ending valid.
        var version = 1
        for index in 0..<30 {
            let text = index % 2 == 0 ? "$a = \(index);\n$b = ;" : "$a = \(index);"
            version += 1
            mapping = ScratchDocumentMapping(editorText: text)
            await session.change(uri: uri, text: mapping.lspText(for: text), version: version)
        }
        let finalText = "$a = 99;\n$b = $a + 1;"
        version += 1
        await session.change(uri: uri, text: ScratchDocumentMapping(editorText: finalText).lspText(for: finalText), version: version)

        // Collect everything published for this document for a short while.
        let collector = Task { () -> DiagnosticsUpdate? in
            var latest: DiagnosticsUpdate?
            for await update in updates where update.uri == uri { latest = update }
            return latest
        }
        try await Task.sleep(for: .seconds(3))
        collector.cancel()
        let last = await collector.value
        #expect(last != nil, "no diagnostics were published")
        let syntaxErrors = (last?.diagnostics ?? []).filter { $0.codeString == "syntax_error" }
        #expect(syntaxErrors.isEmpty, "stale syntax errors remained: \(syntaxErrors.map(\.message))")
        if let reported = last?.version {
            #expect(reported == version)
        }
    }
}
