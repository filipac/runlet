import Foundation
import Testing
@testable import RunletCore

/// #8: source excerpts in error cards, and where a frame's file is on this Mac.
struct SourceExcerptTests {
    // MARK: Reading lines

    private func temporaryFile(_ contents: String) throws -> String {
        try temporaryFile(Data(contents.utf8))
    }

    private func temporaryFile(_ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-excerpt-\(UUID().uuidString).php")
        try data.write(to: url)
        return url.path
    }

    private func numbered(_ count: Int) -> String {
        (1...count).map { "line \($0)" }.joined(separator: "\n") + "\n"
    }

    private func numbers(_ result: Result<SourceExcerpt, SourceExcerptFailure>) -> [Int] {
        (try? result.get())?.lines.map(\.number) ?? []
    }

    @Test func fiveLinesAroundTheLine() throws {
        let path = try temporaryFile(numbered(20))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let excerpt = try SourceExcerptReader.read(path: path, line: 10).get()
        #expect(excerpt.focusLine == 10)
        #expect(excerpt.lines.map(\.number) == [8, 9, 10, 11, 12])
        #expect(excerpt.lines.map(\.text) == ["line 8", "line 9", "line 10", "line 11", "line 12"])
        #expect(excerpt.lines.allSatisfy { !$0.isTruncated })
        // Another radius.
        #expect(numbers(SourceExcerptReader.read(path: path, line: 10, limits: SourceExcerptLimits(radius: 0))) == [10])
    }

    @Test func firstAndLastLinesOfAFile() throws {
        let path = try temporaryFile(numbered(6))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(numbers(SourceExcerptReader.read(path: path, line: 1)) == [1, 2, 3])
        #expect(numbers(SourceExcerptReader.read(path: path, line: 2)) == [1, 2, 3, 4])
        // The final newline doesn't start a seventh line.
        #expect(numbers(SourceExcerptReader.read(path: path, line: 6)) == [4, 5, 6])
        #expect(SourceExcerptReader.read(path: path, line: 7) == .failure(.pastEnd(lineCount: 6)))
        // Without a final newline, the last line still counts.
        let noNewline = try temporaryFile("<?php\necho 1;\nthrow new Exception();")
        defer { try? FileManager.default.removeItem(atPath: noNewline) }
        let last = try SourceExcerptReader.read(path: noNewline, line: 3).get()
        #expect(last.lines.map(\.text) == ["<?php", "echo 1;", "throw new Exception();"])
        #expect(SourceExcerptReader.read(path: noNewline, line: 4) == .failure(.pastEnd(lineCount: 3)))
        // Empty files and no line.
        let empty = try temporaryFile("")
        defer { try? FileManager.default.removeItem(atPath: empty) }
        #expect(SourceExcerptReader.read(path: empty, line: 1) == .failure(.pastEnd(lineCount: 0)))
        #expect(SourceExcerptReader.read(path: path, line: 0) == .failure(.noLine))
    }

    @Test func crlfLineEndings() throws {
        let path = try temporaryFile("<?php\r\n\r\nfunction a()\r\n{\r\n    throw new Exception('x');\r\n}\r\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let excerpt = try SourceExcerptReader.read(path: path, line: 5).get()
        #expect(excerpt.lines.map(\.text) == ["function a()", "{", "    throw new Exception('x');", "}"])
        #expect(excerpt.lines.map(\.number) == [3, 4, 5, 6])
        #expect(!excerpt.lines.contains { $0.text.contains("\r") })
    }

    @Test func longLinesAreCut() throws {
        let long = String(repeating: "a", count: 5000)
        let accented = String(repeating: "é", count: 400)
        let path = try temporaryFile("<?php\n\(long)\n\(accented)\nshort\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let excerpt = try SourceExcerptReader.read(path: path, line: 2, limits: SourceExcerptLimits(maxLineLength: 100)).get()
        #expect(excerpt.lines.map(\.number) == [1, 2, 3, 4])
        let cut = excerpt.lines[1]
        #expect(cut.isTruncated)
        #expect(cut.text == String(repeating: "a", count: 100) + "…")
        // Multi-byte characters are never split, and the line is still UTF-8 text.
        #expect(excerpt.lines[2].isTruncated)
        #expect(excerpt.lines[2].text == String(repeating: "é", count: 100) + "…")
        #expect(excerpt.lines[3] == SourceExcerpt.Line(number: 4, text: "short"))
    }

    @Test func linesBeyondTheReadLimit() throws {
        // 40 lines of 100 bytes; only 1 KB is read.
        let body = (1...40).map { String(format: "%-99d", $0) }.joined(separator: "\n") + "\n"
        let path = try temporaryFile(body)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let limits = SourceExcerptLimits(maxBytes: 1024)
        #expect(SourceExcerptReader.read(path: path, line: 30, limits: limits) == .failure(.tooLarge))
        // Lines within the limit show.
        #expect(numbers(SourceExcerptReader.read(path: path, line: 5, limits: limits)) == [3, 4, 5, 6, 7])
    }

    @Test func missingFoldersAndBinaryFiles() throws {
        #expect(SourceExcerptReader.read(path: "/nonexistent/runlet/\(UUID().uuidString).php", line: 3) == .failure(.missing))
        #expect(SourceExcerptReader.read(path: FileManager.default.temporaryDirectory.path, line: 1) == .failure(.notAFile))
        let binary = try temporaryFile(Data([0x3C, 0x3F, 0x0A, 0x00, 0x01, 0x0A, 0x41]))
        defer { try? FileManager.default.removeItem(atPath: binary) }
        #expect(SourceExcerptReader.read(path: binary, line: 2) == .failure(.binary))
        for failure in [SourceExcerptFailure.missing, .notAFile, .tooLarge, .pastEnd(lineCount: 1), .binary, .noLine, .unreadable("x")] {
            #expect(!failure.message.isEmpty)
        }
    }

    @Test func latin1FilesStillShow() throws {
        let path = try temporaryFile(Data("<?php\n// caf".utf8) + Data([0xE9]) + Data("\necho 1;\n".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let excerpt = try SourceExcerptReader.read(path: path, line: 2).get()
        #expect(excerpt.lines[1].text == "// café")
    }

    @Test func dedentKeepsRelativeIndentation() {
        let excerpt = SourceExcerpt(lines: [
            .init(number: 10, text: "        if ($a) {"),
            .init(number: 11, text: ""),
            .init(number: 12, text: "\t\t    throw $e;"),
            .init(number: 13, text: "        }"),
        ], focusLine: 12).dedented()
        #expect(excerpt.lines.map(\.text) == ["if ($a) {", "", "    throw $e;", "}"])
        #expect(excerpt.focusLine == 12)
        // Nothing shared: unchanged.
        let flat = SourceExcerpt(lines: [.init(number: 1, text: "a"), .init(number: 2, text: "  b")], focusLine: 1)
        #expect(flat.dedented() == flat)
    }

    // MARK: The tab's own code

    private func request(_ code: String, selection: SourceSelection? = nil) -> RunRequest {
        RunRequest(tabId: UUID(), documentVersion: 1, target: TargetSnapshot(kind: .sandboxLocal, label: "s", targetId: "sandbox", workingDirectory: "/tmp", phpExecutable: "php"),
                   code: code, selection: selection)
    }

    @Test func snippetLinesMapThroughTheSelection() throws {
        // A tagless snippet: the runner's `<?php ` sits on line 1, so lines don't move.
        let whole = try SourceExcerptReader.snippet(request("$a = 1;\n$b = 2;\nthrow new Exception('x');\n$c = 3;"), snippetLine: 3).get()
        #expect(whole.lines.map(\.number) == [1, 2, 3, 4])
        #expect(whole.focusLine == 3)
        #expect(whole.lines[2].text == "throw new Exception('x');")
        // Run Selection of editor lines 11–13: snippet line 2 is editor line 12.
        let selection = SourceSelection(startLine: 11, startColumn: 5, utf16Range: NSRangeCodable(location: 120, length: 40))
        let selected = try SourceExcerptReader.snippet(request("foo();\nbar();\nbaz();", selection: selection), snippetLine: 2).get()
        #expect(selected.focusLine == 12)
        #expect(selected.lines.map(\.number) == [11, 12, 13])
        #expect(selected.lines[1].text == "bar();")
        // Code with its own tag.
        let tagged = try SourceExcerptReader.excerpt(text: "<?php\r\n\r\nthrow new Error();", line: 3).get()
        #expect(tagged.lines.map(\.text) == ["<?php", "", "throw new Error();"])
        #expect(SourceExcerptReader.snippet(request("echo 1;"), snippetLine: 4) == .failure(.pastEnd(lineCount: 1)))
    }

    // MARK: Where a frame's file is

    private let exists: @Sendable (String) -> Bool = { path in
        ["/Users/dev/app/app/Invoice.php", "/Users/dev/app/vendor/laravel/framework/src/Builder.php", "/Users/dev/other/lib.php",
         "/Users/dev/shop/app/Order.php", "/Users/dev/shop/vendor/acme/pkg/Client.php", "/Users/dev/Sandbox/app/Models/User.php"].contains(path)
    }

    @Test func localProjectFramesAreProjectVendorOrOutside() {
        let snapshot = TargetSnapshot(kind: .local, label: "l", targetId: "x", workingDirectory: "/Users/dev/app", phpExecutable: "php")
        let resolver = FrameSourceResolver.forSnapshot(snapshot, localSource: nil, fileExists: exists)
        #expect(resolver.locate("/Users/dev/app/app/Invoice.php") == .file(FrameSourceFile(
            hostPath: "/Users/dev/app/app/Invoice.php", runtimePath: "/Users/dev/app/app/Invoice.php", origin: .project, isLocalCopy: false, displayPath: "app/Invoice.php")))
        let vendor = resolver.locate("/Users/dev/app/vendor/laravel/framework/src/Builder.php").file
        #expect(vendor?.origin == .vendor)
        #expect(vendor?.displayPath == "vendor/laravel/framework/src/Builder.php")
        #expect(vendor?.isLocalCopy == false)
        #expect(resolver.locate("/Users/dev/other/lib.php").file?.origin == .outsideProject)
        // Missing files say where Runlet looked; PHP's own pseudo-files aren't files.
        #expect(resolver.locate("/Users/dev/app/app/Gone.php") == .unavailable(path: "/Users/dev/app/app/Gone.php", reason: "/Users/dev/app/app/Gone.php doesn't exist on this Mac."))
        #expect(resolver.locate("Standard input code") == .none)
        #expect(resolver.locate("[internal function]") == .none)
    }

    @Test func dockerAndSSHFramesAreLocalCopies() {
        let docker = TargetSnapshot(kind: .docker, label: "d", targetId: "p", workingDirectory: "/var/www/html", phpExecutable: "php", containerId: "abc")
        let dockerResolver = FrameSourceResolver.forSnapshot(docker, localSource: "/Users/dev/shop", fileExists: exists)
        let order = dockerResolver.locate("/var/www/html/app/Order.php").file
        #expect(order == FrameSourceFile(hostPath: "/Users/dev/shop/app/Order.php", runtimePath: "/var/www/html/app/Order.php", origin: .project,
                                         isLocalCopy: true, displayPath: "app/Order.php", runtimeLocation: "the container"))
        #expect(dockerResolver.locate("/var/www/html/vendor/acme/pkg/Client.php").file?.origin == .vendor)
        #expect(dockerResolver.locate("/var/www/html/vendor/acme/pkg/Client.php").file?.isLocalCopy == true)
        // Not in the local folder: unavailable, with the path on this Mac.
        #expect(dockerResolver.locate("/var/www/html/app/New.php") == .unavailable(
            path: "/Users/dev/shop/app/New.php", reason: "/var/www/html/app/New.php maps to /Users/dev/shop/app/New.php, which doesn't exist on this Mac."))
        // Outside the mapped directory, or no local folder: the container's path and why.
        if case .unavailable(let path, let reason) = dockerResolver.locate("/usr/local/lib/php/x.php") {
            #expect(path == "/usr/local/lib/php/x.php")
            #expect(reason.contains("outside the mapped directory"))
        } else {
            Issue.record("expected unavailable")
        }
        if case .unavailable(_, let reason) = FrameSourceResolver.forSnapshot(docker, localSource: nil, fileExists: exists).locate("/var/www/html/app/Order.php") {
            #expect(reason.contains("Set a local source folder"))
        } else {
            Issue.record("expected unavailable")
        }

        let endpoint = SSHEndpoint(host: "shop.example.com", user: "forge", controlPath: "/tmp/x.sock")
        let ssh = TargetSnapshot(kind: .ssh, label: "s", targetId: "p", workingDirectory: "/home/forge/shop/current", phpExecutable: "php", ssh: endpoint)
        let sshResolver = FrameSourceResolver.forSnapshot(ssh, localSource: "/Users/dev/shop", runtimeDirectory: "/home/forge/shop/releases/20261004", fileExists: exists)
        let release = sshResolver.locate("/home/forge/shop/releases/20261004/app/Order.php").file
        #expect(release?.hostPath == "/Users/dev/shop/app/Order.php")
        #expect(release?.isLocalCopy == true)
        #expect(release?.origin == .project)
        #expect(release?.runtimeLocation == endpoint.displayName)
        if case .unavailable(_, let reason) = FrameSourceResolver.forSnapshot(ssh, localSource: nil, fileExists: exists).locate("/home/forge/shop/current/app/Order.php") {
            #expect(reason.contains("Set a local folder in the SSH profile"))
        } else {
            Issue.record("expected unavailable")
        }
    }

    @Test func sandboxFilesAreTheFilesThatRan() {
        // The sandbox's container mounts the sandbox itself: no "local copy".
        let sandboxDocker = TargetSnapshot(kind: .sandboxDocker, label: "s", targetId: "sandbox", workingDirectory: "/sandbox", phpExecutable: "php", hostMountDirectory: "/Users/dev/Sandbox")
        let file = FrameSourceResolver.forSnapshot(sandboxDocker, localSource: nil, fileExists: exists).locate("/sandbox/app/Models/User.php").file
        #expect(file?.hostPath == "/Users/dev/Sandbox/app/Models/User.php")
        #expect(file?.isLocalCopy == false)
        #expect(file?.runtimeLocation == nil)
        #expect(file?.displayPath == "app/Models/User.php")
        let sandboxLocal = TargetSnapshot(kind: .sandboxLocal, label: "s", targetId: "sandbox", workingDirectory: "/Users/dev/Sandbox", phpExecutable: "php")
        #expect(FrameSourceResolver.forSnapshot(sandboxLocal, localSource: nil, fileExists: exists).locate("/Users/dev/Sandbox/app/Models/User.php").file?.isLocalCopy == false)
        // Without a snapshot: container and server mappings read copies unless told otherwise.
        #expect(FrameSourceResolver(mapping: .container(root: "/var/www/html", hostRoot: "/Users/dev/shop"), fileExists: exists).readsLocalCopy)
        #expect(FrameSourceResolver(mapping: .host).readsLocalCopy == false)
        #expect(FrameSourceResolver(mapping: .container(root: "/var/www/html", hostRoot: "/Users/dev/shop")).projectRoot == "/Users/dev/shop")
    }

    // MARK: Reading once per run

    @Test func storeReadsEachFileLineOncePerRun() async throws {
        let path = try temporaryFile(numbered(10))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SourceExcerptStore(capacity: 2)
        let run = UUID()
        let first = await store.file(path, line: 4, run: run)
        #expect(numbers(first) == [2, 3, 4, 5, 6])
        // Same run and line: cached, even after the file changes.
        try Data(numbered(3).utf8).write(to: URL(fileURLWithPath: path))
        #expect(await store.file(path, line: 4, run: run) == first)
        #expect(await store.fileReads == 1)
        // A new run reads again and sees the change.
        #expect(await store.file(path, line: 4, run: UUID()) == .failure(.pastEnd(lineCount: 3)))
        #expect(await store.fileReads == 2)
        // The oldest entry goes once the store is full.
        _ = await store.file(path, line: 1, run: run)
        #expect(await store.cached(SourceExcerptStore.Key(run: run, path: path, line: 4)) == nil)
        let snippet = await store.snippet(request("a();\nb();"), snippetLine: 2)
        #expect(numbers(snippet) == [1, 2])
    }
}
