import AppKit
import Observation
import RunletCore
import RunletExecution

/// The Database pane's two views (#150): the schema's tables (#21) and the server.
enum DatabasePaneSection: String, CaseIterable {
    case tables = "Tables"
    case server = "Server"
}

/// What the Server section knows about one target's connection (#150), kept in memory while
/// Runlet runs (never saved): the last report, when each part was read, what is being read,
/// the refresh interval the user turned on (nil: off), and the last action's outcome.
@MainActor
@Observable
final class DatabaseServerState {
    var info: SQLServerInfo?
    var readAt: [SQLServerInfo.Part: Date] = [:]
    var loading: Set<SQLServerInfo.Part> = []
    /// The last read failed as a whole (the connection didn't open, a timeout, …).
    var failure: String?
    /// Seconds between automatic reads of the sessions; nil when off (the default).
    var refreshInterval: Int?
    /// Sessions a confirmed action ended or cancelled since the list was read, by id.
    var ended: [Int64: SQLServerActionReport] = [:]
    /// The session an action is under way on.
    var acting: Int64?
    var lastAction: SQLServerActionReport?
    var lastActionAt: Date?
    @ObservationIgnored var readTask: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?

    var isLoading: Bool { !loading.isEmpty }
}

/// A Cancel Query or Kill Session waiting for the user's answer (#150). It always asks, on every
/// connection, production or not.
struct ServerActionConfirmation: Identifiable {
    let id = UUID()
    var plan: SQLServerActionPlan
    var session: SQLServerInfo.Session
    /// The window whose sheet asks.
    var windowId: UUID?
    var tabId: UUID
    var target: TargetRef
    var key: String
    var connection: SQLConnectionChoice
    var openedFrom: String
    var isProduction: Bool
    var title: String
    var sessionLine: String
    var text: String
}

/// The Server sections' state (#150), per app model.
@MainActor
@Observable
final class DatabaseServerStore {
    var states: [String: DatabaseServerState] = [:]
    var section: DatabasePaneSection = .tables
    var sessionFilter = ""
    var hideIdle = false
    var confirmation: ServerActionConfirmation?
    /// What the last read or action did, for DEBUG steps.
    var lastEvent: String?

    private static var stores: [ObjectIdentifier: DatabaseServerStore] = [:]

    static func shared(for model: AppModel) -> DatabaseServerStore {
        let key = ObjectIdentifier(model)
        if let existing = stores[key] { return existing }
        let created = DatabaseServerStore()
        stores[key] = created
        return created
    }
}

/// The Database pane's Server section (#150): the server's version, the database's size and
/// largest tables, and its sessions, for the explorer's connection, read on demand in a fresh
/// runner (production asks before each read; the refresh interval is never offered there), and
/// a Cancel Query or Kill Session on a session that always asks first. Nothing reads by itself:
/// the refresh interval is off until the user picks one, and stops when the pane hides, the tab
/// changes, or Runlet goes to the background.
extension AppModel {
    var databaseServer: DatabaseServerStore { DatabaseServerStore.shared(for: self) }

    /// The state key: the target and connection, like the schema's (`SQLSchemaStore.key`).
    func serverKey(for tab: TabModel) -> String? {
        explorerConnection(for: tab).ref.map { SQLSchemaStore.key(tab.target, $0) }
    }

    func serverState(for tab: TabModel) -> DatabaseServerState? {
        serverKey(for: tab).flatMap { databaseServer.states[$0] }
    }

    /// Whether the explorer's connection for `tab` is production (the target's or the saved connection's marking).
    func serverIsProduction(for tab: TabModel) -> Bool {
        isProduction(tab.target, connection: explorerConnection(for: tab).savedConnection)
    }

    /// Read (or Refresh): reads `parts` of the server report. Production asks first, every time.
    func readDatabaseServer(for tab: TabModel, parts: [SQLServerInfo.Part] = SQLServerInfo.Part.allCases) {
        let choice = explorerConnection(for: tab)
        if case .missing(let name) = choice {
            alert = AppAlert(title: "The saved connection isn't defined", message: SQLConnectionChoice.missingMessage(name))
            return
        }
        guard let key = serverKey(for: tab), databaseServer.states[key]?.isLoading != true else { return }
        let saved = choice.savedConnection
        let what = (parts.count == SQLServerInfo.Part.allCases.count ? "Read the server's version, uptime, and TLS, the database's size and largest tables, and the server's sessions" : "Read the server's " + parts.map { $0.title.lowercased() }.joined(separator: " and "))
            + " through \(choice.label)"
            + (saved.map { " (\($0.summary)) (opens the connection \($0.opensOnThisMac ? "from this Mac" : "without booting the application")" } ?? " (boots the application")
            + ", reads only the catalog and the server's status, no rows, and runs nothing else)"
        guardProduction(.sqlServer, target: tab.target, text: what, sqlConnection: saved.map { "the saved connection “\($0.name)” (\($0.summary))" + ($0.opensOnThisMac ? " from this Mac" : "") } ?? choice.label, sqlSaved: saved != nil, savedConnection: saved,
                        in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, self.serverKey(for: tab) == key else { return }
            self.performServerRead(for: tab, key: key, parts: parts)
        }
    }

    /// The read itself, after any production confirmation (or a refresh tick off production).
    private func performServerRead(for tab: TabModel, key: String, parts: [SQLServerInfo.Part]) {
        let choice = explorerConnection(for: tab)
        guard let ref = choice.ref else { return }
        let state = databaseServer.states[key] ?? DatabaseServerState()
        databaseServer.states[key] = state
        guard !state.isLoading else { return }
        let saved = choice.savedConnection
        state.loading = Set(parts)
        let task = Task { [weak self, weak state] in
            guard let self else { return }
            do {
                // From this Mac for a saved connection that opens there (#142), else on the target.
                let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                let info = try await self.engine.loadSQLServerInfo(target: snapshot, parts: parts, connection: ref.appName, saved: saved)
                guard let state else { return }
                let now = Date()
                state.info = state.info.map { $0.merged(with: info) } ?? info
                for part in parts { state.readAt[part] = now }
                if parts.contains(.sessions) { state.ended = [:] }
                state.failure = nil
                self.databaseServer.lastEvent = "read \(parts.map(\.rawValue).joined(separator: "+")): \(info.overview?.server ?? "-"), \(info.sizes?.tables.count ?? 0) tables, \(info.sessions?.list.count ?? 0) sessions, errors \(info.errors ?? [:])"
            } catch is CancellationError {
                self.databaseServer.lastEvent = "read stopped"
            } catch {
                state?.failure = "\(error)"
                self.databaseServer.lastEvent = "read failed: \(error)"
            }
            state?.loading = []
            state?.readTask = nil
        }
        state.readTask = task
        // #180: listed in the Connection Manager while it reads; Close stops it.
        trackDatabaseWork(DatabaseWork(purpose: .serverRead, tabId: tab.id, tabTitle: tab.title, target: tab.target, connection: choice) { task.cancel() }, until: task)
    }

    // MARK: Refresh

    /// Turns the sessions' refresh interval on (`seconds`) or off (nil) for the tab's connection.
    /// Never on production. It stops by itself when the tab isn't the selected one of its window
    /// any more, the Server section isn't shown, the connection changes, or it became production.
    func setServerRefresh(_ seconds: Int?, for tab: TabModel) {
        guard let key = serverKey(for: tab) else { return }
        let state = databaseServer.states[key] ?? DatabaseServerState()
        databaseServer.states[key] = state
        state.refreshTask?.cancel()
        state.refreshTask = nil
        guard let seconds, SQLServerPanel.refreshIntervals(isProduction: serverIsProduction(for: tab)).contains(seconds) else {
            state.refreshInterval = nil
            return
        }
        state.refreshInterval = seconds
        let tabId = tab.id
        databaseServer.lastEvent = "refresh every \(seconds) s"
        state.refreshTask = Task { [weak self, weak state] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, let state else { return }
                guard let tab = self.windows.lazy.compactMap({ $0.selectedTab }).first(where: { $0.id == tabId }),
                      self.serverKey(for: tab) == key, self.showInspector, self.inspectorPane == .database, self.databaseServer.section == .server,
                      !self.serverIsProduction(for: tab) else {
                    self.stopServerRefresh(reason: "the Server section, its tab, or its connection changed")
                    return
                }
                if !state.isLoading { self.performServerRead(for: tab, key: key, parts: [.sessions]) }
            }
        }
    }

    /// Turns every refresh interval off: the pane hid, the tab changed, or Runlet went to the background.
    func stopServerRefresh(reason: String) {
        var stopped = false
        for state in databaseServer.states.values where state.refreshInterval != nil || state.refreshTask != nil {
            state.refreshTask?.cancel()
            state.refreshTask = nil
            state.refreshInterval = nil
            stopped = true
        }
        if stopped { databaseServer.lastEvent = "refresh stopped: \(reason)" }
    }

    // MARK: Cancel Query and Kill Session

    /// Asks before Cancel Query or Kill Session on `session`, always (on every connection). The
    /// panel's own session and databases without the statements are refused with the reason.
    func requestServerAction(_ action: SQLServerAction, session: SQLServerInfo.Session, for tab: TabModel) {
        guard let key = serverKey(for: tab), let state = databaseServer.states[key], let info = state.info else { return }
        let choice = explorerConnection(for: tab)
        switch SQLServerPanel.plan(action, session: session, info: info) {
        case .failure(let refusal):
            alert = AppAlert(title: "Runlet won't \(action == .kill ? "kill" : "cancel the statement of") session \(session.id)", message: refusal.message)
            databaseServer.lastEvent = "refused: \(refusal.message)"
        case .success(let plan):
            let openedFrom = choice.savedConnection.map { openedFromLabel($0, tabTarget: tab.target) } ?? targetLabel(tab.target)
            let production = serverIsProduction(for: tab)
            databaseServer.confirmation = ServerActionConfirmation(
                plan: plan, session: session, windowId: window(containing: tab.id)?.id, tabId: tab.id, target: tab.target, key: key,
                connection: choice, openedFrom: openedFrom, isProduction: production,
                title: SQLServerPanel.confirmationTitle(plan),
                sessionLine: SQLServerPanel.sessionLine(session, readAt: state.readAt[.sessions] ?? Date()),
                text: SQLServerPanel.confirmationText(plan, connection: choice.label, openedFrom: openedFrom, isProduction: production, readOnly: choice.savedConnection?.readOnly == true)
            )
            databaseServer.lastEvent = "asking: \(plan.statement)"
        }
    }

    func cancelServerAction() {
        if databaseServer.confirmation != nil { databaseServer.lastEvent = "not sent" }
        databaseServer.confirmation = nil
    }

    /// The user confirmed: a fresh runner sends the statement after its checks. The Run Log of
    /// the tab records it (the statement and the outcome, never the session's statement text).
    func confirmServerAction() {
        guard let confirmation = databaseServer.confirmation else { return }
        databaseServer.confirmation = nil
        guard let tab = windows.lazy.flatMap(\.tabs).first(where: { $0.id == confirmation.tabId }), serverKey(for: tab) == confirmation.key,
              let state = databaseServer.states[confirmation.key] else { return }
        let saved = confirmation.connection.savedConnection
        let ref = confirmation.connection.ref
        state.acting = confirmation.plan.session
        tab.appendRunLog("server", "Database pane: \(confirmation.plan.action.title) on session \(confirmation.plan.session) with \(confirmation.plan.statement), confirmed",
                         detail: "Through \(confirmation.connection.label) on \(confirmation.openedFrom); listed as \(confirmation.session.userAndHost)")
        let task = Task { [weak self, weak state] in
            guard let self else { return }
            let report: SQLServerActionReport
            do {
                let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                report = await self.engine.runSQLServerAction(confirmation.plan, target: snapshot, connection: ref?.appName, saved: saved)
            } catch {
                report = SQLServerActionReport(action: confirmation.plan.action, outcome: .failed, driver: confirmation.plan.dialect, session: confirmation.plan.session, statement: confirmation.plan.statement, detail: "\(error)")
            }
            state?.acting = nil
            state?.lastAction = report
            state?.lastActionAt = Date()
            if report.succeeded { state?.ended[report.session] = report }
            tab.appendRunLog("server", report.logMessage(connection: confirmation.connection.label),
                              detail: [report.statement, report.elapsedMs.map { String(format: "%.0f ms", $0) }, report.state, report.detail].compactMap { $0 }.joined(separator: " · "))
            self.databaseServer.lastEvent = "action: \(report.outcome.rawValue) — \(report.message)"
        }
        // #180: listed in the Connection Manager while it runs; Close stops waiting for it.
        trackDatabaseWork(DatabaseWork(purpose: .serverAction("\(confirmation.plan.action.title) on session \(confirmation.plan.session)"), tabId: tab.id, tabTitle: tab.title,
                                       target: confirmation.target, connection: confirmation.connection) { task.cancel() }, until: task)
    }
}
