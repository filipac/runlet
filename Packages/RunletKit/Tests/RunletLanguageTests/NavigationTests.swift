import Foundation
import RunletCore
import Testing
@testable import RunletLanguage

/// Request building and response mapping for navigation (#22), without a server.
struct NavigationTests {
    // MARK: Capabilities and parsing

    @Test func featuresFollowTheAdvertisedCapabilities() {
        let capabilities: JSONValue = .object([
            "definitionProvider": .bool(true),
            "referencesProvider": .object([:]),
            "inlayHintProvider": .bool(false),
            "codeActionProvider": .object(["resolveProvider": .bool(true)]),
        ])
        #expect(LanguageNavigation.supports(.definition, in: capabilities))
        #expect(LanguageNavigation.supports(.references, in: capabilities))
        #expect(!LanguageNavigation.supports(.inlayHints, in: capabilities))
        #expect(LanguageNavigation.supports(.codeActions, in: capabilities))
        #expect(!LanguageNavigation.supports(.foldingRanges, in: capabilities))
        #expect(LanguageNavigation.resolvesCodeActions(in: capabilities))
        #expect(!LanguageNavigation.resolvesCodeActions(in: .object(["codeActionProvider": .bool(true)])))
        #expect(!LanguageNavigation.supports(.definition, in: .null))
    }

    @Test func clientCapabilitiesDeclareOnlyWhatRunletHandles() {
        let params = LanguageServerSession.initializeParams(rootURI: "file:///p", name: "p")
        let document = params["capabilities"]?["textDocument"]
        #expect(document?["definition"]?["linkSupport"] == .bool(true))
        #expect(document?["references"] != nil)
        #expect(document?["inlayHint"] != nil)
        #expect(document?["inlayHint"]?["resolveSupport"] == nil)
        #expect(document?["codeAction"]?["resolveSupport"]?["properties"] == .array([.string("edit")]))
        #expect(document?["codeAction"]?["codeActionLiteralSupport"]?["codeActionKind"]?["valueSet"]?.arrayValue?.contains(.string("quickfix")) == true)
        #expect(document?["foldingRange"]?["lineFoldingOnly"] == .bool(true))
        // Edits apply to the tab only: no server-pushed edits, no resource operations.
        #expect(params["capabilities"]?["workspace"]?["applyEdit"] == .bool(false))
        #expect(params["capabilities"]?["workspace"]?["workspaceEdit"]?["documentChanges"] == .bool(false))
        // Unchanged from before #22.
        #expect(document?["completion"]?["completionItem"]?["snippetSupport"] == .bool(false))
    }

    @Test func locationsParseFromEveryResultShape() throws {
        let range: JSONValue = .object(["start": .object(["line": .number(3), "character": .number(1)]), "end": .object(["line": .number(3), "character": .number(4)])])
        let other: JSONValue = .object(["start": .object(["line": .number(1), "character": .number(0)]), "end": .object(["line": .number(9), "character": .number(0)])])
        let single = LSPLocation.parseList(.object(["uri": .string("file:///a.php"), "range": range]))
        #expect(single == [LSPLocation(uri: "file:///a.php", range: LSPRange(start: LSPPosition(line: 3, character: 1), end: LSPPosition(line: 3, character: 4)))])
        #expect(LSPLocation.parseList(.array([.object(["uri": .string("file:///a.php"), "range": range]), .object(["uri": .string("file:///b.php"), "range": range])])).count == 2)
        // LocationLink: the selection range, not the whole target.
        let link = LSPLocation.parseList(.array([.object(["targetUri": .string("file:///c.php"), "targetRange": other, "targetSelectionRange": range])]))
        #expect(link.first?.uri == "file:///c.php")
        #expect(link.first?.range.start == LSPPosition(line: 3, character: 1))
        #expect(LSPLocation.parseList(.null).isEmpty)
        #expect(LSPLocation.parseList(.array([.object(["uri": .string("x")])])).isEmpty)
    }

    @Test func inlayHintsAndCodeActionsParse() throws {
        let position: JSONValue = .object(["line": .number(4), "character": .number(35)])
        let hint = try #require(InlayHint.parse(.object(["position": position, "label": .string("value:"), "kind": .number(2), "tooltip": .string("string $value"), "paddingRight": .bool(true)])))
        #expect(hint.kind == .parameter && hint.label == "value:" && hint.tooltip == "string $value" && hint.paddingRight && !hint.paddingLeft)
        let parts = try #require(InlayHint.parse(.object(["position": position, "label": .array([.object(["value": .string("int")]), .object(["value": .string("|null")])]), "kind": .number(1)])))
        #expect(parts.label == "int|null" && parts.kind == .type)
        // PHPantom's reference counts have no kind.
        #expect(InlayHint.parse(.object(["position": position, "label": .string(" 2 references")]))?.kind == nil)

        let editRange: JSONValue = .object(["start": .object(["line": .number(1), "character": .number(0)]), "end": .object(["line": .number(1), "character": .number(0)])])
        let importAction = try #require(LSPCodeAction.parse(.object([
            "title": .string("Import `App\\Services\\PriceFormatter`"), "kind": .string("quickfix"), "isPreferred": .bool(true),
            "edit": .object(["changes": .object(["file:///p/.runlet-scratch/tab-1.php": .array([.object(["range": editRange, "newText": .string("use X;\n")])])])]),
        ]), index: 0))
        #expect(importAction.isQuickFix && importAction.isPreferred && !importAction.needsResolve)
        #expect(importAction.edit?.changes["file:///p/.runlet-scratch/tab-1.php"]?.first?.newText == "use X;\n")
        let lazy = try #require(LSPCodeAction.parse(.object(["title": .string("Inline variable $f"), "kind": .string("refactor.inline"), "data": .object(["uri": .string("x")])]), index: 1))
        #expect(lazy.needsResolve && lazy.edit == nil)
        // documentChanges: text edits are read, file operations are recorded.
        let documentChanges = try #require(LSPCodeAction.parse(.object(["title": .string("Move class"), "edit": .object(["documentChanges": .array([
            .object(["textDocument": .object(["uri": .string("file:///a.php"), "version": .null]), "edits": .array([.object(["range": editRange, "newText": .string("x")])])]),
            .object(["kind": .string("rename"), "oldUri": .string("file:///a.php"), "newUri": .string("file:///b.php")]),
        ])])]), index: 2))
        #expect(documentChanges.edit?.changes["file:///a.php"]?.count == 1)
        #expect(documentChanges.edit?.resourceOperations.count == 1)
        // A bare Command only runs something on the server: not offered.
        #expect(LSPCodeAction.parse(.object(["title": .string("Run"), "command": .string("phpantom.x")]), index: 3) == nil)
        let disabled = try #require(LSPCodeAction.parse(.object(["title": .string("Extract"), "disabled": .object(["reason": .string("Select an expression")])]), index: 4))
        #expect(disabled.disabledReason == "Select an expression")
        #expect(LSPCodeAction.ordered([lazy, importAction, disabled]).map(\.id) == [0, 1, 4])
    }

    @Test func foldingRangesParse() {
        let ranges = [
            LSPFoldingRange.parse(.object(["startLine": .number(3), "startCharacter": .number(0), "endLine": .number(9), "endCharacter": .number(1)])),
            LSPFoldingRange.parse(.object(["startLine": .number(19), "endLine": .number(21), "kind": .string("comment")])),
            LSPFoldingRange.parse(.object(["startLine": .number(5), "endLine": .number(5)])),
        ]
        #expect(ranges[0] == LSPFoldingRange(startLine: 3, endLine: 9))
        #expect(ranges[1]?.kind == "comment")
        #expect(ranges[2] == nil)
    }

    // MARK: Destinations

    private static let root = "/Users/me/app"
    private static let scratch = "file:///Users/me/app/.runlet-scratch/tab-1.php"

    private func resolver(_ editorText: String, declarations: [String: String] = [:], mapping pathMapping: EditorPathMapping = .host, editor: Bool = true,
                          existing: Set<String>? = nil, root: String = Self.root, kind: LanguageWorkspace.Kind = .project) -> NavigationResolver {
        NavigationResolver(scratchURI: Self.scratch, mapping: ScratchDocumentMapping(editorText: editorText, declarations: declarations),
                           editorLineCount: TextLineIndex(editorText).lineCount, workspaceRoot: root, workspaceKind: kind,
                           pathMapping: pathMapping, hasExternalEditor: editor, fileExists: { path in existing.map { $0.contains(path) } ?? true })
    }

    private func location(_ uri: String, _ line: Int, _ character: Int, length: Int = 0) -> LSPLocation {
        LSPLocation(uri: uri, range: LSPRange(start: LSPPosition(line: line, character: character), end: LSPPosition(line: line, character: character + length)))
    }

    @Test func definitionsInTheTabMoveThroughTheHiddenLines() {
        let text = "function f() {}\nf();"
        // `<?php` is LSP line 0, so LSP line 1 is the first editor line.
        #expect(resolver(text).destination(for: location(Self.scratch, 1, 9, length: 1)) == .scratch(LSPRange(start: LSPPosition(line: 0, character: 9), end: LSPPosition(line: 0, character: 10))))
        // A snippet with its own tag maps one to one.
        let tagged = "<?php\nfunction f() {}\nf();"
        #expect(resolver(tagged).destination(for: location(Self.scratch, 1, 9)) == .scratch(LSPRange(start: LSPPosition(line: 1, character: 9), end: LSPPosition(line: 1, character: 9))))
        // The hidden `;` line after a tagless snippet is the end of its last line.
        if case .scratch(let range) = resolver(text).destination(for: location(Self.scratch, 3, 0)) {
            #expect(range.start.line == 1)
            #expect(TextLineIndex(text).offset(of: range.start) == (text as NSString).length)
        } else {
            Issue.record("expected the tab")
        }
    }

    @Test func definitionsOnHiddenDeclarationsNameTheDriverVariable() {
        let text = "$app->make('x');"
        let destinations = resolver(text, declarations: ["app": "Illuminate\\Foundation\\Application", "db": "Acme\\Db"])
        // Line 1 declares `$app`, line 2 `$db` (sorted), line 3 is the editor's first line.
        #expect(destinations.destination(for: location(Self.scratch, 1, 4)) == .hiddenLine(variable: "app", type: "Illuminate\\Foundation\\Application"))
        #expect(destinations.destination(for: location(Self.scratch, 2, 4)) == .hiddenLine(variable: "db", type: "Acme\\Db"))
        #expect(destinations.destination(for: location(Self.scratch, 0, 0)) == .hiddenLine(variable: nil, type: nil))
        #expect(destinations.destination(for: location(Self.scratch, 3, 0)) == .scratch(LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0))))
    }

    @Test func localProjectFilesOpenInTheEditorAndVendorFilesPeek() {
        let destinations = resolver("x();")
        guard case .projectFile(let model) = destinations.destination(for: location("file:///Users/me/app/app/Models/Widget.php", 6, 0)) else {
            Issue.record("expected a project file")
            return
        }
        #expect(model.path == "/Users/me/app/app/Models/Widget.php" && model.displayPath == "app/Models/Widget.php" && model.line == 7 && model.origin == .project)
        #expect(model.runtimePath == nil)
        guard case .peek(let vendor) = destinations.destination(for: location("file:///Users/me/app/vendor/laravel/framework/src/Illuminate/Database/Eloquent/Model.php", 1883, 27)) else {
            Issue.record("expected a vendor peek")
            return
        }
        #expect(vendor.origin == .vendor && vendor.displayPath == "vendor/laravel/framework/src/Illuminate/Database/Eloquent/Model.php" && vendor.line == 1884)
        // Without an external editor, project files are peeked too.
        if case .peek(let file) = resolver("x();", editor: false).destination(for: location("file:///Users/me/app/app/Models/Widget.php", 6, 0)) {
            #expect(file.origin == .project)
        } else {
            Issue.record("expected a peek")
        }
        // Percent-encoded paths and `..` resolve.
        if case .projectFile(let file) = destinations.destination(for: location("file:///Users/me/app/app/My%20Models/../Models/W.php", 0, 0)) {
            #expect(file.displayPath == "app/Models/W.php")
        } else {
            Issue.record("expected a project file")
        }
    }

    @Test func filesOutsideTheProjectInMemoryOrMissing() {
        let destinations = resolver("x();", existing: ["/Users/me/.composer/vendor/psy/psysh/src/Shell.php"])
        guard case .peek(let outside) = destinations.destination(for: location("file:///Users/me/.composer/vendor/psy/psysh/src/Shell.php", 10, 0)) else {
            Issue.record("expected a peek")
            return
        }
        #expect(outside.origin == .outsideProject && outside.displayPath == "/Users/me/.composer/vendor/psy/psysh/src/Shell.php")
        #expect(destinations.destination(for: location("file:///Users/me/app/app/Gone.php", 0, 0)) == .unavailable("app/Gone.php isn't on this Mac."))
        // Runlet's own in-memory documents are never on disk.
        guard case .peek(let api) = destinations.destination(for: location("file:///Users/me/app/.runlet-scratch/runlet-api.php", 12, 4)) else {
            Issue.record("expected a peek")
            return
        }
        #expect(api.origin == .inMemory && api.path == nil && api.displayPath == "Runlet's snippet API")
        if case .peek(let other) = destinations.destination(for: location("file:///Users/me/app/.runlet-scratch/tab-2.php", 1, 0)) {
            #expect(other.displayPath == "Another tab's code")
        } else {
            Issue.record("expected a peek")
        }
        #expect(destinations.destination(for: location("phpantom://stubs/Core.php", 0, 0)) == .unavailable("phpantom://stubs/Core.php isn't a file."))
        // PHPantom 0.10.0's answer for `(new DateTime())->format`.
        #expect(destinations.destination(for: location("phpantom-stub://DateTime", 760, 20)) == .unavailable("DateTime is built into PHP; there is no source to show."))
        // A basic workspace has no project: everything on disk is outside it.
        if case .peek(let file) = resolver("x();", root: "/tmp/basic", kind: .basic).destination(for: location("file:///tmp/basic/a.php", 0, 0)) {
            #expect(file.origin == .outsideProject)
        } else {
            Issue.record("expected a peek")
        }
    }

    @Test func dockerAndSSHTargetsShowWhereTheTargetSeesTheFile() {
        // A Docker profile whose container runs /var/www/html from the local folder /Users/me/app.
        let docker = resolver("x();", mapping: .container(root: "/var/www/html", hostRoot: Self.root))
        if case .projectFile(let file) = docker.destination(for: location("file:///Users/me/app/app/Models/Widget.php", 6, 0)) {
            #expect(file.path == "/Users/me/app/app/Models/Widget.php")
            #expect(file.runtimePath == "/var/www/html/app/Models/Widget.php" && file.runtimeLocation == "the container")
        } else {
            Issue.record("expected a project file")
        }
        if case .peek(let file) = docker.destination(for: location("file:///Users/me/app/vendor/laravel/framework/src/Foo.php", 0, 0)) {
            #expect(file.origin == .vendor && file.runtimePath == "/var/www/html/vendor/laravel/framework/src/Foo.php")
        } else {
            Issue.record("expected a vendor peek")
        }
        // An SSH profile (Forge's `current`, and the release it resolved to).
        let ssh = resolver("x();", mapping: .remote(roots: ["/home/forge/site/current", "/home/forge/site/releases/42"], localRoot: Self.root, host: "forge@example.com"))
        if case .peek(let file) = ssh.destination(for: location("file:///Users/me/app/vendor/a/b.php", 0, 0)) {
            #expect(file.runtimePath == "/home/forge/site/current/vendor/a/b.php" && file.runtimeLocation == "forge@example.com")
        } else {
            Issue.record("expected a vendor peek")
        }
    }

    @Test func runtimePathsInvertTheEditorPathMapping() {
        let container = EditorPathMapping.container(root: "/app", hostRoot: "/Users/me/app")
        #expect(container.runtimePath(forHostPath: "/Users/me/app/src/A.php") == "/app/src/A.php")
        #expect(container.runtimePath(forHostPath: "/Users/me/app") == "/app")
        #expect(container.runtimePath(forHostPath: "/Users/me/other/A.php") == nil)
        #expect(container.resolve(container.runtimePath(forHostPath: "/Users/me/app/src/A.php")!) == .mapped("/Users/me/app/src/A.php"))
        #expect(EditorPathMapping.container(root: "/", hostRoot: "/Users/me/app").runtimePath(forHostPath: "/Users/me/app/x.php") == "/x.php")
        #expect(EditorPathMapping.container(root: "/app", hostRoot: nil).runtimePath(forHostPath: "/Users/me/app/x.php") == nil)
        #expect(EditorPathMapping.host.runtimePath(forHostPath: "/Users/me/app/x.php") == nil)
        #expect(EditorPathMapping.remote(roots: ["/srv/app"], localRoot: nil, host: "h").runtimePath(forHostPath: "/Users/me/app/x.php") == nil)
    }

    @Test func referencesListTheTabFirstWithSnippets() {
        let text = "function helper(int $n) { return $n; }\nhelper(1);\n  $x = helper(2);"
        let destinations = resolver(text, declarations: [:])
        let locations = [
            location("file:///Users/me/app/vendor/x/y.php", 4, 8, length: 6),
            location("file:///Users/me/app/app/Services/B.php", 9, 4, length: 6),
            location(Self.scratch, 3, 7, length: 6),
            location(Self.scratch, 1, 9, length: 6),
            location(Self.scratch, 1, 9, length: 6),
            location("file:///Users/me/app/app/Services/A.php", 2, 0, length: 6),
            location(Self.scratch, 0, 0),
        ]
        let rows = ReferenceList.make(locations, resolver: destinations, editorText: text) { file, line in
            "    helper(); // \(file.fileName):\(line)"
        }
        #expect(rows.map(\.label) == ["This tab", "This tab", "app/Services/A.php", "app/Services/B.php", "vendor/x/y.php"])
        #expect(rows.map(\.line) == [1, 3, 3, 10, 5])
        #expect(rows.map(\.id) == [0, 1, 2, 3, 4])
        // Leading whitespace is trimmed and the reference's columns follow.
        #expect(rows[1].snippet == "$x = helper(2);")
        #expect(rows[1].highlight == 5..<11)
        #expect(rows[0].highlight == 9..<15)
        #expect(rows[2].snippet == "helper(); // A.php:2")
        #expect(rows[2].highlight == nil)
        #expect(rows[0].isInTab && !rows[2].isInTab)
    }

    // MARK: Code action edits

    private static let importEdit = LSPTextEdit(range: LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 0)), newText: "use App\\Services\\PriceFormatter;\n")

    @Test func importsLandAtTheTopOfATaglessSnippet() throws {
        let text = "$f = new PriceFormatter();\necho $f->format(1);"
        let mapping = ScratchDocumentMapping(editorText: text)
        let edits = try ScratchEditPlanner.plan(LSPWorkspaceEdit(changes: [Self.scratch: [Self.importEdit]]), scratchURI: Self.scratch, mapping: mapping, editorText: text).get()
        #expect(edits == [ScratchEdit(range: NSRange(location: 0, length: 0), text: "use App\\Services\\PriceFormatter;\n")])
        #expect(ScratchEditPlanner.apply(edits, to: text) == "use App\\Services\\PriceFormatter;\n$f = new PriceFormatter();\necho $f->format(1);")
        // With hidden `@var` lines, an import after `<?php` (inside them) still goes to the top.
        let declared = ScratchDocumentMapping(editorText: text, declarations: ["app": "Illuminate\\Foundation\\Application"])
        #expect(try ScratchEditPlanner.plan(LSPWorkspaceEdit(changes: [Self.scratch: [Self.importEdit]]), scratchURI: Self.scratch, mapping: declared, editorText: text).get() == edits)
    }

    @Test func refactoringsMapThroughTheHiddenLines() throws {
        // PHPantom's "Inline variable $sum": delete line 3 and replace `$sum` on line 4 (LSP).
        let text = "$a = 1;\n$b = 2;\n$sum = 1 + 2;\necho $sum;"
        let edit = LSPWorkspaceEdit(changes: [Self.scratch: [
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 3, character: 0), end: LSPPosition(line: 4, character: 0)), newText: ""),
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 4, character: 5), end: LSPPosition(line: 4, character: 9)), newText: "(1 + 2)"),
        ]])
        let edits = try ScratchEditPlanner.plan(edit, scratchURI: Self.scratch, mapping: ScratchDocumentMapping(editorText: text), editorText: text).get()
        #expect(edits.map(\.range.location) == [35, 16])
        #expect(ScratchEditPlanner.apply(edits, to: text) == "$a = 1;\n$b = 2;\necho (1 + 2);")
        // The same edit on a snippet with its own `<?php` maps one to one.
        let tagged = "<?php\n$b = 2;\n$sum = 1 + 2;\necho $sum;"
        let taggedEdit = LSPWorkspaceEdit(changes: [Self.scratch: [
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 2, character: 0), end: LSPPosition(line: 3, character: 0)), newText: ""),
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 3, character: 5), end: LSPPosition(line: 3, character: 9)), newText: "(1 + 2)"),
        ]])
        let taggedEdits = try ScratchEditPlanner.plan(taggedEdit, scratchURI: Self.scratch, mapping: ScratchDocumentMapping(editorText: tagged), editorText: tagged).get()
        #expect(ScratchEditPlanner.apply(taggedEdits, to: tagged) == "<?php\n$b = 2;\necho (1 + 2);")
        // Insertions at one point keep the server's order; an insertion after the snippet goes to its end.
        let order = LSPWorkspaceEdit(changes: [Self.scratch: [
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 0)), newText: "A"),
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 0)), newText: "B"),
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 5, character: 1), end: LSPPosition(line: 5, character: 1)), newText: "Z"),
        ]])
        #expect(ScratchEditPlanner.apply(try ScratchEditPlanner.plan(order, scratchURI: Self.scratch, mapping: ScratchDocumentMapping(editorText: text), editorText: text).get(), to: text)
            == "AB$a = 1;\n$b = 2;\n$sum = 1 + 2;\necho $sum;Z")
    }

    @Test func editsOutsideTheTabOrOnHiddenTextAreRefused() {
        let text = "$x = 1;\necho $x;"
        let mapping = ScratchDocumentMapping(editorText: text)
        func plan(_ edit: LSPWorkspaceEdit) -> Result<[ScratchEdit], ScratchEditRejection> {
            ScratchEditPlanner.plan(edit, scratchURI: Self.scratch, mapping: mapping, editorText: text)
        }
        let range = LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 2))
        // Other files: multi-file edits are deferred (#22).
        #expect(plan(LSPWorkspaceEdit(changes: [Self.scratch: [LSPTextEdit(range: range, newText: "$y")], "file:///Users/me/app/app/A.php": [LSPTextEdit(range: range, newText: "x")]]))
            == .failure(.otherFiles(["A.php"])))
        #expect(plan(LSPWorkspaceEdit(changes: [Self.scratch: [LSPTextEdit(range: range, newText: "$y")]], resourceOperations: ["create file:///x.php"])) == .failure(.resourceOperations))
        // Replacing `<?php` or the hidden final `;`.
        #expect(plan(LSPWorkspaceEdit(changes: [Self.scratch: [LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 1, character: 2)), newText: "")]])) == .failure(.hiddenText))
        #expect(plan(LSPWorkspaceEdit(changes: [Self.scratch: [LSPTextEdit(range: LSPRange(start: LSPPosition(line: 2, character: 5), end: LSPPosition(line: 3, character: 1)), newText: "")]])) == .failure(.hiddenText))
        #expect(plan(LSPWorkspaceEdit(changes: [Self.scratch: [LSPTextEdit(range: range, newText: "a"), LSPTextEdit(range: LSPRange(start: LSPPosition(line: 1, character: 1), end: LSPPosition(line: 1, character: 4)), newText: "b")]])) == .failure(.overlapping))
        #expect(plan(LSPWorkspaceEdit(changes: [:])) == .failure(.empty))
        #expect(plan(LSPWorkspaceEdit(changes: ["file:///Users/me/app/app/A.php": []])) == .failure(.empty))
        #expect(ScratchEditRejection.otherFiles(["A.php", "B.php"]).description.contains("A.php, B.php"))
    }

    // MARK: Inlay hints

    @Test func inlayHintsAreParameterNamesAndTypesInEditorOffsets() {
        let text = "helper(3, 'x');\n$names = array_map(fn ($n) => $n, [1]);"
        let mapping = ScratchDocumentMapping(editorText: text)
        let hints = [
            InlayHint(position: LSPPosition(line: 1, character: 10), label: "label:", kind: .parameter, tooltip: "string $label", paddingRight: true),
            InlayHint(position: LSPPosition(line: 1, character: 7), label: "count:", kind: .parameter, paddingRight: true),
            InlayHint(position: LSPPosition(line: 2, character: 23), label: "int ", kind: .type),
            InlayHint(position: LSPPosition(line: 1, character: 7), label: "again:", kind: .parameter),
            InlayHint(position: LSPPosition(line: 1, character: 15), label: " 2 references", kind: nil),
            InlayHint(position: LSPPosition(line: 0, character: 3), label: "hidden:", kind: .parameter),
            InlayHint(position: LSPPosition(line: 1, character: 99), label: "past:", kind: .parameter),
            InlayHint(position: LSPPosition(line: 2, character: 0), label: "start:", kind: .parameter),
        ]
        let placed = InlayHintPlacement.place(hints, mapping: mapping, editorText: text)
        #expect(placed == [
            EditorInlayHint(offset: 7, label: "count:", kind: .parameter),
            EditorInlayHint(offset: 10, label: "label:", kind: .parameter, tooltip: "string $label"),
            EditorInlayHint(offset: 16 + 23, label: "int", kind: .type),
        ])
        // `int` sits right before `$n`.
        #expect((text as NSString).substring(with: NSRange(location: 39, length: 2)) == "$n")
        // With hidden `@var` lines, positions move by their count.
        let declared = ScratchDocumentMapping(editorText: text, declarations: ["app": "App"])
        let shifted = InlayHintPlacement.place([InlayHint(position: LSPPosition(line: 2, character: 7), label: "count:", kind: .parameter)], mapping: declared, editorText: text)
        #expect(shifted.map(\.offset) == [7])
    }

    @Test func inlayHintsAreRequestedForTheVisibleLines() {
        let mapping = ScratchDocumentMapping(editorText: "x")
        let range = InlayHintPlacement.requestRange(visibleLines: 100...140, margin: 20, editorLineCount: 500, mapping: mapping)
        #expect(range.start == LSPPosition(line: 81, character: 0) && range.end == LSPPosition(line: 162, character: 0))
        let clamped = InlayHintPlacement.requestRange(visibleLines: 0...10, margin: 20, editorLineCount: 12, mapping: mapping)
        #expect(clamped.start == LSPPosition(line: 1, character: 0) && clamped.end == LSPPosition(line: 13, character: 0))
    }

    // MARK: Folding

    @Test func foldingRangesMapToEditorLines() {
        let text = "function f()\n{\n    return 1;\n}\n$a = [\n    1,\n];"
        let mapping = ScratchDocumentMapping(editorText: text)
        let ranges = [
            LSPFoldingRange(startLine: 2, endLine: 4),
            LSPFoldingRange(startLine: 2, endLine: 3),
            LSPFoldingRange(startLine: 5, endLine: 7),
            LSPFoldingRange(startLine: 0, endLine: 2),
            LSPFoldingRange(startLine: 6, endLine: 9, kind: "comment"),
        ]
        // LSP line 2 is editor line 1 (`{`); the hidden `<?php` line starts nothing; ends past
        // the snippet (the hidden `;` line) are clamped.
        #expect(FoldingPlacement.regions(ranges, mapping: mapping, editorLineCount: 7) == [
            EditorFoldRegion(startLine: 1, endLine: 3),
            EditorFoldRegion(startLine: 4, endLine: 6),
            EditorFoldRegion(startLine: 5, endLine: 6, kind: "comment"),
        ])
    }

    @Test func foldsHideTheBlockBetweenItsFirstLineAndItsCloser() throws {
        let text = "function f()\n{\n    return 1;\n    }\n$a = [\n    1,\n];"
        let body = try #require(FoldingPlacement.hiddenRange(for: EditorFoldRegion(startLine: 1, endLine: 3), in: text))
        // From the newline after `{` to the indented `}`.
        #expect((text as NSString).substring(with: body) == "\n    return 1;\n    ")
        let array = try #require(FoldingPlacement.hiddenRange(for: EditorFoldRegion(startLine: 4, endLine: 6), in: text))
        #expect((text as NSString).substring(with: array) == "\n    1,\n")
        #expect(FoldingPlacement.hiddenRange(for: EditorFoldRegion(startLine: 4, endLine: 9), in: text) == nil)
        #expect(FoldingPlacement.hiddenRange(for: EditorFoldRegion(startLine: 2, endLine: 2), in: text) == nil)
    }

    @Test func foldsMoveWithTheTextAndOpenWhenEdited() {
        let folds = [NSRange(location: 14, length: 16), NSRange(location: 40, length: 8)]
        // Typing on a line above moves both.
        #expect(FoldingPlacement.adjust(folds, edited: NSRange(location: 3, length: 2), changeInLength: 2).kept == [NSRange(location: 16, length: 16), NSRange(location: 42, length: 8)])
        // Typing at the end of the fold's first line (before the placeholder) keeps it folded.
        #expect(FoldingPlacement.adjust(folds, edited: NSRange(location: 14, length: 1), changeInLength: 1).kept == [NSRange(location: 15, length: 16), NSRange(location: 41, length: 8)])
        // Typing before the closer (just after the fold) leaves the first fold alone.
        #expect(FoldingPlacement.adjust(folds, edited: NSRange(location: 30, length: 1), changeInLength: 1).kept == [NSRange(location: 14, length: 16), NSRange(location: 41, length: 8)])
        // An edit inside a fold opens it (Replace All, a reload, undo).
        let inside = FoldingPlacement.adjust(folds, edited: NSRange(location: 20, length: 0), changeInLength: -3)
        #expect(inside.kept == [NSRange(location: 37, length: 8)])
        #expect(inside.opened == [NSRange(location: 14, length: 13)])
    }
}
