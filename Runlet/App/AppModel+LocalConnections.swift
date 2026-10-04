import AppKit
import RunletCore
import RunletExecution

/// Saved connections opened from this Mac (#142): those whose Connect From says this Mac, and
/// every connection of all targets. They run in a local PHP process (Runlet's PHP when it is
/// installed, else the default PHP from Settings) in an empty folder of Runlet's, with the
/// `plain` bootstrap, so no project code runs and nothing is written to the project. Stop,
/// limits, timeouts, and output are those of local runs; production marking and read-only are
/// unchanged; the password still reaches PHP only on stdin.
extension AppModel {
    /// The PHP that opens connections from this Mac, or nil when there is none.
    var localConnectionPHP: LocalConnectionLaunch.PHP? {
        let runlet: PHPInstallation? = switch runletPHPState {
        case .installed(let php), .updateAvailable(let php): php
        default: nil
        }
        return LocalConnectionLaunch.choosePHP(runlet: runlet, defaultPath: settings.defaultPHPExecutable, installations: phpInstallations)
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

    /// Where a saved connection is opened, for the editor, the SQL bar, and Test Connection:
    /// "this Mac (Runlet's PHP 8.5.8)", "this Mac (Runlet's PHP 8.5.8) through SSH “bastion”"
    /// (#143), or the target's name.
    func openedFromLabel(_ connection: DatabaseConnection, tabTarget: TargetRef? = nil) -> String {
        if connection.usesSSHTunnel {
            return thisMacLabel + " through SSH " + (library.tunnelProfile(of: connection).map { "“\($0.name)”" } ?? "(its profile is missing)")
        }
        if connection.opensOnThisMac { return thisMacLabel }
        return targetLabel(connection.scope ?? tabTarget ?? .sandbox)
    }

    /// The snapshot of a run on `connection` from this Mac. Throws, with what to do, when this
    /// Mac has no PHP.
    func localConnectionSnapshot(for connection: DatabaseConnection) async throws -> TargetSnapshot {
        if localConnectionPHP == nil { await waitForFirstDiscovery() }
        var chosen = localConnectionPHP
        if connection.driver == .mongodb {
            var candidates = chosen.map { [$0] } ?? []
            if let path = settings.defaultPHPExecutable, !path.isEmpty {
                candidates.append(.init(path: path, label: "Default PHP", isRunletPHP: false))
            }
            candidates += phpInstallations.map { .init(path: $0.path, label: "\($0.source) PHP \($0.version)", isRunletPHP: false) }
            chosen = await MongoLaunch.choosePHP(candidates: candidates)
            if chosen == nil { throw TargetResolutionError(description: "No local PHP has ext-mongodb. Install ext-mongodb in a PHP shown in Settings ▸ PHP, then try again.") }
        }
        guard let php = chosen else {
            throw TargetResolutionError(description: LocalConnectionLaunch.noPHPMessage(connection))
        }
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
