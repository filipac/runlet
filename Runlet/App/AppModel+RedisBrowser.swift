import AppKit
import Observation
import RunletCore
import RunletExecution

/// The key browser of one target's Redis connection (#190), in memory while Runlet runs: the
/// database, pattern, and type it scans, the keys read so far, and what each key's details
/// and value said. Nothing is read by itself.
@MainActor
@Observable
final class RedisKeyBrowserState {
    var db = 0
    var pattern = "*"
    /// TYPE filter for SCAN; nil: every type.
    var type: String?
    var keys: [RedisKeyEntry] = []
    /// The next cursor; nil before the first scan, "0" when the scan is complete.
    var next: String?
    var pages = 0
    var loading = false
    var error: String?
    var databases: Int?
    var keyspace: [RedisKeyPage.Keyspace] = []
    var readAt: Date?
    /// Memory Usage per key (by its raw bytes, base64).
    var details: [String: RedisKeyDetails] = [:]
    var detailLoading: Set<String> = []
    var detailErrors: [String: String] = [:]
    /// What the last scan read: database, pattern, type.
    var scanned: String?
    @ObservationIgnored var task: Task<Void, Never>?

    /// The database numbers to offer.
    var databaseNumbers: [Int] { RedisKeyPage.databaseNumbers(databases: databases, keyspace: keyspace) }

    /// Another database: the keys listed belong to the last one.
    func select(db: Int) {
        guard db != self.db else { return }
        self.db = db
        keys = []
        next = nil
        pages = 0
        details = [:]
        detailErrors = [:]
        scanned = nil
    }

    func keyCount(db: Int) -> Int? { keyspace.first { $0.db == db }?.keys }
}

/// The Redis server panel of one target's connection (#190): the last INFO and CLIENT LIST,
/// and Kill Client's confirmation and outcome.
@MainActor
@Observable
final class RedisServerState {
    var report: RedisServerReport?
    var loading = false
    var error: String?
    var readAt: Date?
    /// The client a confirmed Kill is ending.
    var killing: Int64?
    var lastKill: RedisKillReport?
    @ObservationIgnored var task: Task<Void, Never>?
}

/// Kill Client's confirmation (#190): always asked, on every connection.
struct RedisKillConfirmation: Identifiable {
    let id = UUID()
    var tabId: UUID
    var key: String
    var client: RedisClientInfo
    var runId: String
    var listedBy: Int64
    var connection: SQLConnectionChoice
    var connectionLabel: String
    var isProduction: Bool
}

/// A key's value, opened from the key browser (#190), in a sheet.
struct RedisValueSheet: Identifiable {
    let id = UUID()
    var tabId: UUID
    var key: RedisKeyEntry
    var db: Int
    var reply: RedisReplyInfo?
    var error: String?
}

extension RedisUI {
    func browser(_ key: String) -> RedisKeyBrowserState {
        if let existing = browsers[key] { return existing }
        let created = RedisKeyBrowserState()
        browsers[key] = created
        return created
    }

    func server(_ key: String) -> RedisServerState {
        if let existing = servers[key] { return existing }
        let created = RedisServerState()
        servers[key] = created
        return created
    }
}

/// The Database pane for Redis tabs (#190): the key browser (SCAN with a pattern, never KEYS;
/// type and TTL with each page; memory usage and the value on demand) and the server panel
/// (INFO, CLIENT LIST, Kill Client). Reads happen when the user asks; production asks first.
extension AppModel {
    /// The browser's and server panel's key: the tab's target and Redis connection; nil when the
    /// tab's saved connection is missing.
    func redisPaneKey(for tab: TabModel) -> String? {
        guard tab.language == .redis, let ref = sqlConnectionChoice(for: tab).ref else { return nil }
        return (ref.isSaved ? "saved" : tab.target.stableKey) + "\u{1F}redis\u{1F}" + ref.key
    }

    /// "the default connection" / "the saved connection “Cache” (redis, …) from this Mac".
    func redisConnectionText(_ choice: SQLConnectionChoice) -> String {
        if let saved = choice.savedConnection {
            return "the saved connection “\(saved.name)” (\(saved.summary))" + savedConnectionPlace(saved)
        }
        return choice.label
    }

    /// Scans one page of keys: the first (`more: false`, which starts over) or the next.
    func scanRedisKeys(_ tab: TabModel, more: Bool = false) {
        guard let key = redisPaneKey(for: tab) else { return }
        let state = redisUI.browser(key)
        guard !state.loading else { return }
        if more, state.next == nil || state.next == "0" { return }
        let choice = sqlConnectionChoice(for: tab)
        let saved = choice.savedConnection
        let target = tab.target
        let db = state.db
        let pattern = state.pattern.isEmpty ? "*" : state.pattern
        let type = state.type
        let cursor = more ? (state.next ?? "0") : "0"
        let what = "SCAN \(cursor) MATCH \(RedisScript.quoted(pattern)) COUNT 200\(type.map { " TYPE \($0)" } ?? "") in database \(db), with each key's TYPE and PTTL"
        guardProduction(.redisKeys, target: target, text: what, sqlConnection: redisConnectionText(choice), sqlSaved: saved != nil, savedConnection: saved, in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab else { return }
            state.loading = true
            state.error = nil
            if !more {
                state.keys = []
                state.details = [:]
                state.detailErrors = [:]
                state.pages = 0
            }
            let task = Task {
                do {
                    let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                    defer { self.releaseSQLTunnel(snapshot) }
                    let page = try await self.engine.loadRedisKeys(target: snapshot, db: db, pattern: pattern, cursor: cursor, count: 200, type: type, connection: choice.ref?.appName, saved: saved)
                    let known = Set(state.keys.map(\.raw))
                    state.keys += page.keys.filter { !known.contains($0.raw) }
                    state.next = page.next
                    state.pages += 1
                    state.databases = page.databases ?? state.databases
                    state.keyspace = page.keyspace ?? state.keyspace
                    state.readAt = Date()
                    state.scanned = "db \(db) · \(pattern)" + (type.map { " · \($0)" } ?? "")
                    self.learnRedisConnections(page.connections, for: target)
                } catch is CancellationError {
                    state.error = "Stopped."
                } catch {
                    state.error = "\(error)"
                }
                state.loading = false
                state.task = nil
            }
            state.task = task
            self.trackDatabaseWork(DatabaseWork(purpose: .other(title: "Scan keys: \(pattern) in db \(db)", feature: "Database pane · Keys"), tabId: tab.id, tabTitle: tab.title, target: target, connection: choice) { task.cancel() }, until: task)
        }
    }

    func stopRedisScan(_ tab: TabModel) {
        guard let key = redisPaneKey(for: tab) else { return }
        redisUI.browsers[key]?.task?.cancel()
    }

    /// Memory Usage: the key's type, TTL, encoding, length, and MEMORY USAGE.
    func loadRedisKeyDetails(_ tab: TabModel, key entry: RedisKeyEntry) {
        guard let key = redisPaneKey(for: tab) else { return }
        let state = redisUI.browser(key)
        guard !state.detailLoading.contains(entry.raw) else { return }
        let choice = sqlConnectionChoice(for: tab)
        let saved = choice.savedConnection
        let db = state.db
        guardProduction(.redisKeys, target: tab.target, text: "MEMORY USAGE \(RedisScript.quoted(entry.bytes)), with its TYPE, PTTL, OBJECT ENCODING, and length, in database \(db)", sqlConnection: redisConnectionText(choice), sqlSaved: saved != nil, savedConnection: saved, in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab else { return }
            state.detailLoading.insert(entry.raw)
            state.detailErrors[entry.raw] = nil
            Task {
                do {
                    let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                    defer { self.releaseSQLTunnel(snapshot) }
                    state.details[entry.raw] = try await self.engine.loadRedisKeyDetails(target: snapshot, db: db, key: entry.bytes, connection: choice.ref?.appName, saved: saved)
                } catch {
                    state.detailErrors[entry.raw] = "\(error)"
                }
                state.detailLoading.remove(entry.raw)
            }
        }
    }

    /// Open Value: the key's value, read by its type, in a sheet.
    func openRedisValue(_ tab: TabModel, key entry: RedisKeyEntry) {
        guard let key = redisPaneKey(for: tab) else { return }
        let state = redisUI.browser(key)
        let choice = sqlConnectionChoice(for: tab)
        let saved = choice.savedConnection
        let db = state.db
        let maxElements = settings.sqlRowsPerPage
        guardProduction(.redisKeys, target: tab.target, text: "\(entry.readCommand) in database \(db) (at most \(maxElements.formatted()) elements)", sqlConnection: redisConnectionText(choice), sqlSaved: saved != nil, savedConnection: saved, in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab else { return }
            let sheet = RedisValueSheet(tabId: tab.id, key: entry, db: db)
            self.redisUI.value = sheet
            Task {
                var result = sheet
                do {
                    let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                    defer { self.releaseSQLTunnel(snapshot) }
                    result.reply = try await self.engine.loadRedisValue(target: snapshot, db: db, key: entry.bytes, maxElements: maxElements, connection: choice.ref?.appName, saved: saved)
                } catch {
                    result.error = "\(error)"
                }
                if self.redisUI.value?.id == sheet.id { self.redisUI.value = result }
            }
        }
    }

    /// Insert Command: the command that reads the key, on a new line at the caret. Runs nothing.
    func insertRedisCommand(_ tab: TabModel, key entry: RedisKeyEntry) {
        guard tab.language == .redis else { return }
        let editor = tab.editor
        let text = editor.text as NSString
        let caret = min(editor.selectedRange.location, text.length)
        let atLineStart = caret == 0 || text.character(at: caret - 1) == 10
        editor.insert((atLineStart ? "" : "\n") + entry.readCommand + "\n")
    }

    // MARK: Server panel

    func loadRedisServer(_ tab: TabModel) {
        guard let key = redisPaneKey(for: tab) else { return }
        let state = redisUI.server(key)
        guard !state.loading else { return }
        let choice = sqlConnectionChoice(for: tab)
        let saved = choice.savedConnection
        let target = tab.target
        guardProduction(.redisServer, target: target, text: "INFO, CLIENT LIST, CLIENT ID", sqlConnection: redisConnectionText(choice), sqlSaved: saved != nil, savedConnection: saved, in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab else { return }
            state.loading = true
            state.error = nil
            let task = Task {
                do {
                    let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                    defer { self.releaseSQLTunnel(snapshot) }
                    state.report = try await self.engine.loadRedisServer(target: snapshot, connection: choice.ref?.appName, saved: saved)
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
            self.trackDatabaseWork(DatabaseWork(purpose: .other(title: "Read INFO and CLIENT LIST", feature: "Database pane · Server"), tabId: tab.id, tabTitle: tab.title, target: target, connection: choice) { task.cancel() }, until: task)
        }
    }

    /// Kill Client: asks first, always, naming the client.
    func askKillRedisClient(_ tab: TabModel, client: RedisClientInfo) {
        guard let key = redisPaneKey(for: tab), let report = redisUI.servers[key]?.report else { return }
        if client.id == report.ownId {
            alert = AppAlert(title: "That's Runlet's own connection", message: "Client \(client.id) is the connection the panel listed the clients with; it closes by itself. Nothing was killed.")
            return
        }
        let choice = sqlConnectionChoice(for: tab)
        redisUI.kill = RedisKillConfirmation(tabId: tab.id, key: key, client: client, runId: report.runId ?? "", listedBy: report.ownId ?? 0, connection: choice, connectionLabel: redisConnectionText(choice), isProduction: isProduction(tab.target, connection: choice.savedConnection))
    }

    func cancelKillRedisClient() {
        redisUI.kill = nil
    }

    /// The user confirmed: a fresh runner checks the server and the client, then CLIENT KILL ID.
    func confirmKillRedisClient() {
        guard let confirmation = redisUI.kill else { return }
        redisUI.kill = nil
        guard let tab = allTabs.first(where: { $0.id == confirmation.tabId }), redisPaneKey(for: tab) == confirmation.key else { return }
        let state = redisUI.server(confirmation.key)
        let saved = confirmation.connection.savedConnection
        state.killing = confirmation.client.id
        tab.appendRunLog("server", "Database pane: Kill Client \(confirmation.client.id) (\(confirmation.client.address)), confirmed", detail: "CLIENT KILL ID \(confirmation.client.id) through \(confirmation.connectionLabel)")
        let task = Task {
            let report: RedisKillReport
            do {
                let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                defer { self.releaseSQLTunnel(snapshot) }
                report = await self.engine.killRedisClient(target: snapshot, clientId: confirmation.client.id, address: confirmation.client.address, runId: confirmation.runId, listedBy: confirmation.listedBy, connection: confirmation.connection.ref?.appName, saved: saved)
            } catch {
                report = RedisKillReport(id: confirmation.client.id, outcome: .failed, detail: "\(error)")
            }
            state.killing = nil
            state.lastKill = report
            tab.appendRunLog("server", "Kill Client \(confirmation.client.id): \(report.outcome.rawValue)", detail: report.detail)
            if report.outcome == .killed, var current = state.report, let clients = current.clients {
                // The killed client leaves the list until the next read.
                current.clients = clients.components(separatedBy: "\n").filter { !$0.hasPrefix("id=\(confirmation.client.id) ") }.joined(separator: "\n")
                state.report = current
            }
        }
        trackDatabaseWork(DatabaseWork(purpose: .other(title: "Kill Client \(confirmation.client.id)", feature: "Database pane · Server"), tabId: tab.id, tabTitle: tab.title, target: tab.target, connection: confirmation.connection) { task.cancel() }, until: task)
    }
}
