import AppKit
import Observation
import RunletCore
import RunletExecution

/// The MongoDB Server section of one target's connection (#207), in memory while Runlet runs:
/// the last `serverStatus` and `$currentOp`, the refresh interval the user turned on (nil: off,
/// the default; never on production), and Kill Op's outcome.
@MainActor
@Observable
final class MongoServerState {
    var report: MongoServerReport?
    var loading = false
    var error: String?
    var readAt: Date?
    /// Seconds between automatic reads; nil when off.
    var refreshInterval: Int?
    /// The operation a confirmed Kill Op is ending.
    var killing: String?
    var lastKill: MongoKillReport?
    /// Hide the operations Runlet's own runs and panels are doing.
    var hideRunlet = false
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
}

extension MongoUI {
    func server(_ key: String) -> MongoServerState {
        if let existing = servers[key] { return existing }
        let created = MongoServerState()
        servers[key] = created
        return created
    }
}

/// The Database pane's Server section for MongoDB tabs (#207), like SQL's (#150) and Redis's: a
/// `serverStatus` summary and the server's operations (`$currentOp`), read on demand in a fresh
/// runner (production asks before each read; the refresh interval is never offered there), and
/// Kill Op on an operation, which always asks first in the shared danger sheet and refuses the
/// panel's own read.
extension AppModel {
    /// The panel's key: the tab's target and MongoDB connection (`mongoCacheKey`).
    func mongoServerKey(for tab: TabModel) -> String? {
        guard tab.language == .mongodb, sqlConnectionChoice(for: tab).ref != nil else { return nil }
        return mongoCacheKey(tab)
    }

    /// "the default connection" / "the saved connection “Docs” (mongodb, …) from this Mac".
    func mongoConnectionText(_ choice: SQLConnectionChoice) -> String {
        if let saved = choice.savedConnection {
            return "the saved connection “\(saved.name)” (\(saved.summary))" + savedConnectionPlace(saved)
        }
        return choice.label
    }

    /// Read Server Details (or Refresh): `serverStatus` and `$currentOp`. Production asks first.
    func loadMongoServer(_ tab: TabModel) {
        guard let key = mongoServerKey(for: tab) else { return }
        let choice = sqlConnectionChoice(for: tab)
        guardProduction(.sqlServer, target: tab.target, text: "serverStatus (version, uptime, connections, memory, replica set) and $currentOp (the server's operations)",
                        sqlConnection: mongoConnectionText(choice), sqlSaved: choice.savedConnection != nil, savedConnection: choice.savedConnection,
                        in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, self.mongoServerKey(for: tab) == key else { return }
            self.performMongoServerRead(tab, key: key)
        }
    }

    /// The read itself, after any production confirmation (or a refresh tick off production).
    private func performMongoServerRead(_ tab: TabModel, key: String, askToConnect: Bool = true) {
        let state = MongoUI.shared.server(key)
        guard !state.loading else { return }
        let choice = sqlConnectionChoice(for: tab)
        let saved = choice.savedConnection
        state.loading = true
        state.error = nil
        let task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            do {
                let snapshot = try await self.sqlSnapshot(for: tab, saved: saved, askToConnect: askToConnect)
                defer { self.releaseSQLTunnel(snapshot) }
                state.report = try await self.engine.loadMongoServer(target: snapshot, connection: choice.ref?.appName, saved: saved)
                state.readAt = Date()
            } catch is CancellationError {
                state.error = "Stopped."
            } catch {
                state.error = "\(error)"
            }
            state.loading = false
            state.task = nil
        }
        state.task = task
        trackDatabaseWork(DatabaseWork(purpose: .serverRead, tabId: tab.id, tabTitle: tab.title, target: tab.target, connection: choice) { task.cancel() }, until: task)
    }

    /// Turns the refresh interval on (`seconds`) or off (nil). Never on production; it stops by
    /// itself when the tab isn't selected, the Server section hides, or the connection changes.
    func setMongoServerRefresh(_ seconds: Int?, for tab: TabModel) {
        guard let key = mongoServerKey(for: tab) else { return }
        let state = MongoUI.shared.server(key)
        state.refreshTask?.cancel()
        state.refreshTask = nil
        let production = isProduction(tab.target, connection: sqlConnectionChoice(for: tab).savedConnection)
        guard let seconds, MongoServerPanel.refreshIntervals(isProduction: production).contains(seconds) else {
            state.refreshInterval = nil
            return
        }
        state.refreshInterval = seconds
        let tabId = tab.id
        state.refreshTask = Task { [weak self, weak state] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, let state else { return }
                guard let tab = self.windows.lazy.compactMap({ $0.selectedTab }).first(where: { $0.id == tabId }),
                      self.mongoServerKey(for: tab) == key, self.showInspector, self.inspectorPane == .database, self.databaseServer.section == .server,
                      !self.isProduction(tab.target, connection: self.sqlConnectionChoice(for: tab).savedConnection), NSApp.isActive else {
                    state.refreshInterval = nil
                    state.refreshTask = nil
                    return
                }
                if !state.loading { self.performMongoServerRead(tab, key: key, askToConnect: false) }
            }
        }
    }

    /// Kill Op: asks first, always, in the shared danger sheet. The panel's own read is refused.
    func askKillMongoOperation(_ tab: TabModel, operation: MongoServerReport.Operation) {
        guard let key = mongoServerKey(for: tab), let report = MongoUI.shared.servers[key]?.report else { return }
        if let refusal = MongoServerPanel.refusal(operation) {
            alert = AppAlert(title: "That's Runlet's own operation", message: refusal)
            return
        }
        let choice = sqlConnectionChoice(for: tab)
        let production = isProduction(tab.target, connection: choice.savedConnection)
        let tabId = tab.id
        MongoUI.shared.kill = DatabaseDangerConfirmation.mongoKill(operation, connection: mongoConnectionText(choice), isProduction: production, tabId: tabId) { [weak self] in
            guard let self, let tab = self.allTabs.first(where: { $0.id == tabId }), self.mongoServerKey(for: tab) == key else { return }
            self.killMongoOperation(tab, operation: operation, report: report, key: key)
        }
    }

    func confirmMongoKill() {
        guard let kill = MongoUI.shared.kill else { return }
        MongoUI.shared.kill = nil
        kill.perform()
    }

    func cancelMongoKill() {
        MongoUI.shared.kill = nil
    }

    /// The user confirmed: a fresh runner checks the server and the operation, then `killOp`.
    private func killMongoOperation(_ tab: TabModel, operation: MongoServerReport.Operation, report: MongoServerReport, key: String) {
        let state = MongoUI.shared.server(key)
        let choice = sqlConnectionChoice(for: tab)
        let saved = choice.savedConnection
        state.killing = operation.opid
        tab.appendRunLog("server", "Database pane: Kill Op \(operation.opid) (\(operation.title)), confirmed", detail: "killOp through \(mongoConnectionText(choice))")
        let task = Task { [weak self] in
            guard let self else { return }
            let outcome: MongoKillReport
            do {
                let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                defer { self.releaseSQLTunnel(snapshot) }
                outcome = await self.engine.killMongoOperation(operation, report: report, target: snapshot, connection: choice.ref?.appName, saved: saved)
            } catch {
                outcome = MongoKillReport(opid: operation.opid, outcome: .failed, detail: "\(error)")
            }
            state.killing = nil
            state.lastKill = outcome
            tab.appendRunLog("server", "Kill Op \(operation.opid): \(outcome.outcome.rawValue)", detail: outcome.detail)
            if outcome.outcome == .killed || outcome.outcome == .gone, var current = state.report {
                // The operation leaves the list until the next read.
                current.operations = current.operations?.filter { $0.opid != operation.opid }
                state.report = current
            }
        }
        trackDatabaseWork(DatabaseWork(purpose: .serverAction("Kill Op \(operation.opid)"), tabId: tab.id, tabTitle: tab.title, target: tab.target, connection: choice) { task.cancel() }, until: task)
    }
}
