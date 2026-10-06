import Foundation
import Testing
@testable import RunletCore

/// The `.runlet` folder fingerprint that tells Runlet a driver changed since its tabs were
/// declared, and what Runlet does about it.
struct DriverFolderFingerprintTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-fingerprint-\(UUID().uuidString)/.runlet")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try "<?php class A {}".write(to: url.appendingPathComponent("ADriver.php"), atomically: true, encoding: .utf8)
        try "<?php // shared".write(to: url.appendingPathComponent("lib/Shared.php"), atomically: true, encoding: .utf8)
        return url
    }

    @Test func editsAddsAndRemovalsChangeIt() throws {
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try #require(DriverFolderFingerprint.compute(at: url))
        #expect(DriverFolderFingerprint.compute(at: url) == first)
        // An edit (here the same size, a new modification time).
        let driver = url.appendingPathComponent("ADriver.php")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: driver.path)
        let edited = try #require(DriverFolderFingerprint.compute(at: url))
        #expect(edited != first)
        try "<?php class B {}".write(to: url.appendingPathComponent("lib/Added.php"), atomically: true, encoding: .utf8)
        let added = try #require(DriverFolderFingerprint.compute(at: url))
        #expect(added != edited)
        try FileManager.default.removeItem(at: url.appendingPathComponent("lib/Added.php"))
        #expect(DriverFolderFingerprint.compute(at: url) == edited)
        try FileManager.default.removeItem(at: url.appendingPathComponent("lib/Shared.php"))
        #expect(DriverFolderFingerprint.compute(at: url) != edited)
    }

    @Test func snippetsAndFinderFilesDontCount() throws {
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = DriverFolderFingerprint.compute(at: url)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("snippets"), withIntermediateDirectories: true)
        try "<?php 1;".write(to: url.appendingPathComponent("snippets/one.php"), atomically: true, encoding: .utf8)
        try "x".write(to: url.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        #expect(DriverFolderFingerprint.compute(at: url) == before)
    }

    @Test func noFolderHasNoFingerprint() {
        #expect(DriverFolderFingerprint.compute(at: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/.runlet")) == nil)
        // The order the files are listed in doesn't matter; at most `limit` files count.
        let a = DriverFolderFingerprint.Entry(path: "a.php", size: 1, modified: Date(timeIntervalSince1970: 1))
        let b = DriverFolderFingerprint.Entry(path: "b.php", size: 2, modified: Date(timeIntervalSince1970: 2))
        #expect(DriverFolderFingerprint.of([a, b]) == DriverFolderFingerprint.of([b, a]))
        #expect(DriverFolderFingerprint.of([a, b]).hasPrefix("2-"))
    }

    private let tab = DriverInspectorTab(id: "queues", title: "Queues", listCommand: "q", runCommand: "w {id}")

    private func memory(fingerprint: String?) -> DriverInspectorTabMemory {
        var memory = DriverInspectorTabMemory()
        var catalog = ProjectCommandCatalog()
        catalog.inspectorTabs = [tab]
        catalog.inspectorTabsDeclared = true
        memory.remember(catalog, for: "local:a", fingerprint: fingerprint)
        return memory
    }

    @Test func aChangedDriverIsReadAgain() {
        let memory = memory(fingerprint: "1-abc")
        #expect(memory.reload(for: "local:a", current: "1-abc", listsAutomatically: true) == .upToDate)
        #expect(memory.reload(for: "local:a", current: "2-def", listsAutomatically: true) == .reload)
        // Production targets and SSH hosts only offer it.
        #expect(memory.reload(for: "local:a", current: "2-def", listsAutomatically: false) == .offer)
        // No local folder (or no .runlet): nothing to compare.
        #expect(memory.reload(for: "local:a", current: nil, listsAutomatically: true) == .upToDate)
        // Tabs Runlet doesn't know yet are loaded with Load, not here.
        #expect(memory.reload(for: "local:z", current: "2-def", listsAutomatically: true) == .upToDate)
        // A reload that failed for this folder is retried only by Refresh.
        #expect(memory.reload(for: "local:a", current: "2-def", listsAutomatically: true, failed: "2-def") == .upToDate)
        #expect(memory.reload(for: "local:a", current: "2-def", listsAutomatically: true, failed: "2-def", explicit: true) == .reload)
        #expect(memory.reload(for: "local:a", current: "3-ghi", listsAutomatically: true, failed: "2-def") == .reload)
    }

    @Test func theFingerprintIsRememberedAndOlderEntriesHaveNone() throws {
        let remembered = memory(fingerprint: "1-abc")
        let data = try JSONEncoder().encode(remembered)
        let restored = try JSONDecoder().decode(DriverInspectorTabMemory.self, from: data)
        #expect(restored == remembered)
        #expect(restored.fingerprints["local:a"] == "1-abc")
        // A new fingerprint with the same tabs is a change (to save).
        var updated = restored
        var catalog = ProjectCommandCatalog()
        catalog.inspectorTabs = [tab]
        catalog.inspectorTabsDeclared = true
        let changed = updated.remember(catalog, for: "local:a", fingerprint: "2-def")
        #expect(changed)
        // Written before fingerprints: unknown, so it is read again once.
        let older = #"{"tabs": {"local:a": [{"id": "queues", "title": "Queues", "list": {"kind": "host", "command": "q"}, "runCommand": "w {id}"}]}}"#
        let old = try JSONDecoder().decode(DriverInspectorTabMemory.self, from: Data(older.utf8))
        #expect(old.fingerprints.isEmpty)
        #expect(old.reload(for: "local:a", current: "1-abc", listsAutomatically: true) == .reload)
    }
}
