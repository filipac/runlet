import Foundation
import Testing
@testable import RunletLanguage

/// File watching for the language server (#336): globs, registrations, and batching.
struct WatchedFilesTests {
    let root = "/Users/alice/Sites/shop"

    @Test func globsMatchLikeLSP() throws {
        let php = try #require(LSPGlob(pattern: "**/*.php"))
        #expect(php.matches(path: "\(root)/app/Models/User.php", root: root))
        #expect(php.matches(path: "\(root)/index.php", root: root))
        #expect(!php.matches(path: "\(root)/app/User.phpx", root: root))
        #expect(!php.matches(path: "\(root)/README.md", root: root))

        let lock = try #require(LSPGlob(pattern: "**/composer.lock"))
        #expect(lock.matches(path: "\(root)/composer.lock", root: root))
        #expect(lock.matches(path: "\(root)/packages/billing/composer.lock", root: root))
        #expect(!lock.matches(path: "\(root)/composer.lock.bak", root: root))

        // A pattern without `**` matches from the root: `*` stays within one segment.
        let topLevel = try #require(LSPGlob(pattern: "*.php"))
        #expect(topLevel.matches(path: "\(root)/index.php", root: root))
        #expect(!topLevel.matches(path: "\(root)/app/index.php", root: root))

        let alternatives = try #require(LSPGlob(pattern: "**/*.{php,inc}"))
        #expect(alternatives.matches(path: "\(root)/lib/a.inc", root: root))
        #expect(!alternatives.matches(path: "\(root)/lib/a.txt", root: root))

        let range = try #require(LSPGlob(pattern: "**/v[0-9].php"))
        #expect(range.matches(path: "\(root)/v2.php", root: root))
        #expect(!range.matches(path: "\(root)/vx.php", root: root))
        let negated = try #require(LSPGlob(pattern: "**/v[!0-9].php"))
        #expect(negated.matches(path: "\(root)/vx.php", root: root))

        let question = try #require(LSPGlob(pattern: "config/?.php"))
        #expect(question.matches(path: "\(root)/config/a.php", root: root))
        #expect(!question.matches(path: "\(root)/config/ab.php", root: root))

        let tail = try #require(LSPGlob(pattern: "database/**"))
        #expect(tail.matches(path: "\(root)/database/schema/mysql.sql", root: root))
        #expect(!tail.matches(path: "\(root)/app/database.php", root: root))

        // Dots and other regular-expression characters are literal.
        let literal = try #require(LSPGlob(pattern: "**/.phpantom.toml"))
        #expect(literal.matches(path: "\(root)/.phpantom.toml", root: root))
        #expect(!literal.matches(path: "\(root)/xphpantomxtoml", root: root))
    }

    @Test func relativePatternsMatchUnderTheirBaseOnly() throws {
        let json: JSONValue = .object(["baseUri": .string("file://\(root)/vendor/acme"), "pattern": .string("**/*.php")])
        let glob = try #require(LSPGlob(json: json))
        #expect(glob.matches(path: "\(root)/vendor/acme/src/Thing.php", root: root))
        #expect(!glob.matches(path: "\(root)/app/Thing.php", root: root))
        // A WorkspaceFolder as the base.
        let folder: JSONValue = .object(["baseUri": .object(["uri": .string("file://\(root)"), "name": .string("shop")]), "pattern": .string("*.toml")])
        let toml = try #require(LSPGlob(json: folder))
        #expect(toml.matches(path: "\(root)/.phpantom.toml", root: root))
        #expect(!toml.matches(path: "\(root)/sub/.phpantom.toml", root: root))
    }

    /// What PHPantom 0.10 registers, from `src/server.rs`.
    static let phpantomRegistration: JSONValue = .object(["registrations": .array([
        .object(["id": .string("typeHierarchy"), "method": .string("textDocument/prepareTypeHierarchy")]),
        .object(["id": .string("workspace/didChangeWatchedFiles"), "method": .string("workspace/didChangeWatchedFiles"), "registerOptions": .object(["watchers": .array([
            .object(["globPattern": .string("**/*.php"), "kind": .number(7)]),
            .object(["globPattern": .string("**/composer.json"), "kind": .number(2)]),
            .object(["globPattern": .string("**/composer.lock"), "kind": .number(2)]),
            .object(["globPattern": .string("**/.phpantom.toml"), "kind": .number(7)]),
        ])])]),
    ])])

    @Test func registryFollowsRegisterAndUnregister() {
        var registry = WatchedFileRegistry()
        #expect(registry.isEmpty)
        let result1 = registry.register(Self.phpantomRegistration)
        #expect(result1)
        #expect(registry.patterns == ["**/*.php", "**/composer.json", "**/composer.lock", "**/.phpantom.toml"])
        #expect(registry.couldMatch(path: "\(root)/app/User.php", root: root))
        #expect(!registry.couldMatch(path: "\(root)/package.json", root: root))

        // Other registrations are ignored.
        let result2 = registry.register(.object(["registrations": .array([.object(["id": .string("x"), "method": .string("textDocument/formatting")])])]))
        #expect(!result2)
        let result3 = registry.unregister(.object(["unregisterations": .array([.object(["id": .string("typeHierarchy"), "method": .string("textDocument/prepareTypeHierarchy")])])]))
        #expect(!result3)

        // The spec's spelling, and the corrected one.
        let result4 = registry.unregister(.object(["unregisterations": .array([.object(["id": .string("workspace/didChangeWatchedFiles"), "method": .string("workspace/didChangeWatchedFiles")])])]))
        #expect(result4)
        #expect(registry.isEmpty)
        registry.register(Self.phpantomRegistration)
        let result5 = registry.unregister(.object(["unregistrations": .array([.object(["id": .string("workspace/didChangeWatchedFiles"), "method": .string("workspace/didChangeWatchedFiles")])])]))
        #expect(result5)
        #expect(registry.isEmpty)
    }

    @Test func kindsDecideWhatIsReported() {
        var registry = WatchedFileRegistry()
        registry.register(Self.phpantomRegistration)
        #expect(registry.reportedType(for: .created, path: "\(root)/app/User.php", root: root) == .created)
        #expect(registry.reportedType(for: .deleted, path: "\(root)/app/User.php", root: root) == .deleted)
        #expect(registry.reportedType(for: .changed, path: "\(root)/composer.lock", root: root) == .changed)
        // composer.lock only wants changes: replaced by a branch switch, it changed.
        #expect(registry.reportedType(for: .created, path: "\(root)/composer.lock", root: root) == .changed)
        #expect(registry.reportedType(for: .deleted, path: "\(root)/composer.lock", root: root) == nil)
        #expect(registry.reportedType(for: .created, path: "\(root)/notes.txt", root: root) == nil)
    }

    @Test func eventPathsMapToTheServersRootAndSkipGit() {
        // FSEvents reports /private/var/… for a root under /var/….
        #expect(WatchedPaths.workspacePath("/private/var/tmp/shop/app/A.php", root: "/var/tmp/shop", realRoot: "/private/var/tmp/shop") == "/var/tmp/shop/app/A.php")
        #expect(WatchedPaths.workspacePath("/var/tmp/shop/app/A.php", root: "/var/tmp/shop", realRoot: "/private/var/tmp/shop") == "/var/tmp/shop/app/A.php")
        #expect(WatchedPaths.workspacePath("/private/var/tmp/other/A.php", root: "/var/tmp/shop", realRoot: "/private/var/tmp/shop") == nil)
        #expect(WatchedPaths.workspacePath("/var/tmp/shop/.git/index", root: "/var/tmp/shop", realRoot: "/var/tmp/shop") == nil)
        #expect(WatchedPaths.workspacePath("/var/tmp/shop/.git/hooks/x.php", root: "/var/tmp/shop", realRoot: "/var/tmp/shop") == nil)
        #expect(WatchedPaths.workspacePath("/var/tmp/shop/vendor/acme/.git/HEAD", root: "/var/tmp/shop", realRoot: "/var/tmp/shop") == nil)
        #expect(WatchedPaths.workspacePath("/var/tmp/shop/.github/ci.php", root: "/var/tmp/shop", realRoot: "/var/tmp/shop") == "/var/tmp/shop/.github/ci.php")
    }

    @Test func batchesWaitForAQuietMomentButNotForever() {
        var batcher = FileChangeBatcher(debounce: 0.3, maxDelay: 2)
        #expect(batcher.deadline == nil)
        batcher.record(path: "\(root)/a.php", flags: .created, at: 10)
        #expect(batcher.deadline == 10.3)
        batcher.record(path: "\(root)/b.php", flags: .modified, at: 10.2)
        #expect(batcher.deadline == 10.5)
        let result6 = batcher.takeIfDue(at: 10.4)
        #expect(result6 == nil)
        // Events keep coming every 0.2 s: still due 2 s after the first.
        var time = 10.2
        while time < 13 {
            time += 0.2
            batcher.record(path: "\(root)/c\(Int(time * 10)).php", flags: .created, at: time)
            let due = batcher.takeIfDue(at: time)
            if due != nil { break }
        }
        #expect(time >= 12 && time < 12.3)
        #expect(batcher.pendingCount == 0)
    }

    @Test func eachPathIsSentOnceWithItsMergedFlags() throws {
        var batcher = FileChangeBatcher()
        batcher.record(path: "\(root)/a.php", flags: .removed, at: 0)
        batcher.record(path: "\(root)/a.php", flags: .created, at: 0.1)
        batcher.record(path: "\(root)/b.php", flags: .modified, at: 0.1)
        let taken = batcher.takeIfDue(at: 1)
        let events = try #require(taken)
        #expect(events.map(\.path) == ["\(root)/a.php", "\(root)/b.php"])
        #expect(events[0].flags == [.removed, .created])
    }

    struct FakeProbe: FileSystemProbe {
        var files: [String: FileSystemProbeKind] = [:]
        var folders: [String: [String]] = [:]
        func kind(of path: String) -> FileSystemProbeKind { files[path] ?? (folders[path] != nil ? .directory : .missing) }
        func files(under directory: String, limit: Int) -> [String] { Array((folders[directory] ?? []).prefix(limit)) }
    }

    @Test func changesFollowWhatIsOnDiskNow() {
        var registry = WatchedFileRegistry()
        registry.register(Self.phpantomRegistration)
        let probe = FakeProbe(
            files: ["\(root)/app/New.php": .file, "\(root)/app/Edited.php": .file, "\(root)/composer.lock": .file, "\(root)/notes.txt": .file],
            folders: ["\(root)/app/Billing": ["\(root)/app/Billing/Invoice.php", "\(root)/app/Billing/README.md", "\(root)/app/Billing/.git/x.php"]]
        )
        let events: [(path: String, flags: FileEventFlags)] = [
            ("\(root)/app/New.php", [.created, .modified]),
            ("\(root)/app/Edited.php", .modified),
            ("\(root)/app/Gone.php", .removed),
            ("\(root)/app/Moved.php", .renamed),
            ("\(root)/composer.lock", [.removed, .created]),
            ("\(root)/notes.txt", .created),
            ("\(root)/app/Billing", [.renamed, .isDirectory]),
        ]
        let changes = FileChangeBatcher().changes(for: events, registry: registry, root: root, probe: probe)
        #expect(changes == [
            WatchedFileChange(path: "\(root)/app/New.php", type: .created),
            WatchedFileChange(path: "\(root)/app/Edited.php", type: .changed),
            WatchedFileChange(path: "\(root)/app/Gone.php", type: .deleted),
            WatchedFileChange(path: "\(root)/app/Moved.php", type: .deleted),
            WatchedFileChange(path: "\(root)/composer.lock", type: .changed),
            WatchedFileChange(path: "\(root)/app/Billing/Invoice.php", type: .created),
        ])
    }

    @Test func aBranchSwitchIsAFewNotifications() {
        var registry = WatchedFileRegistry()
        registry.register(Self.phpantomRegistration)
        var batcher = FileChangeBatcher(maxBatchSize: 2000)
        var probe = FakeProbe()
        // 4,500 PHP files rewritten, plus Git's own churn (dropped before batching by
        // `WatchedPaths`) and other files no glob wants.
        for index in 0..<4500 {
            let path = "\(root)/app/Generated/Class\(index).php"
            probe.files[path] = .file
            batcher.record(path: path, flags: [.removed, .created, .modified], at: Double(index) / 10_000)
        }
        let events = batcher.takeIfDue(at: 1) ?? []
        let changes = batcher.changes(for: events, registry: registry, root: root, probe: probe)
        let notifications = batcher.notifications(for: changes)
        #expect(changes.count == 4500)
        #expect(notifications.map(\.count) == [2000, 2000, 500])
        let params = FileChangeBatcher.params(for: Array(changes.prefix(1)))
        #expect(params["changes"]?.arrayValue?.first?["uri"]?.stringValue == "file://\(root)/app/Generated/Class0.php")
        #expect(params["changes"]?.arrayValue?.first?["type"]?.intValue == 1)
    }

    @Test func urisArePercentEncoded() {
        #expect(WatchedFileChange(path: "/Users/alice/My Projects/shop/a.php", type: .changed).uri == "file:///Users/alice/My%20Projects/shop/a.php")
    }
}

/// `$/progress` (#336).
struct WorkDoneProgressTests {
    static func progress(_ token: JSONValue, _ value: [String: JSONValue]) -> JSONValue {
        .object(["token": token, "value": .object(value)])
    }

    @Test func beginReportAndEndUpdateTheProgress() throws {
        var tracker = WorkDoneProgressTracker()
        #expect(tracker.current == nil)
        let result7 = tracker.apply(Self.progress(.string("phpantom/indexing"), ["kind": .string("begin"), "title": .string("PHPantom: Indexing"), "message": .string("Starting"), "percentage": .number(0)]))
        #expect(result7)
        #expect(tracker.current == LanguageServerProgress(token: "phpantom/indexing", title: "PHPantom: Indexing", message: "Starting", percentage: 0))
        #expect(tracker.current?.statusText == "Indexing… 0%")

        let result8 = tracker.apply(Self.progress(.string("phpantom/indexing"), ["kind": .string("report"), "message": .string("Scanning vendor packages (1200/2900 files)"), "percentage": .number(42)]))
        #expect(result8)
        #expect(tracker.current?.percentage == 42)
        #expect(tracker.current?.message == "Scanning vendor packages (1200/2900 files)")
        #expect(tracker.current?.statusText == "Indexing… 42%")
        // A report without a message keeps the last one.
        tracker.apply(Self.progress(.string("phpantom/indexing"), ["kind": .string("report"), "percentage": .number(50)]))
        #expect(tracker.current?.message == "Scanning vendor packages (1200/2900 files)")
        // The same report again changes nothing.
        let result9 = tracker.apply(Self.progress(.string("phpantom/indexing"), ["kind": .string("report"), "percentage": .number(50)]))
        #expect(!result9)

        let result10 = tracker.apply(Self.progress(.string("phpantom/indexing"), ["kind": .string("end"), "message": .string("Indexed 5678 classes")]))
        #expect(result10)
        #expect(tracker.current == nil)
        #expect(tracker.last?.message == "Indexed 5678 classes")
        #expect(tracker.last?.title == "PHPantom: Indexing")
        // A late report for an ended token is ignored.
        let result11 = tracker.apply(Self.progress(.string("phpantom/indexing"), ["kind": .string("report"), "percentage": .number(99)]))
        #expect(!result11)
        #expect(tracker.current == nil)
    }

    @Test func theLatestOperationShowsAndNumberTokensWork() {
        var tracker = WorkDoneProgressTracker()
        tracker.apply(Self.progress(.string("phpantom/indexing"), ["kind": .string("begin"), "title": .string("PHPantom: Indexing")]))
        tracker.apply(Self.progress(.number(7), ["kind": .string("begin"), "title": .string("Find References"), "message": .string("Scanning…")]))
        #expect(tracker.current?.token == "#7")
        #expect(tracker.current?.statusText == "Find References…")
        tracker.apply(Self.progress(.number(7), ["kind": .string("end")]))
        #expect(tracker.current?.token == "phpantom/indexing")
        #expect(tracker.current?.statusText == "Indexing…")
        tracker.reset()
        #expect(tracker.current == nil)
        #expect(tracker.last?.title == "Find References")
    }

    @Test func percentagesStayInRange() {
        var tracker = WorkDoneProgressTracker()
        tracker.apply(Self.progress(.string("t"), ["kind": .string("begin"), "title": .string("PHPantom: Full index"), "percentage": .number(140)]))
        #expect(tracker.current?.percentage == 100)
        #expect(tracker.current?.statusText == "Indexing… 100%")
    }
}

/// The capabilities Runlet's client declares (#336).
struct LanguageClientCapabilityTests {
    @Test func declaresFileWatchingAndProgress() {
        let params = LanguageServerSession.initializeParams(rootURI: "file:///Users/alice/Sites/shop/", name: "shop")
        let capabilities = params["capabilities"]
        #expect(capabilities?["workspace"]?["didChangeWatchedFiles"]?["dynamicRegistration"] == .bool(true))
        #expect(capabilities?["workspace"]?["didChangeWatchedFiles"]?["relativePatternSupport"] == .bool(true))
        #expect(capabilities?["window"]?["workDoneProgress"] == .bool(true))
        // Still no edits pushed by the server.
        #expect(capabilities?["workspace"]?["applyEdit"] == .bool(false))
    }
}

/// The status bar's PHPantom item (#336).
struct LanguageStatusSummaryTests {
    let indexing = LanguageServerActivity(progress: LanguageServerProgress(token: "phpantom/indexing", title: "PHPantom: Indexing", message: "Scanning vendor packages (1200/2900 files)", percentage: 42))

    @Test func indexingShowsItsPercentageAndMessage() {
        let summary = LanguageStatusSummary(state: .ready(serverVersion: "0.10.0"), activity: indexing, limitations: [])
        #expect(summary.title == "Indexing… 42%")
        #expect(summary.help == "PHPantom: Indexing: Scanning vendor packages (1200/2900 files)")
        #expect(summary.isBusy)
        #expect(LanguageStatusSummary.stateLine(state: .ready(serverVersion: "0.10.0"), activity: indexing) == "Indexing… 42%")
        var unknown = indexing
        unknown.progress?.percentage = nil
        #expect(LanguageStatusSummary(state: .ready(serverVersion: nil), activity: unknown, limitations: []).title == "Indexing…")
    }

    @Test func idleStatesStayAsTheyWere() {
        #expect(LanguageStatusSummary(state: .ready(serverVersion: nil), activity: LanguageServerActivity(), limitations: []).title == "PHPantom")
        let limited = LanguageStatusSummary(state: .ready(serverVersion: nil), activity: LanguageServerActivity(), limitations: ["vendor/ is not installed."])
        #expect(limited.title == "PHPantom (limited)")
        #expect(limited.help == "vendor/ is not installed.")
        #expect(LanguageStatusSummary(state: .starting, activity: LanguageServerActivity(), limitations: []).title == "Indexing…")
        let failed = LanguageStatusSummary(state: .failed("PHPantom could not start"), activity: LanguageServerActivity(), limitations: [])
        #expect(failed.title == "PHPantom failed")
        #expect(failed.isFailure)
        #expect(LanguageStatusSummary.stateLine(state: .ready(serverVersion: "0.10.0"), activity: LanguageServerActivity()) == "Ready · version 0.10.0")
        #expect(LanguageStatusSummary.watchedFiles(["**/*.php", "**/composer.json", "/Users/alice/shop/*.toml"]) == "*.php · composer.json · /Users/alice/shop/*.toml")
    }
}

/// Model copies and file changes (#340), without a server.
struct OverlayTrackerTests {
    static let needsCopy = """
        <?php
        namespace App\\Models;

        use Illuminate\\Database\\Eloquent\\Model;
        use Illuminate\\Database\\Eloquent\\Relations\\HasMany;

        class Shelf extends Model
        {
            public function parts(): HasMany
            {
                return $this->hasMany(Part::class);
            }
        }

        """

    @Test func onlyTheScannedFoldersCount() {
        #expect(EloquentOverlay.isScanned("app/Models/Shelf.php", directories: ["app"]))
        #expect(EloquentOverlay.isScanned("src/Shelf.php", directories: [""]))
        #expect(!EloquentOverlay.isScanned("app/Models/Shelf.txt", directories: ["app"]))
        #expect(!EloquentOverlay.isScanned("lib/Shelf.php", directories: ["app"]))
        #expect(!EloquentOverlay.isScanned("app/vendor/Shelf.php", directories: ["app"]))
        #expect(!EloquentOverlay.isScanned("app/.cache/Shelf.php", directories: ["app"]))
        #expect(!EloquentOverlay.isScanned("storage/Shelf.php", directories: [""]))
        #expect(!EloquentOverlay.isScanned("bootstrap/cache/Shelf.php", directories: [""]))
    }

    @Test func aCopyOpensChangesAndCloses() throws {
        let root = LanguageTestSupport.tempDirectory()
        let file = root.appendingPathComponent("app/Models/Shelf.php")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tracker = OverlayTracker(root: root)
        let change = WatchedFileChange(path: file.path, type: .changed)

        try Self.needsCopy.write(to: file, atomically: true, encoding: .utf8)
        var notes = tracker.notifications(for: [WatchedFileChange(path: file.path, type: .created)])
        #expect(notes.map(\.method) == ["textDocument/didOpen"])
        #expect(notes.first?.params["textDocument"]?["text"]?.stringValue?.contains("function parts()") == true)
        #expect(notes.first?.params["textDocument"]?["text"]?.stringValue?.contains("): HasMany") == false)

        try Self.needsCopy.replacingOccurrences(of: "parts", with: "spares").write(to: file, atomically: true, encoding: .utf8)
        notes = tracker.notifications(for: [change])
        #expect(notes.map(\.method) == ["textDocument/didChange"])
        #expect(notes.first?.params["textDocument"]?["version"]?.intValue == 2)

        try Self.needsCopy.replacingOccurrences(of: "): HasMany", with: "").write(to: file, atomically: true, encoding: .utf8)
        notes = tracker.notifications(for: [change])
        #expect(notes.map(\.method) == ["textDocument/didClose"])
        #expect(tracker.uris.isEmpty)
        // Nothing to close twice, and files that need no copy send nothing.
        #expect(tracker.notifications(for: [change, WatchedFileChange(path: file.path, type: .deleted)]).isEmpty)

        tracker.reset([file.absoluteString])
        #expect(tracker.notifications(for: [WatchedFileChange(path: file.path, type: .deleted)]).map(\.method) == ["textDocument/didClose"])
    }
}
