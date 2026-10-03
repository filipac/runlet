import Foundation
import Testing
@testable import RunletCore

struct ProjectSnippetsTests {
    /// A temporary project root, removed when the test ends.
    final class Project {
        let root: URL
        var snippets: URL { ProjectSnippets.directory(projectRoot: root) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-snippets-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".runlet/snippets"), withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func write(_ name: String, _ contents: String) throws -> URL {
            let url = snippets.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }
    }

    private func parse(_ contents: String, name: String = "example.php") -> ProjectSnippet {
        ProjectSnippets.parse(contents, fileURL: URL(fileURLWithPath: "/project/.runlet/snippets/\(name)"))
    }

    @Test func metadataDocblockIsReadAndRemoved() {
        let snippet = parse("""
        <?php
        /**
         * @label Recent users
         * @description The ten newest
         *   accounts, newest first
         * @author someone
         */

        User::latest()->take(10)->get();

        """)
        #expect(snippet.label == "Recent users")
        #expect(snippet.description == "The ten newest accounts, newest first")
        #expect(snippet.code == "User::latest()->take(10)->get();")
        #expect(snippet.id == "/project/.runlet/snippets/example.php")
    }

    @Test func labelFallsBackToFileName() {
        let snippet = parse("<?php\n\n$x = 1;\n$x + 1\n", name: "add-one.php")
        #expect(snippet.label == "add-one")
        #expect(snippet.description == nil)
        #expect(snippet.code == "$x = 1;\n$x + 1")

        // An empty @label still falls back; the docblock is metadata and is removed.
        let empty = parse("<?php\n/** @label */\necho 1;", name: "empty-label.php")
        #expect(empty.label == "empty-label")
        #expect(empty.code == "echo 1;")
    }

    @Test func singleLineDocblockAndSameLineCode() {
        let snippet = parse("<?php /** @label Ping */ echo 'pong';")
        #expect(snippet.label == "Ping")
        #expect(snippet.code == "echo 'pong';")
        #expect(parse("<?php echo 1;").code == "echo 1;")
    }

    @Test func docblockWithoutMetadataStaysInCode() {
        let code = "/**\n * Adds one.\n */\nfunction addOne(int $i): int { return $i + 1; }\naddOne(1)"
        let snippet = parse("<?php\n" + code + "\n", name: "add.php")
        #expect(snippet.label == "add")
        #expect(snippet.code == code)
    }

    @Test func onlyTheFirstDocblockBeforeCodeIsMetadata() {
        // Comments may precede the metadata block and stay in the code.
        let commented = parse("<?php\n// shared with the team\n/**\n * @label Team\n */\necho 1;\n")
        #expect(commented.label == "Team")
        #expect(commented.code == "// shared with the team\n\necho 1;")

        // A docblock after code is never metadata.
        let late = parse("<?php\n$a = 1;\n/** @label Late */\n$a\n", name: "late.php")
        #expect(late.label == "late")
        #expect(late.code == "$a = 1;\n/** @label Late */\n$a")
    }

    @Test func tagLessFilesIndentationAndLineEndings() {
        let tagless = parse("/** @label No tag */\n\n    indented();\n", name: "x.php")
        #expect(tagless.label == "No tag")
        #expect(tagless.code == "    indented();")

        let crlf = parse("\u{FEFF}<?php\r\n/**\r\n * @label Windows\r\n * @description CRLF file\r\n */\r\necho 1;\r\necho 2;\r\n")
        #expect(crlf.label == "Windows")
        #expect(crlf.description == "CRLF file")
        #expect(crlf.code == "echo 1;\r\necho 2;")

        // `<?php` must be a real tag, not a prefix of something else.
        #expect(parse("<?phpx").code == "<?phpx")
        #expect(parse("<?php").code == "")
    }

    @Test func loadReadsSortsAndSkips() throws {
        let project = try Project()
        try project.write("b.php", "<?php\n/** @label beta */\n2;")
        try project.write("a.php", "<?php\n/** @label Alpha */\n1;")
        try project.write("snippet10.php", "<?php 10;")
        try project.write("snippet9.php", "<?php 9;")
        try project.write("notes.txt", "not php")
        try project.write(".hidden.php", "<?php 'hidden';")
        try project.write("latin1.php", "")
        try Data([0x3C, 0x3F, 0x70, 0x68, 0x70, 0x20, 0xFF, 0xFE]).write(to: project.snippets.appendingPathComponent("latin1.php"))
        try FileManager.default.createDirectory(at: project.snippets.appendingPathComponent("folder.php"), withIntermediateDirectories: true)
        let unreadable = try project.write("secret.php", "<?php 'secret';")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        // Nested folders are not scanned.
        try FileManager.default.createDirectory(at: project.snippets.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("<?php 'nested';".utf8).write(to: project.snippets.appendingPathComponent("nested/deep.php"))

        let snippets = ProjectSnippets.load(projectRoot: project.root)
        #expect(snippets.map(\.label) == ["Alpha", "beta", "snippet9", "snippet10"])
        #expect(snippets.map(\.code) == ["1;", "2;", "9;", "10;"])
        #expect(snippets.first?.fileURL.lastPathComponent == "a.php")
        #expect(Set(snippets.map(\.id)).count == snippets.count)
    }

    @Test func missingFolderLoadsNothing() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-none-\(UUID().uuidString)")
        #expect(ProjectSnippets.load(projectRoot: root).isEmpty)
    }

    @Test func fileContentsRoundTrip() throws {
        let code = "$users = User::query()\n    ->latest()\n    ->get();\n$users->count()"
        let contents = ProjectSnippets.fileContents(label: "Count users", description: "How many\naccounts exist", code: code)
        #expect(contents == "<?php\n/**\n * @label Count users\n * @description How many accounts exist\n */\n\n\(code)\n")
        let snippet = parse(contents)
        #expect(snippet.label == "Count users")
        #expect(snippet.description == "How many accounts exist")
        #expect(snippet.code == code)
    }

    @Test func fileContentsSanitizesAndStripsTag() {
        let contents = ProjectSnippets.fileContents(label: "Ends */ here", description: nil, code: "<?php\n\necho 1;\n\n")
        #expect(!contents.contains("Ends */"))
        #expect(contents.components(separatedBy: "<?php").count == 2)
        let snippet = parse(contents)
        #expect(snippet.label == "Ends * / here")
        #expect(snippet.description == nil)
        #expect(snippet.code == "echo 1;")

        // No label or description: no docblock, so the code's own docblock is kept.
        let plain = ProjectSnippets.fileContents(label: "  ", description: "", code: "/** Doc */\nfoo();")
        #expect(plain == "<?php\n\n/** Doc */\nfoo();\n")
        #expect(parse(plain, name: "plain.php").code == "/** Doc */\nfoo();")
    }

    @Test func fileNameSlugs() {
        #expect(ProjectSnippets.fileName(forLabel: "Recent Users (top 10)") == "recent-users-top-10.php")
        #expect(ProjectSnippets.fileName(forLabel: "Café Ünïcode") == "cafe-unicode.php")
        #expect(ProjectSnippets.fileName(forLabel: "  ") == "snippet.php")
        #expect(ProjectSnippets.fileName(forLabel: "../../etc/passwd") == "etc-passwd.php")
        #expect(ProjectSnippets.fileName(forLabel: String(repeating: "a", count: 100)).count == 64)
    }

    @Test func saveCreatesFolderAndRefusesOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try ProjectSnippets.save(label: "Hello World", description: "Greets", code: "echo 'hi';", projectRoot: root)
        #expect(url.lastPathComponent == "hello-world.php")
        #expect(url == ProjectSnippets.fileURL(forLabel: "Hello World", projectRoot: root))
        #expect(ProjectSnippets.load(projectRoot: root).map(\.label) == ["Hello World"])

        #expect(throws: ProjectSnippets.SaveError.fileExists(url)) {
            try ProjectSnippets.save(label: "Hello world", description: nil, code: "echo 'other';", projectRoot: root)
        }
        #expect(ProjectSnippets.load(projectRoot: root).first?.code == "echo 'hi';")

        try ProjectSnippets.save(label: "Hello world", description: nil, code: "echo 'other';", projectRoot: root, overwrite: true)
        let reloaded = ProjectSnippets.load(projectRoot: root)
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.code == "echo 'other';")
        #expect(reloaded.first?.label == "Hello world")

        #expect(throws: ProjectSnippets.SaveError.invalidFileName("../x.php")) {
            try ProjectSnippets.save(label: "x", description: nil, code: "1;", projectRoot: root, fileName: "../x.php")
        }
    }

    @Test func driverStyleNamesStayOutOfTheDriverFolder() throws {
        // Drivers are `.runlet/*Driver.php`; snippets always go one level down.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-driverish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try ProjectSnippets.save(label: "Acme Driver", description: nil, code: "1;", projectRoot: root)
        #expect(url.deletingLastPathComponent().lastPathComponent == "snippets")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".runlet")
        #expect(!url.lastPathComponent.hasSuffix("Driver.php"))
    }

    // MARK: SQL snippets (#130)

    @Test func sqlSnippetsReadTheirMetadataComment() {
        let snippet = parse("""
        -- @label Recent users
        -- @description The ten newest
        --   accounts
        SELECT * FROM users ORDER BY id DESC LIMIT 10;

        """, name: "recent-users.sql")
        #expect(snippet.language == .sql)
        #expect(snippet.label == "Recent users")
        #expect(snippet.description == "The ten newest accounts")
        #expect(snippet.code == "SELECT * FROM users ORDER BY id DESC LIMIT 10;")
        #expect(snippet.inputs.isEmpty)
        #expect(snippet.personalCode == snippet.code)

        // A docblock works too; a blank line ends the `--` run.
        let docblock = parse("/**\n * @label Counts\n */\nselect count(*) from orders;", name: "counts.sql")
        #expect(docblock.label == "Counts")
        #expect(docblock.code == "select count(*) from orders;")
        let separated = parse("-- just a note\n\n-- @label Later\nselect 1;", name: "note.sql")
        #expect(separated.label == "note")
        #expect(separated.code == "-- just a note\n\n-- @label Later\nselect 1;")
    }

    @Test func sqlCommentsWithoutTagsStayInTheCode() {
        let snippet = parse("-- Run on the replica only\nselect 1;\n", name: "replica.sql")
        #expect(snippet.label == "replica")
        #expect(snippet.description == nil)
        #expect(snippet.code == "-- Run on the replica only\nselect 1;")
        // `@input` means nothing in SQL: no inputs, and the line is not taken as metadata.
        let input = parse("-- @input int $id\nselect 1;", name: "input.sql")
        #expect(input.inputs.isEmpty)
        #expect(input.code == "-- @input int $id\nselect 1;")
    }

    @Test func sqlSnippetsAreListedSavedAndReadBack() throws {
        let project = try Project()
        try project.write("users.php", "<?php\n/** @label Users */\nUser::count();")
        try project.write("orders.sql", "-- @label Orders\nselect count(*) from orders;")
        try project.write("notes.txt", "not a snippet")
        let loaded = ProjectSnippets.load(projectRoot: project.root)
        #expect(loaded.map(\.label) == ["Orders", "Users"])
        #expect(loaded.map(\.language) == [.sql, .php])

        #expect(ProjectSnippets.fileName(forLabel: "Big Tables", language: .sql) == "big-tables.sql")
        let url = try ProjectSnippets.save(label: "Big tables", description: "Largest first", code: "select 1;\n", projectRoot: project.root, language: .sql)
        #expect(url.lastPathComponent == "big-tables.sql")
        #expect(try String(contentsOf: url, encoding: .utf8) == "-- @label Big tables\n-- @description Largest first\n\nselect 1;\n")
        let saved = try #require(ProjectSnippets.load(projectRoot: project.root).first { $0.fileURL.lastPathComponent == "big-tables.sql" })
        #expect(saved.label == "Big tables")
        #expect(saved.description == "Largest first")
        #expect(saved.code == "select 1;")
        #expect(saved.language == .sql)

        // A PHP file name is refused for SQL, and the other way round.
        #expect(throws: ProjectSnippets.SaveError.invalidFileName("x.php")) {
            try ProjectSnippets.save(label: "x", description: nil, code: "select 1;", projectRoot: project.root, fileName: "x.php", language: .sql)
        }
        #expect(ProjectSnippets.fileContents(label: "", description: nil, code: "select 1;", language: .sql) == "select 1;\n")
    }
}
