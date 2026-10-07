import Foundation
import RunletCore
import Testing
@testable import RunletLanguage

/// A language server written in PHP that records what Runlet sends (#336):
/// `Tests/Fixtures/fake-lsp/server.php`.
enum FakeLanguageServer {
    static let php = ExecutableLocator.resolve("php")

    /// An executable that runs the fake server, as `phpantom_lsp` would be run.
    static func binary() throws -> URL {
        let php = try #require(php)
        let server = LanguageTestSupport.fixtures.appendingPathComponent("fake-lsp/server.php").path
        let url = LanguageTestSupport.tempDirectory().appendingPathComponent("fake-lsp")
        // A shell script: a shebang can't hold a PHP path with spaces (Herd's is under
        // "Application Support").
        try "#!/bin/sh\nexec '\(php)' '\(server)' \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func session(_ root: URL) throws -> LanguageServerSession {
        LanguageServerSession(workspace: LanguageWorkspace(kind: .project, rootPath: root.path), binary: try binary(), configBase: LanguageTestSupport.tempDirectory(), modelOverlays: false)
    }

    static func request(_ session: LanguageServerSession, _ method: String) async throws -> JSONValue {
        try await session.readyConnection().request(method, .null, timeout: .seconds(5))
    }

    /// Every change the server received, in order, and in how many notifications.
    static func watched(_ session: LanguageServerSession) async throws -> (changes: [JSONValue], notifications: Int) {
        let batches = try await request(session, "fake/log")["watched"]?.arrayValue ?? []
        return (batches.flatMap { $0.arrayValue ?? [] }, batches.count)
    }
}

/// Polls `condition` until it holds or `timeout` passes.
@discardableResult
func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}

private func change(_ root: URL, _ path: String, _ type: Int) -> JSONValue {
    .object(["uri": .string(URL(fileURLWithPath: root.appendingPathComponent(path).path).absoluteString), "type": .number(Double(type))])
}

/// "type uri", to compare changes regardless of order.
private func key(_ change: JSONValue) -> String {
    "\(change["type"]?.intValue ?? 0) \(change["uri"]?.stringValue ?? "")"
}

private func write(_ root: URL, _ path: String, _ text: String = "<?php\n") throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: false, encoding: .utf8)
}

/// The client side of file watching and progress, against the fake server (#336).
@Suite(.serialized, .enabled(if: FakeLanguageServer.php != nil, "requires host PHP"))
struct FileWatchingSessionTests {
    @Test func answersRegistrationsFollowsProgressAndSendsBatchedChanges() async throws {
        let root = LanguageTestSupport.tempDirectory()
        let session = try FakeLanguageServer.session(root)
        await session.start()
        #expect(await session.state.isReady)

        // The capabilities Runlet declared.
        let log = try await FakeLanguageServer.request(session, "fake/log")
        let capabilities = log["initialize"]?["capabilities"]
        #expect(capabilities?["workspace"]?["didChangeWatchedFiles"]?["dynamicRegistration"] == .bool(true))
        #expect(capabilities?["workspace"]?["didChangeWatchedFiles"]?["relativePatternSupport"] == .bool(true))
        #expect(capabilities?["window"]?["workDoneProgress"] == .bool(true))

        // The registration and the progress token were accepted (a null result), and the
        // progress the server reported reached the session.
        #expect(await eventually {
            let activity = await session.activity
            return activity.isWatchingFiles && activity.progress?.percentage == 42
        })
        let answers = try await FakeLanguageServer.request(session, "fake/log")["answers"]
        #expect(answers?["register-watchers"] == .null)
        #expect(answers?["progress-create"] == .null)
        let activity = await session.activity
        #expect(activity.watchedPatterns == ["**/*.php", "**/composer.lock", "\(root.path)/*.toml"])
        #expect(activity.progress == LanguageServerProgress(token: "fake/indexing", title: "Fake: Indexing", message: "Scanning (42/100 files)", percentage: 42))
        #expect(activity.progress?.statusText == "Indexing… 42%")

        // Files written together arrive in one notification; files no glob wants, and Git's,
        // never do. composer.lock only wants changes, so its creation is a change.
        try write(root, "a.php")
        try write(root, "src/Billing/Invoice.php")
        try write(root, "composer.lock", "{}")
        try write(root, ".phpantom.toml", "")
        try write(root, "notes.txt", "")
        try write(root, ".git/hooks/pre-commit.php")
        #expect(await eventually { (try? await FakeLanguageServer.watched(session).changes.count) == 4 })
        try await Task.sleep(for: .milliseconds(600))
        var watched = try await FakeLanguageServer.watched(session)
        #expect(watched.notifications == 1)
        #expect(Set(watched.changes.map(key)) == Set([
            change(root, "a.php", 1), change(root, "src/Billing/Invoice.php", 1), change(root, "composer.lock", 2), change(root, ".phpantom.toml", 1),
        ].map(key)))
        #expect(await session.fileChangesSent?.notifications == 1)

        // A deletion is its own batch, later.
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.php"))
        #expect(await eventually { (try? await FakeLanguageServer.watched(session).notifications) == 2 })
        watched = try await FakeLanguageServer.watched(session)
        #expect(watched.changes.last == change(root, "a.php", 3))

        // The end of the progress.
        _ = try await FakeLanguageServer.request(session, "fake/endProgress")
        #expect(await eventually { await session.activity.progress == nil })
        #expect(await session.activity.lastProgress?.message == "Indexed 3 classes")

        // Unregistered: nothing more is watched or sent.
        _ = try await FakeLanguageServer.request(session, "fake/unregister")
        #expect(await eventually { await !session.activity.isWatchingFiles })
        #expect(try await FakeLanguageServer.request(session, "fake/log")["answers"]?["unregister-watchers"] == .null)
        try write(root, "late.php")
        try await Task.sleep(for: .seconds(1))
        #expect(try await FakeLanguageServer.watched(session).notifications == 2)

        await session.stop()
        #expect(await session.activity == LanguageServerActivity(lastProgress: LanguageServerProgress(token: "fake/indexing", title: "Fake: Indexing", message: "Indexed 3 classes", percentage: 42)))
    }

    @Test func aRestartDropsTheOldRegistrationsAndWatchesAgain() async throws {
        let root = LanguageTestSupport.tempDirectory()
        let session = try FakeLanguageServer.session(root)
        await session.start()
        #expect(await eventually { await session.activity.isWatchingFiles })
        await session.reindex() // The fake server has no reindex command: a restart.
        #expect(await session.state.isReady)
        #expect(await eventually { await session.activity.isWatchingFiles })
        try write(root, "after-restart.php")
        #expect(await eventually { (try? await FakeLanguageServer.watched(session).changes) == [change(root, "after-restart.php", 1)] })
        await session.stop()
        #expect(await !session.activity.isWatchingFiles)
    }
}

/// With the bundled PHPantom (#336): a class added after startup completes without a restart.
@Suite(.serialized, .phpantom, .enabled(if: LanguageTestSupport.hasBinary, "run scripts/fetch-phpantom.sh"))
struct PHPantomFileWatchingTests {
    @Test func aClassAddedAfterStartupCompletesWithoutARestart() async throws {
        let root = LanguageTestSupport.tempDirectory()
        try write(root, "composer.json", #"{"name": "acme/shop", "autoload": {"psr-4": {"App\\": "src/"}}}"#)
        try write(root, "src/Greeter.php", "<?php\nnamespace App;\n\nclass Greeter\n{\n    public function hello(): string { return 'Hello'; }\n}\n")
        let session = await LanguageTestSupport.session(root, modelOverlays: false)
        defer { Task { await session.stop() } }
        #expect(await session.state.isReady)

        // PHPantom registers its watchers once its first index is done, and reported that index.
        #expect(await eventually(timeout: .seconds(30)) { await session.activity.isWatchingFiles })
        let activity = await session.activity
        #expect(activity.watchedPatterns.contains("**/*.php"))
        #expect(activity.watchedPatterns.contains("**/composer.lock"))
        #expect((activity.lastProgress ?? activity.progress)?.isIndexing == true)

        let editorText = "$totals = new InvoiceTot"
        let (uri, mapping) = await LanguageTestSupport.open(session, root: root, editorText: editorText)
        let position = mapping.toLSP(LSPPosition(line: 0, character: (editorText as NSString).length))
        func labels() async -> [String] {
            LanguageTestSupport.labels((try? await session.completion(uri: uri, position: position, triggerCharacter: nil)) ?? [])
        }
        #expect(await !labels().contains("InvoiceTotals"))

        try write(root, "src/Billing/InvoiceTotals.php", "<?php\nnamespace App\\Billing;\n\nclass InvoiceTotals\n{\n    public function sum(): int { return 0; }\n}\n")
        #expect(await eventually { await labels().contains("InvoiceTotals") })
        #expect(await (session.fileChangesSent?.changes ?? 0) >= 1)

        // Deleted (a branch switch away), it goes again.
        try FileManager.default.removeItem(at: root.appendingPathComponent("src/Billing/InvoiceTotals.php"))
        #expect(await eventually { await !labels().contains("InvoiceTotals") })
    }
}
