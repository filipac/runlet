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

    /// The first choice, whatever the driver: Runlet's own PHP when it is installed (it has
    /// pdo_mysql, pdo_pgsql, pdo_sqlite, and ext-mongodb), else the default PHP from Settings,
    /// else the PHP Runlet would pick automatically. A connection gets the first of
    /// `candidates` that has its driver (`choosePHP(for:candidates:drivers:)`, #184).
    public static func choosePHP(runlet: PHPInstallation?, defaultPath: String?, installations: [PHPInstallation]) -> PHP? {
        candidates(runlet: runlet, defaultPath: defaultPath, installations: installations).first
    }

    /// The PHPs that may open a connection from this Mac, in order (#184; #212's list for
    /// MongoDB, now for every driver): Runlet's own PHP, the default PHP from Settings, the PHP
    /// Runlet would pick automatically, then every other discovered PHP (Herd, Homebrew, …).
    /// Each path once; labels never show a path.
    public static func candidates(runlet: PHPInstallation?, defaultPath: String?, installations: [PHPInstallation]) -> [PHP] {
        var ordered: [PHP] = []
        if let runlet { ordered.append(PHP(path: runlet.path, label: "Runlet's PHP \(runlet.version)", isRunletPHP: true)) }
        if let defaultPath, !defaultPath.isEmpty {
            let known = installations.first { $0.path == defaultPath }
            ordered.append(PHP(path: defaultPath, label: known.map(label(of:)) ?? "the default PHP", isRunletPHP: known?.source == RunletPHPStore.sourceName))
        }
        // Runlet's PHP is listed with the discovered ones; it came first already.
        let others = installations.filter { $0.source != RunletPHPStore.sourceName }
        let preferred = PHPDiscovery.preferred(others)
        for php in (preferred.map { [$0] } ?? []) + others {
            ordered.append(PHP(path: php.path, label: label(of: php), isRunletPHP: false))
        }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.path).inserted }
    }

    /// The PHP a connection from this Mac runs with, and why when it isn't the first candidate.
    public struct Choice: Sendable, Equatable {
        public var php: PHP
        public var requirement: PHPDriverRequirement
        /// The candidates before it, which lack the driver.
        public var passedOver: [PHP]
        /// No candidate is known to have the driver, and this one's drivers couldn't be read:
        /// Runlet tries it (the runner says what it lacks).
        public var unchecked: Bool

        public init(php: PHP, requirement: PHPDriverRequirement, passedOver: [PHP] = [], unchecked: Bool = false) {
            self.php = php
            self.requirement = requirement
            self.passedOver = passedOver
            self.unchecked = unchecked
        }

        /// "Herd PHP 8.4.25, the first PHP here with pdo_sqlsrv or pdo_dblib" when an earlier
        /// PHP lacks the driver; else the PHP's label. The run header and Test Connection.
        public var label: String {
            passedOver.isEmpty || unchecked ? php.label : "\(php.label), the first PHP here with \(requirement.name)"
        }

        /// "Runlet's PHP 8.5.8 comes first but has neither pdo_sqlsrv nor pdo_dblib." nil for
        /// the first choice.
        public var reason: String? {
            guard !passedOver.isEmpty else { return nil }
            let names = ConnectionText.list(passedOver.map(\.label))
            let first = passedOver.count == 1 ? "comes first but \(requirement.missing(plural: false))" : "come first but \(requirement.missing(plural: true))"
            let sentence = names.prefix(1).uppercased() + names.dropFirst() + " " + first + "."
            return unchecked ? sentence + " Runlet couldn't read the drivers of \(php.label), so it tries that one." : sentence
        }
    }

    /// The first of `candidates` that has what `connection` needs (#184): its PDO driver
    /// (`pdo_sqlsrv` or `pdo_dblib` for SQL Server, the DSN's own for a custom one) or
    /// ext-mongodb; a Redis connection needs nothing. `drivers` says what each PHP has, from
    /// discovery or the cache; it never runs PHP. A PHP whose drivers aren't known is tried only
    /// when no known one has the driver. nil when none has it: say so with `noPHPMessage(_:checked:)`.
    public static func choosePHP(for connection: DatabaseConnection, candidates: [PHP], drivers: (String) -> PHPDrivers?) -> Choice? {
        let requirement = PHPDriverRequirement(connection)
        // Redis: Runlet's RESP client needs no extension, so the first PHP will do.
        if requirement == .none { return candidates.first.map { Choice(php: $0, requirement: requirement) } }
        var passedOver: [PHP] = []
        var firstUnknown: (php: PHP, before: [PHP])?
        for php in candidates {
            guard let known = drivers(php.path) else {
                if firstUnknown == nil { firstUnknown = (php, passedOver) }
                continue
            }
            if requirement.isMet(by: known) { return Choice(php: php, requirement: requirement, passedOver: passedOver) }
            passedOver.append(php)
        }
        guard let firstUnknown else { return nil }
        return Choice(php: firstUnknown.php, requirement: requirement, passedOver: firstUnknown.before, unchecked: !firstUnknown.before.isEmpty)
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

    /// Why no PHP on this Mac can open `connection` (#184): the driver it needs and the PHPs
    /// checked, and what to do. "No PHP on this Mac has pdo_sqlsrv or pdo_dblib, which the saved
    /// connection “Warehouse” needs, so nothing ran. Checked Runlet's PHP 8.5.8 and Herd PHP 8.4.25. …"
    public static func noPHPMessage(_ connection: DatabaseConnection, checked: [PHP]) -> String {
        let requirement = PHPDriverRequirement(connection)
        guard !checked.isEmpty, requirement != .none else { return noPHPMessage(connection) }
        let what = "No PHP on this Mac has \(requirement.name), which the saved connection “\(connection.name)” needs, so nothing ran. Checked \(ConnectionText.list(checked.map(\.label)))."
        let hasRunletPHP = checked.contains(where: \.isRunletPHP)
        if connection.driver == .mongodb {
            return what + " Download or update Runlet's PHP in Settings ▸ PHP (it has ext-mongodb from build r3), or install ext-mongodb in a PHP listed there."
        }
        if [.mysql, .pgsql, .sqlite].contains(connection.driver), !hasRunletPHP {
            return what + " Download Runlet's PHP in Settings ▸ PHP: it has pdo_mysql, pdo_pgsql, and pdo_sqlite."
        }
        let install = "install the driver in one of these PHPs (Settings ▸ PHP lists them), or open the connection from a target whose PHP has it."
        return what + (hasRunletPHP ? " Runlet's PHP doesn't come with it: " + install : " " + install.prefix(1).uppercased() + install.dropFirst())
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
    /// container or a server (its password stays on this Mac). One through an SSH tunnel
    /// (#143) opens only through its forward on 127.0.0.1, never straight to its host (a name
    /// this Mac may resolve to another machine). Throws before anything starts.
    static func check(_ connection: DatabaseConnection?, target: TargetSnapshot) throws {
        guard let connection, connection.opensOnThisMac else { return }
        guard target.kind == .local, target.targetId == targetId else {
            throw ExecutionError.invalidTarget("The saved connection “\(connection.name)” opens from this Mac, so Runlet didn't send it to \(target.label). Nothing ran.")
        }
        if connection.usesSSHTunnel, target.sqlTunnel == nil {
            throw ExecutionError.invalidTarget("The saved connection “\(connection.name)” connects through an SSH tunnel, and this run has none, so Runlet didn't open it. Nothing ran.")
        }
    }

    /// #143: the local snapshot of a run through an SSH tunnel: as `snapshot(connection:php:directory:)`,
    /// with the forward its PHP connects to. "Shop · this Mac (Runlet's PHP 8.5.8) through bastion".
    public static func snapshot(connection: DatabaseConnection, php: PHP, directory: URL, tunnel: SQLTunnelRoute) -> TargetSnapshot {
        var snapshot = snapshot(connection: connection, php: php, directory: directory)
        snapshot.label += " through \(tunnel.profileName)"
        snapshot.sqlTunnel = tunnel
        return snapshot
    }
}
