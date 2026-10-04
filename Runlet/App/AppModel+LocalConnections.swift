import AppKit
import RunletCore
import RunletExecution

/// Saved connections opened from this Mac (#142): those whose Connect From says this Mac, and
/// every connection of all targets. They run in a local PHP process in an empty folder of
/// Runlet's, with the `plain` bootstrap, so no project code runs and nothing is written to the
/// project. The PHP is the first, in order (Runlet's PHP, the default PHP from Settings, the
/// automatic choice, then the others), that has the connection's driver (#184). Stop, limits,
/// timeouts, and output are those of local runs; production marking and read-only are
/// unchanged; the password still reaches PHP only on stdin.
extension AppModel {
    /// The first choice for connections from this Mac, whatever their driver, or nil when this
    /// Mac has no PHP. A connection gets `localConnectionChoice(for:)`.
    var localConnectionPHP: LocalConnectionLaunch.PHP? {
        localPHPCandidates.first
    }

    /// The PHPs connections from this Mac may use, in order (#184).
    var localPHPCandidates: [LocalConnectionLaunch.PHP] {
        LocalConnectionLaunch.candidates(runlet: installedRunletPHP, defaultPath: settings.defaultPHPExecutable, installations: phpInstallations)
    }

    /// What a local PHP can open connections with (#184): read by discovery, or once by the
    /// cache for a path discovery doesn't list. Never runs PHP.
    func knownPHPDrivers(_ path: String) -> PHPDrivers? {
        if let runlet = installedRunletPHP, runlet.path == path, let drivers = runlet.drivers { return drivers }
        return phpInstallations.first { $0.path == path }?.drivers ?? phpDriverCache.known(path)
    }

    /// The PHP `connection` opens with from this Mac (#184): the first candidate that has its
    /// driver, and why when it isn't the first. nil when none has it, or this Mac has no PHP.
    func localConnectionChoice(for connection: DatabaseConnection) -> LocalConnectionLaunch.Choice? {
        LocalConnectionLaunch.choosePHP(for: connection, candidates: localPHPCandidates, drivers: knownPHPDrivers)
    }

    /// "Herd PHP 8.4.25, the first PHP here with pdo_sqlsrv or pdo_dblib", for the connection
    /// editor; what's missing when no PHP has the driver.
    func localPHPDescription(for connection: DatabaseConnection) -> String {
        if let choice = localConnectionChoice(for: connection) { return choice.label }
        let candidates = localPHPCandidates
        let requirement = PHPDriverRequirement(connection)
        guard !candidates.isEmpty, requirement != .none else { return "a PHP on this Mac (none found yet: download Runlet's PHP in Settings ▸ PHP)" }
        return "a PHP on this Mac with \(requirement.name) (none of \(ConnectionText.list(candidates.map(\.label))) has it: install it in one, see Settings ▸ PHP)"
    }

    /// Runlet's own PHP when it is installed, an older build included.
    private var installedRunletPHP: PHPInstallation? {
        switch runletPHPState {
        case .installed(let php), .updateAvailable(let php): php
        default: nil
        }
    }

    /// Whether Runlet's own PHP is installed (the editor offers to download it otherwise).
    var hasRunletPHP: Bool {
        switch runletPHPState {
        case .installed, .updateAvailable: true
        default: false
        }
    }

    /// "this Mac (Runlet's PHP 8.5.8)", or "this Mac" before a PHP is known.
    var thisMacLabel: String {
        localConnectionPHP.map { "this Mac (\($0.label))" } ?? "this Mac"
    }

    /// "this Mac (Herd PHP 8.4.25, the first PHP here with pdo_sqlsrv or pdo_dblib)": the PHP
    /// `connection` opens with (#184), and why when it isn't the first choice.
    func thisMacLabel(for connection: DatabaseConnection) -> String {
        localConnectionChoice(for: connection).map { "this Mac (\($0.label))" } ?? thisMacLabel
    }

    /// Where a saved connection is opened, for the editor, the SQL bar, and Test Connection:
    /// "this Mac (Runlet's PHP 8.5.8)", "this Mac (Runlet's PHP 8.5.8) through SSH “bastion”"
    /// (#143), or the target's name.
    func openedFromLabel(_ connection: DatabaseConnection, tabTarget: TargetRef? = nil) -> String {
        if connection.usesSSHTunnel {
            return thisMacLabel(for: connection) + " through SSH " + (library.tunnelProfile(of: connection).map { "“\($0.name)”" } ?? "(its profile is missing)")
        }
        if connection.opensOnThisMac { return thisMacLabel(for: connection) }
        return targetLabel(connection.scope ?? tabTarget ?? .sandbox)
    }

    /// The snapshot of a run on `connection` from this Mac, with the first PHP that has its
    /// driver (#184; the run header names it, and why when it isn't the first choice). Throws,
    /// with what to do, when no PHP on this Mac has the driver, or there is none.
    func localConnectionSnapshot(for connection: DatabaseConnection) async throws -> TargetSnapshot {
        if localConnectionPHP == nil { await waitForFirstDiscovery() }
        let candidates = localPHPCandidates
        // Discovery read the drivers of every PHP it lists; a default PHP it doesn't list is read
        // once and kept until the installations change. Nothing is probed per run.
        await phpDriverCache.prepare(candidates.map(\.path))
        guard let choice = LocalConnectionLaunch.choosePHP(for: connection, candidates: candidates, drivers: knownPHPDrivers) else {
            throw TargetResolutionError(description: LocalConnectionLaunch.noPHPMessage(connection, checked: candidates))
        }
        var php = choice.php
        php.label = choice.label
        let directory: URL
        do {
            directory = try LocalConnectionLaunch.directory(in: paths)
        } catch {
            throw TargetResolutionError(description: "Runlet couldn't create its folder for connections from this Mac: \(error.localizedDescription)")
        }
        return LocalConnectionLaunch.snapshot(connection: connection, php: php, directory: directory)
    }

    /// Where an SQL tab's statement, page, or schema read runs: from this Mac for a saved
    /// connection that opens there (through its SSH tunnel, #143: the caller ends the run's
    /// hold on the forward with `releaseSQLTunnel`), else on the tab's target (`snapshot(for:)`).
    /// `askToConnect: false` (#143, the Database pane's refresh ticks) fails instead of asking
    /// when a tunnel's SSH profile isn't connected.
    func sqlSnapshot(for tab: TabModel, saved: DatabaseConnection?, askToConnect: Bool = true) async throws -> TargetSnapshot {
        if let saved, saved.usesSSHTunnel { return try await tunnelSnapshot(for: saved, tab: tab, askToConnect: askToConnect) }
        if let saved, saved.opensOnThisMac { return try await localConnectionSnapshot(for: saved) }
        return try await snapshot(for: tab)
    }

    /// Settings ▸ PHP, where Runlet's PHP is downloaded (the editor's link for a missing PHP or driver).
    func showPHPSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SettingsTabSelection.select("PHP")
        }
    }
}

/// Picks a tab of the open Settings window by its toolbar item's label, as a click on it would
/// (the connection editor's link to Settings ▸ PHP; the `settings-tab` Debug step does the same).
@MainActor
enum SettingsTabSelection {
    static func select(_ label: String) {
        let items = NSApp.windows.compactMap(\.toolbar).flatMap(\.items)
        if let item = items.first(where: { $0.label == label }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }
}
