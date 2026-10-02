import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Runlet's own PHP (#2): download, checksum, unpack, verify, install, remove — against a
/// local archive holding a stand-in `bin/php` that answers like a real one.
struct RunletPHPStoreTests {
    /// A `php-<version>-r1/bin/php` archive in a temporary folder; returns its URL, checksum, and size.
    static func makeArchive(version: String = "8.5.8", reportedVersion: String? = nil, includeBinary: Bool = true) throws -> (url: URL, sha256: String, size: Int64, folder: URL) {
        let folder = try DriverSupport.temporaryDirectory("runlet-php-archive")
        let root = folder.appendingPathComponent("php-\(version)-r1/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if includeBinary {
            let php = root.appendingPathComponent("php")
            try "#!/bin/sh\necho '[\"\(reportedVersion ?? version)\",true]'\n".write(to: php, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: php.path)
        }
        let archive = folder.appendingPathComponent("php.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", folder.path, "php-\(version)-r1"]
        try tar.run()
        tar.waitUntilExit()
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (archive, try RunletPHPStore.sha256(of: archive), size, folder)
    }

    static func store(_ archive: (url: URL, sha256: String, size: Int64, folder: URL), sha256: String? = nil) throws -> (RunletPHPStore, URL) {
        let data = try DriverSupport.temporaryDirectory("runlet-php-data")
        let asset = RunletPHPRelease.Asset(url: archive.url, sha256: sha256 ?? archive.sha256, size: archive.size)
        let release = RunletPHPRelease(version: "8.5.8", build: "r1", assets: ["arm64": asset, "x86_64": asset])
        return (RunletPHPStore(paths: AppPaths(root: data), release: release), data)
    }

    @Test func installsVerifiesAndRemoves() async throws {
        let archive = try Self.makeArchive()
        let (store, data) = try Self.store(archive)
        defer { try? FileManager.default.removeItem(at: archive.folder); try? FileManager.default.removeItem(at: data) }
        #expect(store.isAvailable)
        #expect(await store.installed() == nil)

        let fractions = FractionLog()
        let installed = try await store.install { fractions.append($0) }
        #expect(installed.version == "8.5.8")
        #expect(installed.source == "Runlet")
        #expect(installed.path == store.binaryPath)
        #expect(await store.installed()?.version == "8.5.8")
        #expect(fractions.values.last == 1)
        // No download leftovers next to the installed release.
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path) == ["8.5.8-r1"])

        try store.remove()
        #expect(await store.installed() == nil)
    }

    @Test func aChecksumMismatchInstallsNothing() async throws {
        let archive = try Self.makeArchive()
        let (store, data) = try Self.store(archive, sha256: String(repeating: "a", count: 64))
        defer { try? FileManager.default.removeItem(at: archive.folder); try? FileManager.default.removeItem(at: data) }
        await #expect(throws: RunletPHPStore.InstallError.checksumMismatch) { _ = try await store.install() }
        #expect(await store.installed() == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? [] == [])
    }

    @Test func downloadsFarLargerThanExpectedAreDiscarded() async throws {
        let archive = try Self.makeArchive()
        let data = try DriverSupport.temporaryDirectory("runlet-php-data")
        defer { try? FileManager.default.removeItem(at: archive.folder); try? FileManager.default.removeItem(at: data) }
        let asset = RunletPHPRelease.Asset(url: archive.url, sha256: archive.sha256, size: archive.size / 3)
        let store = RunletPHPStore(paths: AppPaths(root: data), release: RunletPHPRelease(version: "8.5.8", build: "r1", assets: ["arm64": asset, "x86_64": asset]))
        await #expect(throws: RunletPHPStore.InstallError.tooLarge) { _ = try await store.install() }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? [] == [])
    }

    @Test func archivesWithoutAWorkingPHPAreRejected() async throws {
        let missing = try Self.makeArchive(includeBinary: false)
        let (missingStore, missingData) = try Self.store(missing)
        defer { try? FileManager.default.removeItem(at: missing.folder); try? FileManager.default.removeItem(at: missingData) }
        await #expect(throws: RunletPHPStore.InstallError.unpack("bin/php is missing")) { _ = try await missingStore.install() }

        let wrong = try Self.makeArchive(reportedVersion: "7.0.0")
        let (wrongStore, wrongData) = try Self.store(wrong)
        defer { try? FileManager.default.removeItem(at: wrong.folder); try? FileManager.default.removeItem(at: wrongData) }
        await #expect(throws: RunletPHPStore.InstallError.notWorking) { _ = try await wrongStore.install() }
        #expect(await wrongStore.installed() == nil)
    }

    @Test func runletPHPIsOnlyAFallback() {
        let herd = PHPInstallation(path: "/herd/php84", version: "8.4.10", hasTokenizer: true, source: "Herd")
        let runlet = PHPInstallation(path: "/data/PHP/8.5.8-r1/bin/php", version: "8.5.8", hasTokenizer: true, source: "Runlet")
        let merged = RunletPHPStore.merged(discovered: [herd, runlet], runlet: runlet)
        #expect(merged.map(\.path) == [herd.path, runlet.path], "listed once, last")
        #expect(PHPDiscovery.preferred(merged)?.path == herd.path, "an installed PHP wins")
        #expect(PHPDiscovery.preferred(RunletPHPStore.merged(discovered: [], runlet: runlet))?.path == runlet.path, "used when nothing else is installed")
        let old = PHPInstallation(path: "/usr/local/bin/php", version: "8.1.2", hasTokenizer: true, source: "PATH")
        #expect(PHPDiscovery.preferred(RunletPHPStore.merged(discovered: [old], runlet: runlet), minimum: (8, 3))?.path == runlet.path, "and when none is new enough (the sandbox needs 8.3)")
    }

    /// The shipped release names both Macs' archives under its own tag, with real checksums.
    @Test func currentReleaseIsPinnedForBothMacs() {
        let release = RunletPHPRelease.current
        for arch in ["arm64", "x86_64"] {
            let asset = release.assets[arch]
            #expect(asset?.url.absoluteString == "https://github.com/filipac/runlet/releases/download/php-\(release.identifier)/runlet-php-\(release.identifier)-macos-\(arch).tar.gz")
            #expect(asset?.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && asset?.sha256 != String(repeating: "0", count: 64), "\(arch) is pinned")
            #expect((asset?.size ?? 0) > 1_000_000)
        }
        #expect(RunletPHPStore(paths: AppPaths(root: URL(fileURLWithPath: "/tmp/unused"))).isAvailable)
    }

    @Test func placeholderReleasesAreNotOffered() {
        let placeholder = RunletPHPRelease.Asset(url: URL(string: "https://example.invalid/php.tar.gz")!, sha256: String(repeating: "0", count: 64), size: 0)
        let store = RunletPHPStore(paths: AppPaths(root: URL(fileURLWithPath: "/tmp/unused")), release: RunletPHPRelease(version: "8.5.8", build: "r1", assets: ["arm64": placeholder, "x86_64": placeholder]))
        #expect(!store.isAvailable)
    }
}

/// Collects progress callbacks from the download's delegate queue.
final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double?] = []
    func append(_ value: Double?) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Double?] { lock.lock(); defer { lock.unlock() }; return stored }
}
