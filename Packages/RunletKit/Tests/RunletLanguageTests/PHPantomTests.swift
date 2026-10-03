import Foundation
import RunletCore
import Testing
@testable import RunletLanguage

enum LanguageTestSupport {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("plan.md").path) { return url }
        }
        fatalError("repository root not found")
    }()

    static var binary: URL { repoRoot.appendingPathComponent("Resources/LSP/phpantom_lsp") }
    static var fixtures: URL { repoRoot.appendingPathComponent("Tests/Fixtures") }
    static var hasBinary: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-lsp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `modelOverlays: false` shows what PHPantom itself does, without Runlet's model copies.
    static func session(_ root: URL, phpVersion: String? = nil, kind: LanguageWorkspace.Kind = .project, modelOverlays: Bool = true) async -> LanguageServerSession {
        let session = LanguageServerSession(workspace: LanguageWorkspace(kind: kind, rootPath: root.path, phpVersion: phpVersion), binary: binary, configBase: tempDirectory(), modelOverlays: modelOverlays)
        await session.start()
        return session
    }

    /// Opens a tagless editor snippet and returns its LSP URI and mapping.
    static func open(_ session: LanguageServerSession, root: URL, editorText: String) async -> (uri: String, mapping: ScratchDocumentMapping) {
        let uri = LanguageService.scratchURI(root: root, documentId: UUID())
        let mapping = ScratchDocumentMapping(editorText: editorText)
        await session.open(uri: uri, text: mapping.lspText(for: editorText), version: 1)
        return (uri, mapping)
    }

    static func labels(_ items: [CompletionItem]) -> [String] {
        items.map { $0.label.components(separatedBy: "(").first ?? $0.label }
    }
}

/// Prototype-gate checks against the pinned PHPantom release binary.
@Suite(.serialized, .enabled(if: LanguageTestSupport.hasBinary, "run scripts/fetch-phpantom.sh"))
struct PHPantomTests {
    let fixtures = LanguageTestSupport.fixtures

    @Test func taglessScratchCompletionUsesProjectRootWithoutWritingFiles() async throws {
        let root = fixtures.appendingPathComponent("laravel-app")
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("vendor").path), "run scripts/setup-fixtures.sh")
        let session = await LanguageTestSupport.session(root)
        defer { Task { await session.stop() } }
        #expect(await session.state.isReady)

        let editorText = "$w = App\\Models\\Widget::query()->first();\n$w->"
        let (uri, mapping) = await LanguageTestSupport.open(session, root: root, editorText: editorText)
        let items = try await session.completion(uri: uri, position: mapping.toLSP(LSPPosition(line: 1, character: 4)), triggerCharacter: ">")
        let labels = LanguageTestSupport.labels(items)
        // Eloquent attributes inferred from migrations, plus model/builder methods.
        #expect(labels.contains("price"))
        #expect(labels.contains("name"))
        #expect(labels.contains("save"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".runlet-scratch").path))
    }

    @Test func importEditsMapBackToEditorCoordinates() async throws {
        let root = fixtures.appendingPathComponent("laravel-app")
        let session = await LanguageTestSupport.session(root)
        defer { Task { await session.stop() } }
        let editorText = "$price = 5;\n$f = new PriceForm"
        let (uri, mapping) = await LanguageTestSupport.open(session, root: root, editorText: editorText)
        let items = try await session.completion(uri: uri, position: mapping.toLSP(LSPPosition(line: 1, character: 18)), triggerCharacter: nil)
        let item = try #require(items.first { $0.label == "PriceFormatter" })
        let imports = item.additionalTextEdits.map(mapping.toEditor)
        let importEdit = try #require(imports.first)
        #expect(importEdit.newText.contains("use App\\Services\\PriceFormatter;"))
        #expect(importEdit.range.start == LSPPosition(line: 0, character: 0))
        // Applying the mapped edits to the visible editor text yields valid PHP.
        let insert = SnippetText.plain(item.textEdit?.newText ?? item.insertText ?? item.label).text
        var text = editorText as NSString
        let index = TextLineIndex(editorText)
        let replaceRange: NSRange
        if let edit = item.textEdit.map(mapping.toEditor) {
            replaceRange = index.nsRange(of: edit.range)
        } else {
            replaceRange = NSRange(location: text.length - "PriceForm".utf16.count, length: "PriceForm".utf16.count)
        }
        text = text.replacingCharacters(in: replaceRange, with: insert) as NSString
        text = text.replacingCharacters(in: index.nsRange(of: importEdit.range), with: importEdit.newText) as NSString
        #expect((text as String).hasPrefix("use App\\Services\\PriceFormatter;\n$price = 5;"))
        #expect((text as String).hasSuffix("new PriceFormatter()"))
    }

    @Test func hoverSignatureHelpAndDiagnosticRangesWithUnicode() async throws {
        let root = fixtures.appendingPathComponent("lsp-b")
        let session = await LanguageTestSupport.session(root)
        defer { Task { await session.stop() } }
        let diagnosticsStream = await session.diagnosticsUpdates()
        // "é" and "😀" precede the error on its line; positions are UTF-16 on both sides.
        let editorText = "$t = new App\\Thing();\n$t->onlyInProjectB(1, \n$s = 'é😀'; $y = ;"
        let (uri, mapping) = await LanguageTestSupport.open(session, root: root, editorText: editorText)

        let hover = try await session.hover(uri: uri, position: mapping.toLSP(LSPPosition(line: 1, character: 8)))
        #expect(hover?.markdown.contains("onlyInProjectB") == true)

        let signature = try await session.signatureHelp(uri: uri, position: mapping.toLSP(LSPPosition(line: 1, character: 22)))
        let help = try #require(signature)
        #expect(help.signatures.first?.label.contains("int $count") == true)
        #expect(help.activeParameter == 1)

        var syntaxError: LSPDiagnostic?
        for await update in diagnosticsStream where update.uri == uri {
            if let match = update.diagnostics.first(where: { $0.message.lowercased().contains("syntax") || $0.codeString == "syntax_error" }) {
                syntaxError = match
                break
            }
        }
        let diagnostic = try #require(syntaxError)
        let editorRange = mapping.toEditor(diagnostic.range)
        let nsRange = TextLineIndex(editorText).nsRange(of: editorRange)
        // The offending `;` after `$y = ` on line 3 (0-based line 2).
        #expect(editorRange.start.line == 2 || editorRange.start.line == 1)
        #expect(nsRange.location + nsRange.length <= (editorText as NSString).length)
    }

    @Test func workspacesAreIsolatedAndRespectProjectConfiguration() async throws {
        let rootA = fixtures.appendingPathComponent("lsp-a")
        let rootB = fixtures.appendingPathComponent("lsp-b")
        let configBefore = try String(contentsOf: rootB.appendingPathComponent(".phpantom.toml"), encoding: .utf8)
        let sessionA = await LanguageTestSupport.session(rootA)
        let sessionB = await LanguageTestSupport.session(rootB, phpVersion: "8.2")
        defer { Task { await sessionA.stop(); await sessionB.stop() } }

        let text = "$t = new App\\Thing();\n$t->"
        let a = await LanguageTestSupport.open(sessionA, root: rootA, editorText: text)
        let b = await LanguageTestSupport.open(sessionB, root: rootB, editorText: text)
        let position = LSPPosition(line: 1, character: 4)
        let labelsA = LanguageTestSupport.labels(try await sessionA.completion(uri: a.uri, position: a.mapping.toLSP(position), triggerCharacter: ">"))
        let labelsB = LanguageTestSupport.labels(try await sessionB.completion(uri: b.uri, position: b.mapping.toLSP(position), triggerCharacter: ">"))
        #expect(labelsA.contains("onlyInProjectA") && !labelsA.contains("onlyInProjectB"))
        #expect(labelsB.contains("onlyInProjectB") && !labelsB.contains("onlyInProjectA"))
        // The project's own .phpantom.toml is untouched.
        #expect(try String(contentsOf: rootB.appendingPathComponent(".phpantom.toml"), encoding: .utf8) == configBefore)
    }

    @Test func externalAnalyzersAreNotLaunchedImplicitly() async throws {
        // A project that would auto-detect PHPStan and Pint: require-dev + phpstan.neon + vendor/bin scripts.
        let root = LanguageTestSupport.tempDirectory()
        let marker = root.appendingPathComponent("external-tool-ran")
        try #"{"require-dev":{"phpstan/phpstan":"^2","laravel/pint":"^1"},"autoload":{"psr-4":{"App\\":"src/"}}}"#.write(to: root.appendingPathComponent("composer.json"), atomically: true, encoding: .utf8)
        try "parameters:\n  level: 5\n".write(to: root.appendingPathComponent("phpstan.neon"), atomically: true, encoding: .utf8)
        // Without Runlet's config, this project setting makes PHPantom auto-launch vendor/bin/phpstan
        // (verified manually against 0.10.0; see docs/compatibility.md).
        try "[diagnostics]\nworkspace = true\n".write(to: root.appendingPathComponent(".phpantom.toml"), atomically: true, encoding: .utf8)
        let bin = root.appendingPathComponent("vendor/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "<?php\nnamespace App;\nclass A { public function f(): int { return 'x'; } }\n".write(to: root.appendingPathComponent("src/A.php"), atomically: true, encoding: .utf8)
        for tool in ["phpstan", "pint", "phpcs", "php-cs-fixer", "mago"] {
            let script = bin.appendingPathComponent(tool)
            try "#!/bin/sh\necho \(tool) >> '\(marker.path)'\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let session = await LanguageTestSupport.session(root)
        let uri = root.appendingPathComponent("src/A.php").absoluteString
        await session.open(uri: uri, text: try String(contentsOf: root.appendingPathComponent("src/A.php"), encoding: .utf8), version: 1)
        await session.change(uri: uri, text: "<?php\nnamespace App;\nclass A { public function f(): int { return 1; } }\n", version: 2)
        _ = try await session.completion(uri: uri, position: LSPPosition(line: 2, character: 10), triggerCharacter: nil)
        try await Task.sleep(for: .seconds(5))
        await session.stop()
        #expect(!FileManager.default.fileExists(atPath: marker.path), "an external tool was launched: \((try? String(contentsOf: marker, encoding: .utf8)) ?? "")")
    }

    @Test func basicWorkspaceOffersCorePHPCompletion() async throws {
        let root = LanguageTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = await LanguageTestSupport.session(root, kind: .basic)
        defer { Task { await session.stop() } }
        let (uri, mapping) = await LanguageTestSupport.open(session, root: root, editorText: "array_ma")
        let labels = LanguageTestSupport.labels(try await session.completion(uri: uri, position: mapping.toLSP(LSPPosition(line: 0, character: 8)), triggerCharacter: nil))
        #expect(labels.contains("array_map"))
    }

    @Test func crashedServerRestartsAndRestoresDocuments() async throws {
        let root = fixtures.appendingPathComponent("lsp-a")
        let session = await LanguageTestSupport.session(root)
        defer { Task { await session.stop() } }
        let text = "$t = new App\\Thing();\n$t->"
        let (uri, mapping) = await LanguageTestSupport.open(session, root: root, editorText: text)
        let firstPid = await session.serverPid
        await session.simulateCrash()
        // Wait for the automatic restart.
        var restarted = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if await session.state.isReady, await session.serverPid != firstPid {
                restarted = true
                break
            }
        }
        #expect(restarted)
        let labels = LanguageTestSupport.labels(try await session.completion(uri: uri, position: mapping.toLSP(LSPPosition(line: 1, character: 4)), triggerCharacter: ">"))
        #expect(labels.contains("onlyInProjectA"))
    }

    @Test func runsWithoutHostPHPOnPath() async throws {
        // PHPantom is launched with PATH=/usr/bin:/bin; macOS ships no PHP there.
        #expect(!FileManager.default.isExecutableFile(atPath: "/usr/bin/php"))
        let session = await LanguageTestSupport.session(fixtures.appendingPathComponent("lsp-a"))
        #expect(await session.state.isReady)
        await session.stop()
    }
}
