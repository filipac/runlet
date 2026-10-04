import Foundation
import RunletCore

/// Saved connections opened from this Mac (#142): which PHP opens them, the empty folder it
/// starts in, and the local `TargetSnapshot` the engine runs them with. Such a run is an
/// ordinary local run (same Stop, limits, timeouts, and output) whose runner boots no project
/// code (`plain`), in a folder of Runlet's that holds nothing, so nothing of the project runs or
/// is written to its directory.
public enum LocalConnectionLaunch {
    /// `TargetSnapshot.targetId` of a run from this Mac.
    public static let targetId = "this-mac"

    /// The PHP that opens connections from this Mac.
    public struct PHP: Sendable, Equatable {
        public var path: String
        /// "Runlet's PHP 8.5.8", "Herd PHP 8.4.25", "PHP 8.4.25".
        public var label: String
        public var isRunletPHP: Bool

        public init(path: String, label: String, isRunletPHP: Bool) {
            self.path = path
            self.label = label
            self.isRunletPHP = isRunletPHP
        }
    }

    /// Runlet's own PHP when it is installed (it has pdo_mysql, pdo_pgsql, and pdo_sqlite),
    /// else the default PHP from Settings, else the PHP Runlet would pick automatically.
    public static func choosePHP(runlet: PHPInstallation?, defaultPath: String?, installations: [PHPInstallation]) -> PHP? {
        if let runlet { return PHP(path: runlet.path, label: "Runlet's PHP \(runlet.version)", isRunletPHP: true) }
        if let defaultPath, !defaultPath.isEmpty {
            let known = installations.first { $0.path == defaultPath }
            return PHP(path: defaultPath, label: known.map(label(of:)) ?? "the default PHP", isRunletPHP: false)
        }
        guard let preferred = PHPDiscovery.preferred(installations.filter { $0.source != RunletPHPStore.sourceName }) else { return nil }
        return PHP(path: preferred.path, label: label(of: preferred), isRunletPHP: false)
    }

    /// "Herd PHP 8.4.25": the version and where it came from (Herd, Homebrew), never its path.
    static func label(of php: PHPInstallation) -> String {
        switch php.source {
        case RunletPHPStore.sourceName: "Runlet's PHP \(php.version)"
        case "Herd", "Homebrew": "\(php.source) PHP \(php.version)"
        default: "PHP \(php.version)"
        }
    }

    /// Why no PHP on this Mac can open the connection.
    public static func noPHPMessage(_ connection: DatabaseConnection) -> String {
        "No PHP on this Mac can open the saved connection “\(connection.name)”, so nothing ran. Download Runlet's PHP in Settings ▸ PHP (it has pdo_mysql, pdo_pgsql, and pdo_sqlite), or choose a PHP there."
    }

    /// The empty folder runs from this Mac start in (`<data>/LocalConnections`, private to
    /// this user). Runlet writes nothing into it.
    public static func directory(in paths: AppPaths) throws -> URL {
        let url = paths.root.appendingPathComponent("LocalConnections", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// The local snapshot of a run on `connection` from this Mac: "Reporting · this Mac
    /// (Runlet's PHP 8.5.8)".
    public static func snapshot(connection: DatabaseConnection, php: PHP, directory: URL) -> TargetSnapshot {
        TargetSnapshot(kind: .local, label: "\(connection.name) · this Mac (\(php.label))", targetId: targetId, profileRevision: connection.revision, workingDirectory: directory.path, phpExecutable: php.path)
    }

    /// Where a saved connection may be opened: one that opens from this Mac never goes to a
    /// container or a server (its password stays on this Mac). Throws before anything starts.
    static func check(_ connection: DatabaseConnection?, target: TargetSnapshot) throws {
        guard let connection, connection.opensOnThisMac, target.kind != .local || target.targetId != targetId else { return }
        throw ExecutionError.invalidTarget("The saved connection “\(connection.name)” opens from this Mac, so Runlet didn't send it to \(target.label). Nothing ran.")
    }
}
