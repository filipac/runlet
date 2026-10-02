import Foundation
import RunletCore

/// Metadata shipped with the pinned sandbox template (`runlet-sandbox.json`).
public struct SandboxManifest: Sendable, Codable, Equatable {
    public var laravelVersion: String
    public var phpConstraint: String
    public var minimumPHP: String
    public var dockerImage: String

    public var minimumPHPComponents: (Int, Int) {
        let parts = minimumPHP.split(separator: ".").compactMap { Int($0) }
        return (parts.first ?? 8, parts.count > 1 ? parts[1] : 0)
    }
}

/// How the sandbox will execute on this machine.
public enum SandboxRuntime: Sendable, Equatable {
    case local(PHPInstallation)
    /// Docker fallback; `imagePresent` false means a first-use image download is needed.
    case docker(image: String, imagePresent: Bool)
    case unavailable(String)
}

/// Installs the pinned Laravel sandbox into app-owned, writable storage and resets it.
///
/// The packaged template stays immutable; each Laravel version installs into its own
/// directory under Application Support so caches, compiled views, logs, and the SQLite
/// database are writable. Reset only touches that directory.
public struct SandboxManager: Sendable {
    public let templateURL: URL
    public let paths: AppPaths
    public let manifest: SandboxManifest

    /// Path used inside the disposable Docker sandbox container.
    public static let containerDirectory = "/sandbox"

    public init(templateURL: URL, paths: AppPaths) throws {
        self.templateURL = templateURL
        self.paths = paths
        let data = try Data(contentsOf: templateURL.appendingPathComponent("runlet-sandbox.json"))
        self.manifest = try JSONDecoder().decode(SandboxManifest.self, from: data)
    }

    public var installURL: URL {
        paths.sandboxes.appendingPathComponent("laravel-\(manifest.laravelVersion)", isDirectory: true)
    }

    private var installedMarker: URL { installURL.appendingPathComponent(".runlet-installed") }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: installedMarker.path) }

    /// Copies the template (APFS clones make this cheap) and writes a sandbox `.env`.
    @discardableResult
    public func ensureInstalled() throws -> URL {
        if isInstalled { return installURL }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.sandboxes, withIntermediateDirectories: true)
        let staging = paths.sandboxes.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: templateURL, to: staging)
        try Self.environmentFile().write(to: staging.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        for directory in ["storage/logs", "storage/framework/cache/data", "storage/framework/sessions", "storage/framework/views", "storage/app/private", "storage/app/public", "bootstrap/cache"] {
            try fm.createDirectory(at: staging.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let database = staging.appendingPathComponent("database/database.sqlite")
        if !fm.fileExists(atPath: database.path) {
            fm.createFile(atPath: database.path, contents: Data())
        }
        try Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: staging.appendingPathComponent(".runlet-installed"))
        if fm.fileExists(atPath: installURL.path) { try fm.removeItem(at: installURL) }
        try fm.moveItem(at: staging, to: installURL)
        return installURL
    }

    /// Deletes only the sandbox-owned installation and reinstalls a fresh copy.
    public func reset() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: installURL.path) {
            try fm.removeItem(at: installURL)
        }
        try ensureInstalled()
    }

    static func environmentFile() -> String {
        var key = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, key.count, &key)
        return """
        APP_NAME="Runlet Sandbox"
        APP_ENV=local
        APP_KEY=base64:\(Data(key).base64EncodedString())
        APP_DEBUG=true
        APP_URL=http://localhost

        LOG_CHANNEL=single
        LOG_LEVEL=debug

        # SQLite at database/database.sqlite (relative to the sandbox, so it works locally and in Docker).
        DB_CONNECTION=sqlite

        SESSION_DRIVER=array
        CACHE_STORE=file
        QUEUE_CONNECTION=sync
        BROADCAST_CONNECTION=log
        FILESYSTEM_DISK=local

        # Mail is written to storage/logs/laravel.log, never delivered.
        MAIL_MAILER=log
        MAIL_FROM_ADDRESS="sandbox@runlet.local"
        MAIL_FROM_NAME="Runlet Sandbox"

        """
    }

    /// Active service configuration, shown in the UI so users know what the sandbox uses.
    public static let serviceSummary = "SQLite database · file cache · sync queue · mail to log"

    /// Chooses local PHP when a compatible one exists, else Docker.
    public func chooseRuntime(preferredPHP: String?, installations: [PHPInstallation], docker: DockerCLI?) async -> SandboxRuntime {
        let minimum = manifest.minimumPHPComponents
        if let preferredPHP, let preferred = installations.first(where: { $0.path == preferredPHP || $0.path == ExecutableLocator.resolve(preferredPHP) }),
           preferred.satisfies(minimum: minimum), preferred.hasTokenizer {
            return .local(preferred)
        }
        if let compatible = PHPDiscovery.preferred(installations, minimum: minimum) {
            return .local(compatible)
        }
        guard let docker else {
            return .unavailable("The sandbox needs PHP \(manifest.minimumPHP)+ or Docker. Neither was found.")
        }
        do {
            _ = try await docker.serverVersion()
        } catch {
            return .unavailable("The sandbox needs PHP \(manifest.minimumPHP)+ or a running Docker engine: \(error)")
        }
        return .docker(image: manifest.dockerImage, imagePresent: await docker.imageExists(manifest.dockerImage))
    }
}
