import Foundation

/// Current schema version of every app-owned JSON document.
public let persistenceSchemaVersion = 1

/// Versioned envelope written around each persisted document.
struct Envelope<T: Codable>: Codable {
    var schemaVersion: Int
    var savedAt: Date
    var data: T
}

public struct LoadOutcome<T: Sendable>: Sendable {
    public var value: T
    /// Human-readable notes about recovery (corrupt file preserved, fell back to last-good copy…).
    public var recoveryNotes: [String]
}

/// Atomic, recoverable JSON persistence for one document.
///
/// Writes go to a temporary file in the same directory and replace the target atomically.
/// Before replacing, the previous valid file is kept as `<name>.last-good.json`. A file
/// that cannot be decoded is preserved as `<name>.corrupt-<timestamp>.json` rather than
/// silently overwritten.
public struct JSONDocumentStore<T: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    var lastGoodURL: URL { url.deletingPathExtension().appendingPathExtension("last-good.json") }

    public func load(default makeDefault: @autoclosure () -> T) -> LoadOutcome<T> {
        var notes: [String] = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            if let recovered = try? decode(at: lastGoodURL) {
                notes.append("\(url.lastPathComponent) was missing; restored the last good copy.")
                return LoadOutcome(value: recovered, recoveryNotes: notes)
            }
            return LoadOutcome(value: makeDefault(), recoveryNotes: notes)
        }
        do {
            return LoadOutcome(value: try decode(at: url), recoveryNotes: notes)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let corrupt = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
            try? fm.moveItem(at: url, to: corrupt)
            notes.append("\(url.lastPathComponent) could not be read (\(error.localizedDescription)); it was preserved as \(corrupt.lastPathComponent).")
            if let recovered = try? decode(at: lastGoodURL) {
                notes.append("Restored the last good copy of \(url.lastPathComponent).")
                return LoadOutcome(value: recovered, recoveryNotes: notes)
            }
            return LoadOutcome(value: makeDefault(), recoveryNotes: notes)
        }
    }

    private func decode(at url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        // Dates use Foundation's native (lossless) encoding: seconds since 2001-01-01.
        let envelope = try decoder.decode(Envelope<T>.self, from: data)
        guard envelope.schemaVersion <= persistenceSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "written by a newer Runlet (schema \(envelope.schemaVersion))"])
        }
        return envelope.data
    }

    public func save(_ value: T) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(schemaVersion: persistenceSchemaVersion, savedAt: Date(), data: value))

        // Keep the previous file as last-good only if it still decodes.
        if fm.fileExists(atPath: url.path), (try? decode(at: url)) != nil {
            let staging = directory.appendingPathComponent(".\(UUID().uuidString).lastgood")
            try? fm.copyItem(at: url, to: staging)
            if rename(staging.path, lastGoodURL.path) != 0 { try? fm.removeItem(at: staging) }
        }

        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

/// Locations of Runlet's app-owned data.
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var standard: AppPaths { standard(appBundle: .main) }

    /// `RUNLET_DATA_DIR` when set, else `~/Library/Application Support/<folder>`, where the folder
    /// is the app's `RunletDataFolder` Info.plist key: "Runlet" for releases, "Runlet Dev" for
    /// Debug builds, so a build from Xcode keeps its own tabs, settings, Keychain items, and MCP
    /// socket next to the installed app (#267). The `runlet` command passes the app it belongs to.
    public static func standard(appBundle: Bundle?, environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let override = environment["RUNLET_DATA_DIR"], !override.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AppPaths(root: base.appendingPathComponent(folderName(appBundle: appBundle), isDirectory: true))
    }

    /// The Info.plist key that names the data folder (#267).
    public static let folderKey = "RunletDataFolder"
    public static let releaseFolderName = "Runlet"

    /// The app's data folder name: its `RunletDataFolder`, when that's a plain name, else "Runlet".
    public static func folderName(appBundle: Bundle?) -> String {
        guard let name = (appBundle?.object(forInfoDictionaryKey: folderKey) as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), !name.hasPrefix("$(") else { return releaseFolderName }
        return name
    }

    public var state: URL { root.appendingPathComponent("State", isDirectory: true) }
    public var settings: URL { state.appendingPathComponent("settings.json") }
    public var targets: URL { state.appendingPathComponent("targets.json") }
    public var snippets: URL { state.appendingPathComponent("snippets.json") }
    public var history: URL { state.appendingPathComponent("history.json") }
    public var session: URL { state.appendingPathComponent("session.json") }
    public var sandboxes: URL { root.appendingPathComponent("Sandbox", isDirectory: true) }
    public var languageService: URL { root.appendingPathComponent("LanguageService", isDirectory: true) }
    public var runs: URL { root.appendingPathComponent("Runs", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    /// Startup files that report a shell's first prompt (`ShellIntegration`); rewritten on use.
    public var shellIntegration: URL { root.appendingPathComponent("ShellIntegration", isDirectory: true) }
    /// OpenSSH control sockets of SSH profiles (0700; see `SSHControlPaths`).
    public var ssh: URL { root.appendingPathComponent("SSH", isDirectory: true) }
    /// In-app updates (#233): the backup, markers, and log of an update being installed (`UpdateFiles`).
    public var updates: URL { root.appendingPathComponent("Updates", isDirectory: true) }
}
