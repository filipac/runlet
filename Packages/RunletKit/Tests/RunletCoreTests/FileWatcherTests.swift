import Foundation
import Testing
@testable import RunletCore

struct DiskSyncTests {
    @Test func aCleanTabReloads() {
        #expect(DiskSync.evaluate(disk: "new", baseline: "old", editor: "old") == .reload("new"))
    }

    @Test func editsMeetingAChangeAreAConflict() {
        #expect(DiskSync.evaluate(disk: "theirs", baseline: "old", editor: "mine") == .conflict("theirs"))
    }

    @Test func ownEditsAloneChangeNothing() {
        #expect(DiskSync.evaluate(disk: "old", baseline: "old", editor: "mine") == .unchanged)
        #expect(DiskSync.evaluate(disk: "old", baseline: "old", editor: "old") == .unchanged)
    }

    @Test func theSameTextOnBothSidesIsInSync() {
        #expect(DiskSync.evaluate(disk: "same", baseline: "old", editor: "same") == .inSync("same"))
        #expect(DiskSync.evaluate(disk: "same", baseline: nil, editor: "same") == .inSync("same"))
    }

    @Test func aRestoredTabThatDiffersAsks() {
        // Unknown baseline: unsaved edits and a file changed while Runlet was closed look alike.
        #expect(DiskSync.evaluate(disk: "disk", baseline: nil, editor: "tab") == .conflict("disk"))
    }

    @Test func aMissingFileIsReported() {
        #expect(DiskSync.evaluate(disk: nil, baseline: "old", editor: "old") == .missing)
        #expect(DiskSync.evaluate(disk: nil, baseline: nil, editor: "") == .missing)
    }

    @Test func savingAsksOnlyOverANewerFile() {
        #expect(!DiskSync.saveNeedsConfirmation(disk: "old", baseline: "old", editor: "mine"))
        #expect(DiskSync.saveNeedsConfirmation(disk: "theirs", baseline: "old", editor: "mine"))
        #expect(!DiskSync.saveNeedsConfirmation(disk: "mine", baseline: "old", editor: "mine"), "nothing would change")
        #expect(!DiskSync.saveNeedsConfirmation(disk: nil, baseline: "old", editor: "mine"), "a deleted file is written back")
        #expect(DiskSync.saveNeedsConfirmation(disk: "disk", baseline: nil, editor: "tab"))
        #expect(!DiskSync.saveNeedsConfirmation(disk: "tab", baseline: nil, editor: "tab"))
    }
}

/// Live checks against temporary files.
struct FileWatcherTests {
    /// Collects callbacks; `next` waits for one.
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        /// Waits until more than `seen` callbacks arrived (true) or `timeout` passed (false).
        func arrives(after seen: Int, timeout: Duration = .seconds(3)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if value > seen { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return value > seen
        }
    }

    let folder: URL
    let file: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("scratch.php")
        try Data("<?php\n".utf8).write(to: file)
    }

    func watch(_ events: Events) -> FileWatcher {
        FileWatcher(url: file, latency: 0.05, deliveryQueue: DispatchQueue(label: "test")) { events.record() }
    }

    /// Writes into the existing file (same inode), like `echo >>`.
    func writeInPlace(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func seesWritesInPlace() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = Events()
        let watcher = watch(events)
        defer { watcher.cancel() }
        try writeInPlace("echo 1;\n")
        #expect(await events.arrives(after: 0))
    }

    @Test func followsAtomicSaves() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = Events()
        let watcher = watch(events)
        defer { watcher.cancel() }
        try Data("<?php echo 2;\n".utf8).write(to: file, options: .atomic)
        #expect(await events.arrives(after: 0))
        // The new file is watched now: writing into it is seen too.
        try await Task.sleep(for: .milliseconds(150))
        let seen = events.value
        try writeInPlace("echo 3;\n")
        #expect(await events.arrives(after: seen))
    }

    @Test func seesDeletionAndReturn() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = Events()
        let watcher = watch(events)
        defer { watcher.cancel() }
        try FileManager.default.removeItem(at: file)
        #expect(await events.arrives(after: 0))
        try await Task.sleep(for: .milliseconds(150))
        let seen = events.value
        try Data("<?php // back\n".utf8).write(to: file)
        #expect(await events.arrives(after: seen))
    }

    @Test func burstsArriveAsOneCallback() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = Events()
        let watcher = FileWatcher(url: file, latency: 0.3, deliveryQueue: DispatchQueue(label: "test")) { events.record() }
        defer { watcher.cancel() }
        for index in 0..<5 { try writeInPlace("echo \(index);\n") }
        #expect(await events.arrives(after: 0))
        try await Task.sleep(for: .milliseconds(500))
        #expect(events.value == 1)
    }

    @Test func otherFilesInTheFolderDontCount() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = Events()
        let watcher = watch(events)
        defer { watcher.cancel() }
        try Data("other".utf8).write(to: folder.appendingPathComponent("other.php"))
        try await Task.sleep(for: .milliseconds(400))
        #expect(events.value == 0)
    }

    @Test func nothingArrivesAfterCancel() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = Events()
        let watcher = watch(events)
        watcher.cancel()
        try writeInPlace("echo 4;\n")
        try await Task.sleep(for: .milliseconds(300))
        #expect(events.value == 0)
    }
}
