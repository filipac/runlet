import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Runlet's own PHP (#2): download, checksum, unpack, verify, install, remove — against a
/// local archive holding a stand-in `bin/php` that answers like a real one.
struct RunletPHPStoreTests {
    /// A `php-<version>-r1/bin/php` archive in a temporary folder; returns its URL, checksum, and size.
    static func makeArchive(version: String = "8.5.8", build: String = "r1", reportedVersion: String? = nil, includeBinary: Bool = true) throws -> (url: URL, sha256: String, size: Int64, folder: URL) {
        let folder = try DriverSupport.temporaryDirectory("runlet-php-archive")
        let root = folder.appendingPathComponent("php-\(version)-\(build)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if includeBinary {
            let php = root.appendingPathComponent("php")
            try "#!/bin/sh\necho '[\"\(reportedVersion ?? version)\",true]'\n".write(to: php, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: php.path)
        }
        let archive = folder.appendingPathComponent("php.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", folder.path, "php-\(version)-\(build)"]
        try tar.run()
        tar.waitUntilExit()
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (archive, try RunletPHPStore.sha256(of: archive), size, folder)
    }

    static func store(_ archive: (url: URL, sha256: String, size: Int64, folder: URL), sha256: String? = nil, build: String = "r1", data: URL? = nil) throws -> (RunletPHPStore, URL) {
        let data = try data ?? DriverSupport.temporaryDirectory("runlet-php-data")
        let asset = RunletPHPRelease.Asset(url: archive.url, sha256: sha256 ?? archive.sha256, size: archive.size)
        let release = RunletPHPRelease(version: "8.5.8", build: build, assets: ["arm64": asset, "x86_64": asset])
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

    /// A Mac with the r1 build keeps using it after Runlet moves to r2, until the user updates;
    /// the update moves saved PHP paths and removes r1 (#79).
    @Test func anOlderBuildIsUsedUntilUpdated() async throws {
        let r1 = try Self.makeArchive(build: "r1")
        let (r1Store, data) = try Self.store(r1, build: "r1")
        let r2 = try Self.makeArchive(build: "r2")
        let (r2Store, _) = try Self.store(r2, build: "r2", data: data)
        defer { [r1.folder, r2.folder, data].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try await r1Store.install()

        #expect(await r2Store.installed() == nil)
        let older = try #require(await r2Store.installedOlder())
        #expect(older.path == r1Store.binaryPath)
        #expect(older.source == "Runlet")
        #expect(r2Store.releaseIdentifier(ofBinary: older.path) == "8.5.8-r1")

        // Saved paths to r1 move to r2; other paths and r2 itself stay.
        #expect(r2Store.replacement(forPHPPath: r1Store.binaryPath) == r2Store.binaryPath)
        #expect(r2Store.replacement(forPHPPath: r2Store.binaryPath) == nil)
        #expect(r2Store.replacement(forPHPPath: "/opt/homebrew/bin/php") == nil)
        #expect(r2Store.replacement(forPHPPath: data.appendingPathComponent("PHP/8.5.8-r1/bin/php-fpm").path) == nil)
        #expect(r2Store.replacement(forPHPPath: nil) == nil)

        _ = try await r2Store.install()
        #expect(await r2Store.installed()?.path == r2Store.binaryPath)
        #expect(await r2Store.installedOlder() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: r2Store.directory.path) == ["8.5.8-r2"])
    }

    /// #212: a data folder in /private/tmp (a Debug build's scratch folder) still moves saved
    /// paths once the old build's folder is gone, whichever spelling of the folder was saved.
    @Test func savedPathsMoveFromAFolderThatNoLongerExists() throws {
        let name = "runlet-212-\(UUID().uuidString)"
        let data = URL(fileURLWithPath: "/private/tmp/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("PHP"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        let placeholder = RunletPHPRelease.Asset(url: URL(string: "https://example.invalid/php.tar.gz")!, sha256: String(repeating: "0", count: 64), size: 0)
        for root in [data, URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)] {
            let store = RunletPHPStore(paths: AppPaths(root: root), release: RunletPHPRelease(version: "8.5.8", build: "r3", assets: ["arm64": placeholder]))
            for saved in ["/private/tmp/\(name)/PHP/8.5.8-r2/bin/php", "/tmp/\(name)/PHP/8.5.8-r2/bin/php", "/tmp/\(name)/PHP/./8.5.8-r2/bin/php"] {
                #expect(store.releaseIdentifier(ofBinary: saved) == "8.5.8-r2", "\(saved) in \(root.path)")
                #expect(store.replacement(forPHPPath: saved) == store.binaryPath)
            }
            #expect(store.replacement(forPHPPath: "/private/tmp/other/PHP/8.5.8-r2/bin/php") == nil)
        }
        #expect(RunletPHPStore.comparablePath(URL(fileURLWithPath: "/private/var/folders/x")) == "/var/folders/x")
        #expect(RunletPHPStore.comparablePath(URL(fileURLWithPath: "/private/tmpfoo/x")) == "/private/tmpfoo/x")
    }

    @Test func olderBuildsAreTriedNewestFirst() throws {
        let data = try DriverSupport.temporaryDirectory("runlet-php-data")
        defer { try? FileManager.default.removeItem(at: data) }
        let placeholder = RunletPHPRelease.Asset(url: URL(string: "https://example.invalid/php.tar.gz")!, sha256: String(repeating: "0", count: 64), size: 0)
        let store = RunletPHPStore(paths: AppPaths(root: data), release: RunletPHPRelease(version: "8.5.8", build: "r11", assets: ["arm64": placeholder]))
        for name in ["8.5.8-r2", "8.5.8-r10", "8.5.8-r11", ".download-1234", "8.5.8-r9"] {
            try FileManager.default.createDirectory(at: store.directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(store.olderReleaseIdentifiers() == ["8.5.8-r10", "8.5.8-r9", "8.5.8-r2"])
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

    /// #91: the empty list before the first discovery finishes is not "no PHP".
    @Test func theDownloadIsOfferedOnlyAfterDiscoveryFindsNoPHP() {
        let store = RunletPHPStore(paths: AppPaths(root: URL(fileURLWithPath: "/tmp/unused")))
        let herd = PHPInstallation(path: "/herd/php84", version: "8.4.10", hasTokenizer: true, source: "Herd")
        #expect(!store.shouldOffer(discoveryFinished: false, installations: [], isInstalled: false), "not while discovery runs")
        #expect(store.shouldOffer(discoveryFinished: true, installations: [], isInstalled: false), "offered when it found no PHP")
        #expect(!store.shouldOffer(discoveryFinished: true, installations: [herd], isInstalled: false), "not when it found one")
        #expect(!store.shouldOffer(discoveryFinished: true, installations: [], isInstalled: true), "not once installed")
    }

    /// The shipped release names both Macs' archives under its own tag, with real checksums,
    /// and says what it adds to Macs with an older build (r3: ext-mongodb, #212).
    @Test func currentReleaseIsPinnedForBothMacs() {
        let release = RunletPHPRelease.current
        #expect(release.identifier == "8.5.8-r3")
        #expect(release.changes?.contains("mongodb") == true)
        for arch in ["arm64", "x86_64"] {
            let asset = release.assets[arch]
            #expect(asset?.url.absoluteString == "https://github.com/filipac/runlet/releases/download/php-\(release.identifier)/runlet-php-\(release.identifier)-macos-\(arch).tar.gz")
            #expect(asset?.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && asset?.sha256 != String(repeating: "0", count: 64), "\(arch) is pinned")
            #expect((asset?.size ?? 0) > 1_000_000)
        }
        #expect(RunletPHPStore(paths: AppPaths(root: URL(fileURLWithPath: "/tmp/unused"))).isAvailable)
    }

    /// #212: the pinned release, downloaded from GitHub into `RUNLET_TEST_PHP_DOWNLOAD` (a
    /// scratch data folder, never Runlet's own), checked against its pinned checksum, unpacked,
    /// and run: it has the extensions Runlet relies on, mongodb included. An older build already
    /// in that folder (r2, from an earlier Runlet) is found first, replaced, and saved paths to
    /// it move to the new build, as Update in Settings ▸ PHP does. About 26 MB per run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUNLET_TEST_PHP_DOWNLOAD"] != nil, "set RUNLET_TEST_PHP_DOWNLOAD to a scratch data folder"))
    func installsThePinnedReleaseFromGitHub() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["RUNLET_TEST_PHP_DOWNLOAD"]))
        try #require(!root.standardizedFileURL.path.contains("/Library/Application Support/Runlet"), "a scratch folder, never Runlet's data")
        let store = RunletPHPStore(paths: AppPaths(root: root))
        let older = await store.installedOlder()?.path
        let fractions = FractionLog()
        let installed = try await store.install { fractions.append($0) }
        #expect(installed.path == store.binaryPath && installed.version == store.release.version && installed.source == RunletPHPStore.sourceName)
        #expect(fractions.values.last == 1)
        let listed = try TestProcess.runBlocking([installed.path, "-r", "echo implode(',', array_map('strtolower', get_loaded_extensions()));"], step: "extensions", within: .seconds(20))
        let extensions = Set(listed.output.split(separator: ",").map(String.init))
        for name in ["mongodb", "excimer", "redis", "pdo_mysql", "pdo_pgsql", "pdo_sqlite", "mysqli", "intl", "sodium", "tokenizer"] {
            #expect(extensions.contains(name), "\(name) in \(extensions.sorted())")
        }
        #expect(await MongoLaunch.hasMongoDB(installed.path))
        if let older {
            #expect(store.releaseIdentifier(ofBinary: older) != store.release.identifier)
            #expect(store.replacement(forPHPPath: older) == store.binaryPath, "saved paths move to the new build")
            #expect(!FileManager.default.fileExists(atPath: older), "the older build is removed")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path) == [store.release.identifier])
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
