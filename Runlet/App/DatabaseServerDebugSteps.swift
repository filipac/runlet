#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for the Database pane's Server section (#150), for screenshots and scripted
/// checks with scratch data only (see `DebugSteps`):
/// `server:tables|server` (picks the pane's section) · `server-read[:<parts>]` (Read Server
/// Details for the current tab, as its button does: production asks first; parts joined by `+`,
/// e.g. `server-read:sessions`) · `server-filter:<text>` and `server-hide-idle:on|off` (the
/// sessions' filter) · `server-refresh:<seconds>|off` (the refresh interval; refused on
/// production) · `server-action:cancel|kill:<session id or text in its statement>` (the row's
/// Cancel Query… or Kill Session…: the confirmation, or the refusal's alert) ·
/// `server-confirm:yes|no` (answers the confirmation) · `server-state` (prints the section,
/// what was read, the refresh, the confirmation, and the last event).
@MainActor
enum DatabaseServerDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "server":
            model.databaseServer.section = argument == "tables" ? .tables : .server
        case "server-read":
            guard let tab = model.selectedTab else { return true }
            model.databaseServer.section = .server
            let parts = argument.split(separator: "+").compactMap { SQLServerInfo.Part(rawValue: String($0)) }
            model.readDatabaseServer(for: tab, parts: parts.isEmpty ? SQLServerInfo.Part.allCases : parts)
        case "server-filter":
            model.databaseServer.sessionFilter = argument
        case "server-hide-idle":
            model.databaseServer.hideIdle = argument != "off"
        case "server-refresh":
            guard let tab = model.selectedTab else { return true }
            model.setServerRefresh(Int(argument), for: tab)
        case "server-action":
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard let tab = model.selectedTab, parts.count == 2, let action = SQLServerAction(rawValue: parts[0]),
                  let sessions = model.serverState(for: tab)?.info?.sessions?.list else {
                log("server-action: nothing to act on (\(argument))")
                return true
            }
            let match = sessions.first { String($0.id) == parts[1] } ?? sessions.first { !$0.isOwn && $0.query?.contains(parts[1]) == true }
            guard let session = match else {
                log("server-action: no session \(parts[1])")
                return true
            }
            model.requestServerAction(action, session: session, for: tab)
        case "server-confirm":
            if argument == "no" { model.cancelServerAction() } else { model.confirmServerAction() }
        case "server-state":
            log("server-state: \(state(model))")
        default:
            return false
        }
        return true
    }

    static func state(_ model: AppModel) -> String {
        let store = model.databaseServer
        guard let tab = model.selectedTab else { return "no tab" }
        let state = model.serverState(for: tab)
        let info = state?.info
        let sessions = info?.sessions?.list ?? []
        let read = [
            "overview=\(info?.overview?.server ?? "-")",
            "tls=\(info?.overview?.tlsText ?? "-")",
            "sizes=\(info?.sizes.map { "\($0.tables.count) tables, \($0.databaseBytes.map(SQLServerPanel.bytes) ?? "-")" } ?? "-")",
            "sessions=\(sessions.count) (own \(sessions.first { $0.isOwn }.map { String($0.id) } ?? "-"), visibility \(info?.sessions?.visibility ?? "-"))",
            "notes=\(info?.sessions?.notes ?? [])",
            "errors=\(info?.errors ?? [:])",
        ]
        let confirmation = store.confirmation.map { "\($0.title) [\($0.plan.statement)]\($0.isProduction ? " production" : "")" } ?? "none"
        return "section=\(store.section.rawValue) loading=\(state?.isLoading == true) failure=\(state?.failure ?? "none") \(read.joined(separator: " ")) refresh=\(state?.refreshInterval.map { "\($0) s" } ?? "off") production=\(model.serverIsProduction(for: tab)) confirmation=\(confirmation) ended=\(state?.ended.keys.sorted() ?? []) last=\(store.lastEvent ?? "none") runlog=\(tab.runLog.filter { $0.source == "server" }.map(\.message))"
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
