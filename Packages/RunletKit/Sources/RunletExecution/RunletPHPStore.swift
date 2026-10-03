import CryptoKit
import Foundation
import RunletCore

/// Downloads, verifies, and installs Runlet's own PHP (`RunletPHPRelease`) into
/// `<data>/PHP/<version>-<build>/` ([#2](https://github.com/filipac/runlet/issues/2)).
///
/// Nothing is downloaded unless `install` is called (an explicit user action). The archive is
/// checked against the pinned SHA-256 before it is unpacked, the unpacked `bin/php` must run
/// and report the expected version, and the folder is moved into place only then, so a
/// failed or cancelled download never leaves a half-installed PHP behind.
public struct RunletPHPStore: Sendable {
    public enum InstallError: Error, Equatable, CustomStringConvertible {
        case notAvailable
        case download(String)
        case tooLarge
        case checksumMismatch
        case unpack(String)
        case notWorking

        public var description: String {
            switch self {
            case .notAvailable: "This build of Runlet has no PHP download for this Mac."
            case .download(let reason): "The download failed: \(reason)"
            case .tooLarge: "The download was larger than expected and was discarded."
            case .checksumMismatch: "The download did not match its checksum and was discarded."
            case .unpack(let reason): "The archive could not be unpacked: \(reason)"
            case .notWorking: "The downloaded PHP did not run on this Mac."
            }
        }
    }

    public let release: RunletPHPRelease
    /// `<data>/PHP`.
    public let directory: URL

    public init(paths: AppPaths, release: RunletPHPRelease = .current) {
        self.release = release
        self.directory = paths.root.appendingPathComponent("PHP", isDirectory: true)
    }

    public var installDirectory: URL { directory.appendingPathComponent(release.identifier, isDirectory: true) }
    public var binaryPath: String { installDirectory.appendingPathComponent("bin/php").path }

    /// Whether this release's archive exists for this Mac (the pinned checksum is real).
    public var isAvailable: Bool {
        guard let asset = release.assetForThisMac else { return false }
        return asset.size > 0 && asset.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && asset.sha256 != String(repeating: "0", count: 64)
    }

    /// The installed PHP, if this release is installed and runs. Never downloads.
    public func installed() async -> PHPInstallation? {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else { return nil }
        return await PHPDiscovery.inspect(path: binaryPath, source: RunletPHPStore.sourceName)
    }

    /// An older build left from an earlier Runlet (e.g. `8.5.8-r1` when this one installs
    /// `-r2`) that still runs: used until the user updates, so nothing breaks in between.
    /// The newest working one when there are several. Never downloads.
    public func installedOlder() async -> PHPInstallation? {
        for identifier in olderReleaseIdentifiers() {
            let binary = directory.appendingPathComponent(identifier, isDirectory: true).appendingPathComponent("bin/php").path
            guard FileManager.default.isExecutableFile(atPath: binary) else { continue }
            if let php = await PHPDiscovery.inspect(path: binary, source: RunletPHPStore.sourceName) { return php }
        }
        return nil
    }

    /// Folders of other releases in `directory`, newest first by name ("8.5.8-r10" after "-r9").
    func olderReleaseIdentifiers() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries
            .filter { $0 != release.identifier && !$0.hasPrefix(".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// The release folder (e.g. "8.5.8-r1") of a PHP binary inside `directory`, or nil for any
    /// other path.
    public func releaseIdentifier(ofBinary path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == "php", url.deletingLastPathComponent().lastPathComponent == "bin" else { return nil }
        let release = url.deletingLastPathComponent().deletingLastPathComponent()
        guard release.deletingLastPathComponent().path == directory.standardizedFileURL.path else { return nil }
        return release.lastPathComponent
    }

    /// The path a saved PHP setting should use instead of `path`: this release's binary when
    /// `path` is another Runlet release's binary (moved on update), nil when it needs no change.
    public func replacement(forPHPPath path: String?) -> String? {
        guard let path, let identifier = releaseIdentifier(ofBinary: path), identifier != release.identifier else { return nil }
        return binaryPath
    }

    /// The `source` of the installation in PHP lists.
    public static let sourceName = "Runlet"

    /// Discovered installations with Runlet's own PHP last: automatic choices (the sandbox,
    /// projects without a PHP) pick it only when no installed PHP fits.
    public static func merged(discovered: [PHPInstallation], runlet: PHPInstallation?) -> [PHPInstallation] {
        guard let runlet else { return discovered }
        return discovered.filter { $0.path != runlet.path } + [runlet]
    }

    /// Downloads, verifies, unpacks, and installs this release; returns the working PHP.
    /// `progress` gets the downloaded fraction (nil while the size is unknown).
    public func install(progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws -> PHPInstallation {
        guard isAvailable, let asset = release.assetForThisMac else { throw InstallError.notAvailable }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = directory.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let archive = try await Self.download(asset.url, to: work.appendingPathComponent("php.tar.gz"), expectedSize: asset.size, progress: progress)
        guard try Self.sha256(of: archive) == asset.sha256.lowercased() else { throw InstallError.checksumMismatch }

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let tar = try await runCommand(ProcessSpec(executable: "/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", unpacked.path]), timeout: .seconds(120))
        guard tar.exitCode == 0 else { throw InstallError.unpack(String(decoding: tar.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        let root = unpacked.appendingPathComponent("php-\(release.identifier)", isDirectory: true)
        let binary = root.appendingPathComponent("bin/php")
        guard fileManager.isExecutableFile(atPath: binary.path) else { throw InstallError.unpack("bin/php is missing") }
        guard let working = await PHPDiscovery.inspect(path: binary.path, source: Self.sourceName), working.version == release.version else {
            throw InstallError.notWorking
        }
        _ = working

        if fileManager.fileExists(atPath: installDirectory.path) { try fileManager.removeItem(at: installDirectory) }
        try fileManager.moveItem(at: root, to: installDirectory)
        removeOtherReleases()
        guard let installation = await installed() else { throw InstallError.notWorking }
        return installation
    }

    /// Deletes this release's folder (and any older ones).
    public func remove() throws {
        if FileManager.default.fileExists(atPath: installDirectory.path) {
            try FileManager.default.removeItem(at: installDirectory)
        }
        removeOtherReleases()
    }

    /// Older releases left by earlier Runlet versions.
    private func removeOtherReleases() {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries where entry != release.identifier && !entry.hasPrefix(".download-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    // MARK: Download and checksum

    /// A download task with a session delegate (the async `download(from:)` reports no
    /// progress to it): progress as bytes arrive, and a download growing past twice the
    /// expected size is stopped there.
    static func download(_ url: URL, to destination: URL, expectedSize: Int64, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let delegate = Download(expectedSize: expectedSize, destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(session.downloadTask(with: url), continuation: continuation)
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        progress(1)
        return destination
    }

    /// Lowercase hex SHA-256 of a file, read in 1 MiB chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One download: reports progress (a fraction of the server's length, or of the expected
/// size), moves the finished file to `destination`, and resumes the caller once. The
/// session calls it on its own serial queue; `lock` covers `start`, which runs elsewhere.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expectedSize: Int64
    let destination: URL
    let progress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    /// Why the download failed before the session reported its end.
    private var failure: RunletPHPStore.InstallError?

    init(expectedSize: Int64, destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.expectedSize = expectedSize
        self.destination = destination
        self.progress = progress
    }

    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if expectedSize > 0, totalBytesWritten > expectedSize * 2 {
            lock.withLock { failure = .tooLarge }
            downloadTask.cancel()
            return
        }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        progress(total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns: move it now.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return lock.withLock { failure = .download("HTTP \(http.statusCode)") }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
        if expectedSize > 0, size > expectedSize * 2 {
            return lock.withLock { failure = .tooLarge }
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { failure = .download(error.localizedDescription) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, self.failure)
        }
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: RunletPHPStore.InstallError.download(error.localizedDescription))
        } else {
            continuation?.resume()
        }
    }
}
