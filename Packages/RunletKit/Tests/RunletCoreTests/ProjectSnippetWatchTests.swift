import Foundation
@testable import RunletCore
import Testing

/// #51: the snippets folder's watcher (`FolderWatcher`) and the cache it keeps up to date
/// (`ProjectSnippetCache`), on temporary folders: files created, edited in place, atomically
/// replaced, renamed, and deleted, the folder created and removed later, and debouncing.
@Suite(.serialized)
@MainActor
struct ProjectSnippetWatchTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p51-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Polls until `condition` holds, at most `timeout` seconds.
    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func write(_ text: String, to url: URL, atomically: Bool = false) throws {
        try Data(text.utf8).write(to: url, options: atomically ? .atomic : [])
    }

    /// Appends without replacing the file: the folder's entries don't change.
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func watcherReportsEveryKindOfChange() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ProjectSnippets.directory(projectRoot: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let counter = Counter()
        let watcher = FolderWatcher(url: folder, latency: 0.1, deliveryQueue: DispatchQueue(label: "p51-delivery")) { counter.increment() }
        defer { watcher.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        func expectChange(_ name: Comment, _ action: () throws -> Void) async throws {
            let before = counter.count
            try action()
            #expect(await eventually { counter.count > before }, name)
            try await Task.sleep(for: .milliseconds(300))
        }
        let file = folder.appendingPathComponent("users.php")
        try await expectChange("created") { try write("<?php 1;", to: file) }
        try await expectChange("edited in place") { try append("\n2;", to: file) }
        try await expectChange("atomically replaced") { try write("<?php 3;", to: file, atomically: true) }
        try await expectChange("renamed") { try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("people.php")) }
        try await expectChange("deleted") { try FileManager.default.removeItem(at: folder.appendingPathComponent("people.php")) }

        // A file next to the folder isn't in it.
        let before = counter.count
        try write("x", to: root.appendingPathComponent(".runlet/notes.txt"))
        try write("x", to: root.appendingPathComponent("composer.json"))
        try await Task.sleep(for: .milliseconds(700))
        #expect(counter.count == before)

        // After cancel, nothing more arrives.
        watcher.cancel()
        try write("<?php 4;", to: folder.appendingPathComponent("late.php"))
        try await Task.sleep(for: .milliseconds(700))
        #expect(counter.count == before)
    }

    @Test func folderCreatedAndRemovedLater() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ProjectSnippets.directory(projectRoot: root)
        let counter = Counter()
        let watcher = FolderWatcher(url: folder, latency: 0.1, deliveryQueue: DispatchQueue(label: "p51-delivery")) { counter.increment() }
        defer { watcher.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        #expect(!watcher.watchesFolder, "it watches the project root until the folder exists")
        // `.runlet/snippets` appears with a file in it…
        var before = counter.count
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("-- @label A\nSELECT 1;", to: folder.appendingPathComponent("a.sql"))
        #expect(await eventually { counter.count > before }, "the folder was created")
        try await Task.sleep(for: .milliseconds(400))
        #expect(watcher.watchesFolder)
        // …and from then on, edits inside it are seen (the watcher moved onto the new folder).
        before = counter.count
        try append("\nSELECT 2;", to: folder.appendingPathComponent("a.sql"))
        #expect(await eventually { counter.count > before }, "edited in the new folder")
        try await Task.sleep(for: .milliseconds(300))
        // Removing the folder, and making it again, are changes too.
        before = counter.count
        try FileManager.default.removeItem(at: root.appendingPathComponent(".runlet"))
        #expect(await eventually { counter.count > before }, "the folder was removed")
        try await Task.sleep(for: .milliseconds(400))
        #expect(!watcher.watchesFolder)
        before = counter.count
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("<?php 1;", to: folder.appendingPathComponent("b.php"))
        #expect(await eventually { counter.count > before }, "the folder came back")
        try await Task.sleep(for: .milliseconds(400))
        before = counter.count
        try append("\n2;", to: folder.appendingPathComponent("b.php"))
        #expect(await eventually { counter.count > before }, "edited after it came back")
    }

    @Test func aBurstIsOneChange() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ProjectSnippets.directory(projectRoot: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let counter = Counter()
        let watcher = FolderWatcher(url: folder, latency: 0.6, deliveryQueue: DispatchQueue(label: "p51-delivery")) { counter.increment() }
        defer { watcher.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        // A `git checkout` of fifteen files, 30 ms apart: one reload, after the last one.
        let started = Date()
        for index in 0..<15 {
            try write("<?php \(index);", to: folder.appendingPathComponent("s\(index).php"), atomically: index.isMultiple(of: 2))
            try await Task.sleep(for: .milliseconds(30))
        }
        let burst = Date().timeIntervalSince(started)
        #expect(counter.count == 0, "nothing while the folder keeps changing")
        #expect(await eventually { counter.count == 1 })
        #expect(Date().timeIntervalSince(started) >= burst + 0.3, "only once the folder was quiet for the latency")
        try await Task.sleep(for: .milliseconds(900))
        #expect(counter.count == 1)
    }

    @Test func cacheFollowsTheFolder() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ProjectSnippets.directory(projectRoot: root)
        let cache = ProjectSnippetCache(latency: 0.1)
        #expect(cache.snippets(root: root).isEmpty)
        #expect(cache.watchedRoots == [root.path])
        try await Task.sleep(for: .milliseconds(300))

        // Created: listed, with its metadata.
        var generation = cache.generation
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("<?php\n/** @label Recent users */\nUser::latest()->get();\n", to: folder.appendingPathComponent("users.php"))
        #expect(await eventually { cache.snippets(root: root).map(\.label) == ["Recent users"] })
        #expect(cache.generation > generation)
        // Edited in place: the new label and code.
        try await Task.sleep(for: .milliseconds(200))
        try write("<?php\n/** @label Newest users */\nUser::latest()->take(5)->get();\n", to: folder.appendingPathComponent("users.php"))
        #expect(await eventually { cache.snippets(root: root).first?.label == "Newest users" })
        #expect(cache.snippets(root: root).first?.code == "User::latest()->take(5)->get();")
        // Atomically replaced: same file, same id (a selected row stays selected).
        let id = try #require(cache.snippets(root: root).first?.id)
        try await Task.sleep(for: .milliseconds(200))
        try write("-- @label Pending\nSELECT 1;", to: folder.appendingPathComponent("pending.sql"), atomically: true)
        try write("<?php\n/** @label Newest users */\nUser::latest()->take(9)->get();\n", to: folder.appendingPathComponent("users.php"), atomically: true)
        #expect(await eventually { cache.snippets(root: root).map(\.label) == ["Newest users", "Pending"] && cache.snippets(root: root).first?.code.contains("take(9)") == true })
        #expect(cache.snippets(root: root).first?.id == id)
        // Renamed: listed under its new file.
        try await Task.sleep(for: .milliseconds(200))
        try FileManager.default.moveItem(at: folder.appendingPathComponent("pending.sql"), to: folder.appendingPathComponent("open.sql"))
        #expect(await eventually { cache.snippets(root: root).last?.fileURL.lastPathComponent == "open.sql" })
        // Deleted: gone.
        try await Task.sleep(for: .milliseconds(200))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("users.php"))
        #expect(await eventually { cache.snippets(root: root).map(\.label) == ["Pending"] })

        // A change that leaves the snippets as they were doesn't bother observers.
        try await Task.sleep(for: .milliseconds(400))
        generation = cache.generation
        try write("not a snippet", to: folder.appendingPathComponent("README.txt"))
        try await Task.sleep(for: .milliseconds(700))
        #expect(cache.generation == generation)

        // No open tab uses the project any more: it isn't watched or cached.
        cache.retain(roots: [])
        #expect(cache.watchedRoots.isEmpty)
        try write("<?php\n/** @label Later */\n1;\n", to: folder.appendingPathComponent("later.php"))
        try await Task.sleep(for: .milliseconds(700))
        #expect(cache.generation == generation)
        // Shown again, it's read fresh (and watched again).
        #expect(cache.snippets(root: root).map(\.label) == ["Later", "Pending"])
        #expect(cache.watchedRoots == [root.path])
        cache.retain(roots: [root])
        #expect(cache.watchedRoots == [root.path])
        cache.retain(roots: [])
    }

    @Test func cacheWithoutWatchingReadsOnlyWhenAsked() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ProjectSnippets.directory(projectRoot: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cache = ProjectSnippetCache(watchFolders: false)
        #expect(cache.snippets(root: root).isEmpty && cache.watchedRoots.isEmpty)
        try write("<?php 1;", to: folder.appendingPathComponent("one.php"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(cache.snippets(root: root).isEmpty)
        cache.reload(root: root)
        #expect(cache.snippets(root: root).map(\.label) == ["one"])
    }
}
