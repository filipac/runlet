import Foundation
import RunletCore
import Testing
@testable import RunletLanguage

/// Navigation (#22) against the pinned PHPantom binary on the Laravel fixture, through the same
/// scratch-document mapping and destinations the editor uses.
@Suite(.serialized, .enabled(if: LanguageTestSupport.hasBinary, "run scripts/fetch-phpantom.sh"))
struct NavigationIntegrationTests {
    let root = LanguageTestSupport.fixtures.appendingPathComponent("laravel-app")

    private static let snippet = """
        $f = new PriceFormatter();
        $w = App\\Models\\Widget::query()->first();
        function local_helper(int $count, string $label) { return $count; }
        local_helper(3, 'x');
        $x = local_helper(4, 'y');
        $names = array_map(fn ($n) => $n, [1]);
        function folded(array $items): int
        {
            $sum = 0;
            foreach ($items as $item) {
                $sum += $item;
            }
            return $sum;
        }
        echo $x;
        """

    private func open(_ session: LanguageServerSession) async -> (uri: String, mapping: ScratchDocumentMapping, resolver: NavigationResolver) {
        let (uri, mapping) = await LanguageTestSupport.open(session, root: root, editorText: Self.snippet)
        let resolver = NavigationResolver(scratchURI: uri, mapping: mapping, editorLineCount: TextLineIndex(Self.snippet).lineCount,
                                          workspaceRoot: root.path, workspaceKind: .project, hasExternalEditor: true)
        return (uri, mapping, resolver)
    }

    @Test func phpantomAdvertisesTheNavigationFeatures() async throws {
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("vendor").path), "run scripts/setup-fixtures.sh")
        let session = await LanguageTestSupport.session(root)
        defer { Task { await session.stop() } }
        for feature in LanguageFeature.allCases {
            #expect(await session.supports(feature), "\(feature)")
        }
        #expect(LanguageNavigation.resolvesCodeActions(in: await session.serverCapabilities))
    }

    @Test func definitionsGoToTheProjectVendorAndTheTab() async throws {
        let session = await LanguageTestSupport.session(root)
        defer { Task { await session.stop() } }
        let (uri, mapping, resolver) = await open(session)

        // `Widget` (editor line 1) is a project file.
        let widget = try await session.definition(uri: uri, position: mapping.toLSP(LSPPosition(line: 1, character: 18)))
        guard case .projectFile(let model)? = widget.first.map(resolver.destination) else {
            Issue.record("expected a project file, got \(widget)")
            return
        }
        #expect(model.displayPath == "app/Models/Widget.php")
        let source = try String(contentsOfFile: try #require(model.path), encoding: .utf8).components(separatedBy: "\n")
        #expect(source[model.range.start.line].contains("class Widget"))

        // `query()` is Eloquent's, in vendor/: a peek.
        let query = try await session.definition(uri: uri, position: mapping.toLSP(LSPPosition(line: 1, character: 27)))
        guard case .peek(let vendor)? = query.first.map(resolver.destination) else {
            Issue.record("expected a vendor peek, got \(query)")
            return
        }
        #expect(vendor.origin == .vendor && vendor.displayPath.hasSuffix("Illuminate/Database/Eloquent/Model.php"))
        let vendorSource = try String(contentsOfFile: try #require(vendor.path), encoding: .utf8).components(separatedBy: "\n")
        #expect(vendorSource[vendor.range.start.line].contains("function query"))

        // A function declared in the tab: the caret goes to editor line 2, not the LSP line.
        let helper = try await session.definition(uri: uri, position: mapping.toLSP(LSPPosition(line: 3, character: 3)))
        guard case .scratch(let range)? = helper.first.map(resolver.destination) else {
            Issue.record("expected the tab, got \(helper)")
            return
        }
        #expect(range.start.line == 2)
        let line = Self.snippet.components(separatedBy: "\n")[2] as NSString
        #expect(line.substring(from: range.start.character).hasPrefix("local_helper"))
    }

    @Test func referencesMapToEditorLines() async throws {
        let session = await LanguageTestSupport.session(root)
        defer { Task { await session.stop() } }
        let (uri, mapping, resolver) = await open(session)
        let locations = try await session.references(uri: uri, position: mapping.toLSP(LSPPosition(line: 2, character: 12)))
        let rows = ReferenceList.make(locations, resolver: resolver, editorText: Self.snippet) { _, _ in nil }
        #expect(rows.allSatisfy { $0.isInTab })
        #expect(rows.map(\.line) == [3, 4, 5])
        #expect(rows.map(\.snippet) == ["function local_helper(int $count, string $label) { return $count; }", "local_helper(3, 'x');", "$x = local_helper(4, 'y');"])
        #expect(rows[2].highlight == 5..<17)

        // `Widget` is referenced in the project too (the seeder), read from disk.
        let widget = try await session.references(uri: uri, position: mapping.toLSP(LSPPosition(line: 1, character: 18)))
        let widgetRows = ReferenceList.make(widget, resolver: resolver, editorText: Self.snippet) { file, line in
            let lines = file.path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.components(separatedBy: "\n") ?? []
            return line < lines.count ? lines[line] : nil
        }
        #expect(widgetRows.first?.label == "This tab")
        #expect(widgetRows.contains { $0.label == "app/Models/Widget.php" && $0.snippet.contains("class Widget") })
    }

    @Test func inlayHintsPlaceParameterNamesAndTypes() async throws {
        let session = await LanguageTestSupport.session(root)
        defer { Task { await session.stop() } }
        let (uri, mapping, _) = await open(session)
        let lines = TextLineIndex(Self.snippet).lineCount
        let hints = try await session.inlayHints(uri: uri, range: InlayHintPlacement.requestRange(visibleLines: 0...(lines - 1), editorLineCount: lines, mapping: mapping))
        // PHPantom 0.10.0 sometimes also sends kindless "N references" hints; Runlet leaves them out.
        let placed = InlayHintPlacement.place(hints, mapping: mapping, editorText: Self.snippet)
        let text = Self.snippet as NSString
        func before(_ hint: EditorInlayHint) -> String { text.substring(with: NSRange(location: hint.offset, length: min(3, text.length - hint.offset))) }
        let count = try #require(placed.first { $0.label == "count:" })
        #expect(before(count) == "3, ")
        #expect(placed.contains { $0.label == "label:" && before($0) == "'x'" })
        // Unsupported in PHPantom 0.10.0: inferred types only for arrow-function parameters.
        let type = try #require(placed.first { $0.kind == .type })
        #expect(type.label == "int" && before(type).hasPrefix("$n"))
    }

    @Test func importClassAppliesToTheTabOnly() async throws {
        let session = await LanguageTestSupport.session(root)
        defer { Task { await session.stop() } }
        let (uri, mapping, _) = await open(session)
        let range = LSPRange(start: mapping.toLSP(LSPPosition(line: 0, character: 9)), end: mapping.toLSP(LSPPosition(line: 0, character: 23)))
        let actions = LSPCodeAction.ordered(try await session.codeActions(uri: uri, range: range, diagnostics: []))
        let importAction = try #require(actions.first)
        #expect(importAction.title == "Import `App\\Services\\PriceFormatter`" && importAction.isQuickFix)
        let resolved = try await session.resolve(importAction)
        let edits = try ScratchEditPlanner.plan(try #require(resolved.edit), scratchURI: uri, mapping: mapping, editorText: Self.snippet).get()
        let result = ScratchEditPlanner.apply(edits, to: Self.snippet)
        #expect(result.hasPrefix("use App\\Services\\PriceFormatter;\n$f = new PriceFormatter();"))
        // A refactoring that PHPantom computes on request (codeAction/resolve).
        let inline = try #require(try await session.codeActions(uri: uri, range: LSPRange(start: mapping.toLSP(LSPPosition(line: 4, character: 0)), end: mapping.toLSP(LSPPosition(line: 4, character: 2))), diagnostics: [])
            .first { $0.title == "Inline variable $x" })
        #expect(inline.needsResolve)
        let inlineEdit = try #require(try await session.resolve(inline).edit)
        let inlined = ScratchEditPlanner.apply(try ScratchEditPlanner.plan(inlineEdit, scratchURI: uri, mapping: mapping, editorText: Self.snippet).get(), to: Self.snippet)
        #expect(!inlined.contains("$x = local_helper(4, 'y');"))
        #expect(inlined.hasSuffix("echo local_helper(4, 'y');"))
    }

    @Test func foldingRangesCoverTheTabsBlocks() async throws {
        let session = await LanguageTestSupport.session(root)
        defer { Task { await session.stop() } }
        let (uri, mapping, _) = await open(session)
        let ranges = try await session.foldingRanges(uri: uri)
        // `function folded` spans editor lines 6–13, its `foreach` 9–11.
        let editorRanges = ranges.map { (mapping.toEditor(LSPPosition(line: $0.startLine, character: 0)).line, mapping.toEditor(LSPPosition(line: $0.endLine, character: 0)).line) }
        #expect(editorRanges.contains { $0 == (7, 13) || $0 == (6, 13) })
        #expect(editorRanges.contains { $0 == (9, 11) })
    }
}
