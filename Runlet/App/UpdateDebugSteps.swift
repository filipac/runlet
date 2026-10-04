#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for in-app updates (#233), for end-to-end tests and screenshots with a
/// local feed (`RUNLET_UPDATE_FEED_URL`) and scratch data only (see `DebugSteps`):
/// `update:check` (Check for Updates…) · `update:auto` (an automatic check, which shows the window
/// only for an update) · `update:install` (Install and Relaunch on the offer) · `update:later` ·
/// `update:skip` (Skip This Version) · `update:cancel` · `update:install-now` (Install and
/// Relaunch once downloaded) · `update:close` · `update:channel:stable|beta|default` ·
/// `update:automatic:on|off` (Settings ▸ General ▸ Updates) · `update-state` (prints the
/// running version, channel, phase, and install location) · `update-wait:<phase>[:<seconds>]`
/// (holds the steps until the phase is found, upToDate, problem, downloading, extracting,
/// installing, idle, or `done` (no longer checking); at most 60 s by default).
///
/// After Install and Relaunch, the watchdog starts the new version with `RUNLET_DATA_DIR`, and
/// in Debug builds with every `RUNLET_RELAUNCH_<NAME>` as `RUNLET_<NAME>` (e.g.
/// `RUNLET_RELAUNCH_DEBUG_STEPS`), its standard error in `RUNLET_UPDATE_RELAUNCH_STDERR`.
/// `RUNLET_UPDATE_LAUNCH_TIMEOUT` shortens the 60 s it waits for the new version to start.
@MainActor
enum UpdateDebugSteps {
    static var waited: Double = 0

    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        let updater = model.updater
        switch name {
        case "update":
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts.first ?? "" {
            case "check": updater.check(userInitiated: true)
            case "auto": updater.debugAutomaticCheck()
            case "install": updater.installOffer()
            case "later": updater.later()
            case "skip": updater.skipVersion()
            case "cancel": updater.cancel()
            case "install-now": updater.installNow()
            case "close": UpdateWindow.close()
            case "channel": model.settings.updateChannel = UpdateChannel(rawValue: value)
            case "automatic": model.settings.automaticUpdateChecks = value != "off"
            default: log("update: \(argument)?")
            }
        case "update-state":
            log("update-state: \(updater.debugState) window=\(UpdateWindow.isVisible)")
        default:
            return false
        }
        return true
    }

    /// `update-wait:<phase>`: whether the updater is there.
    static func reached(_ argument: String, model: AppModel) -> Bool {
        let want = argument.split(separator: ":").first.map(String.init) ?? "done"
        switch (want, model.updater.phase) {
        case ("found", .found), ("upToDate", .upToDate), ("problem", .problem), ("downloading", .downloading),
             ("extracting", .extracting), ("ready", .readyToInstall), ("installing", .installing), ("idle", .idle):
            return true
        case ("done", let phase):
            return phase != .checking
        default:
            return false
        }
    }

    static func log(_ text: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(text)\n".utf8))
    }
}
#endif
