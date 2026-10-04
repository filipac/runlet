import AppKit
import Observation
import RunletCore
import RunletExecution

/// Redis connection names the runner reported for each target during this session (#190), for
/// Redis tabs' connection pickers. Never saved: the application's config is the source.
@MainActor
@Observable
final class RedisConnectionCatalog {
    var names: [String: [String]] = [:]

    private static var catalogs: [ObjectIdentifier: RedisConnectionCatalog] = [:]

    static func shared(for model: AppModel) -> RedisConnectionCatalog {
        let key = ObjectIdentifier(model)
        if let existing = catalogs[key] { return existing }
        let created = RedisConnectionCatalog()
        catalogs[key] = created
        return created
    }
}

extension SQLRunInfo {
    /// #190: a Redis run's info: its commands (each `statement` shows the line with passwords
    /// as •••), the connection, and, for Run All, whether it runs in MULTI/EXEC.
    init(redis commands: [RedisScript.Command], connection: String?, saved: DatabaseConnection?, transaction: Bool?) {
        let statements = commands.map(\.statement)
        self.init(statement: statements.first ?? SQLScript.Statement(text: "", range: NSRange(location: 0, length: 0), startLine: 1), connection: connection, saved: saved)
        self.statements = statements
        self.transaction = transaction
        language = .redis
        redisCommands = commands
        historyCode = commands.map(\.displayText).joined(separator: "\n")
    }

    /// The output's first line under the run header: "Redis command from line 3 on the saved
    /// connection “Cache” (redis, 127.0.0.1:6379/0) from this Mac."
    var redisNote: String {
        let readOnlyNote = readOnly ? ", read-only" : ""
        guard let transaction else {
            return "Redis command from line \(statements.first?.startLine ?? 1) on \(connectionLabel)\(readOnlyNote)."
        }
        let first = statements.first?.startLine ?? 1
        let last = statements.last?.startLine ?? first
        let place = first == last ? "line \(first)" : "lines \(first)–\(last)"
        let count = statements.count == 1 ? "1 command" : "\(statements.count) commands"
        return transaction
            ? "\(count) from \(place) on \(connectionLabel)\(readOnlyNote), in one MULTI/EXEC transaction: Redis queues them, then runs them all."
            : "\(count) from \(place) on \(connectionLabel)\(readOnlyNote), one by one. Runlet stops at the first error; Redis has no rollback."
    }
}

extension ProductionConfirmation {
    /// #190: "Run this Redis command on production? It can change data."
    var redisTitle: String {
        let count = sqlStatements?.count ?? 1
        let what = count == 1 ? "this Redis command" : "\(count) Redis commands"
        return sqlWarning == nil ? "Run \(what) on production?" : "Run \(what) on production? \(count == 1 ? "It" : "Some") can change data."
    }

    /// #190: what a Redis command, key read, or server read does on production.
    var redisExplanation: String {
        let readOnly = sqlReadOnly ? " The connection is read-only: Runlet refuses commands that can write." : ""
        switch action {
        case .redis:
            if let statements = sqlStatements {
                return "\(marked) The \(statements.count == 1 ? "command" : "\(statements.count) commands") below run \(markedConnection == nil ? "there " : "")in order, \(redisThrough), "
                    + (sqlTransaction == true ? "in one MULTI/EXEC transaction: Redis runs them all once queued, and has no rollback." : "one by one: Runlet stops at the first error, and the commands that ran stay.") + readOnly
            }
            return "\(marked) The command below runs \(markedConnection == nil ? "there, " : "")\(redisThrough). Runlet asks before every Redis run on production." + readOnly
        case .redisKeys:
            return "\(marked) The key browser reads \(redisThrough): SCAN with a pattern (never KEYS), and each key's type and TTL, or one key's value or memory. Nothing changes. Runlet asks before every read on production."
        default:
            return "\(marked) The server panel reads INFO and CLIENT LIST \(redisThrough). Nothing changes. Runlet asks before every read on production."
        }
    }

    private var redisThrough: String {
        sqlSaved
            ? "on \(sqlConnection ?? "the saved connection")" + (sqlFromThisMac ? "" : ", opened from \(targetName)")
            : "through the application's own Redis connection (\(sqlConnection ?? "the default connection"))"
    }
}

/// Load More (#190) under a Redis reply of a tab's current output: the next SCAN page (its
/// cursor), or the elements after a cut LRANGE/ZRANGE. Each page runs again on the same
/// connection; production asks first. A new run or Clear Output detaches it.
@MainActor
@Observable
final class RedisReplyPager {
    enum Phase: Equatable {
        case idle
        case loading
        case failed(String)
    }

    @ObservationIgnored weak var tab: TabModel?
    let itemId: Int
    let run: SQLRunInfo
    let target: TargetRef
    /// The command that produced the reply (the last page's, after Load More).
    private(set) var arguments: [[UInt8]]
    let line: Int
    var phase: Phase = .idle
    private(set) var pages = 1
    private(set) var isDetached = false
    @ObservationIgnored var stop: (() -> Void)?

    /// Nil when the reply has no next page.
    init?(tab: TabModel, itemId: Int, run: SQLRunInfo, target: TargetRef, reply: RedisReplyInfo) {
        // Run All's replies page too, by their own command; a MULTI/EXEC reply doesn't.
        let index = (reply.statement?.index ?? 1) - 1
        guard reply.transaction != true, run.redisCommands.indices.contains(index) else { return nil }
        let command = run.redisCommands[index]
        guard RedisPaging.next(arguments: command.arguments, view: reply.view, shown: reply.view.table.rows.count) != nil else { return nil }
        self.tab = tab
        self.itemId = itemId
        self.run = run
        self.target = target
        arguments = command.arguments
        line = command.line
    }

    var isLoading: Bool { phase == .loading }

    /// The next page's command, for the reply as it is now.
    func nextArguments(for reply: RedisReplyInfo) -> [[UInt8]]? {
        RedisPaging.next(arguments: arguments, view: reply.view, shown: reply.view.table.rows.count)
    }

    func loaded(_ next: [[UInt8]]) {
        arguments = next
        pages += 1
        phase = .idle
    }

    func detach() {
        stop?()
        stop = nil
        isDetached = true
        if isLoading { phase = .idle }
    }
}

/// Redis tabs (#190): creating them, choosing the connection, and running their commands. A
/// command runs only when the user presses Run: opening, importing, or restoring a Redis tab
/// never runs it, Redis tabs never auto-run, and MCP clients can't run them. Dangerous commands
/// always confirm, naming the command; production asks before every run.
extension AppModel {
    var redisConnectionCatalog: RedisConnectionCatalog { RedisConnectionCatalog.shared(for: self) }

    /// File ▸ New Redis Tab: an empty Redis tab on the current tab's target.
    @discardableResult
    func newRedisTab(in window: WindowModel? = nil) -> TabModel {
        let window = window ?? activeWindow
        let target = window?.selectedTab?.target
        var number = 1
        while window?.tabs.contains(where: { $0.title == "Redis \(number)" }) == true { number += 1 }
        return newTab(target: target, code: "", title: "Redis \(number)", in: window, language: .redis)
    }

    /// The application connection names a database tab's picker offers, by its family.
    func applicationConnectionNames(for tab: TabModel) -> [String] {
        switch tab.language {
        case .redis: redisConnectionNames(for: tab)
        // #191: MongoDB has no catalog of names; only the tab's own choice.
        case .mongodb: tab.sqlSavedConnection == nil && tab.sqlSavedConnectionName == nil ? tab.sqlConnection.map { [$0] } ?? [] : []
        default: sqlConnectionNames(for: tab)
        }
    }

    /// Redis connection names to offer: those the target's driver listed in this session, plus
    /// the tab's own choice.
    func redisConnectionNames(for tab: TabModel) -> [String] {
        var names = redisConnectionCatalog.names[tab.target.stableKey] ?? []
        if tab.sqlSavedConnection == nil, tab.sqlSavedConnectionName == nil, let chosen = tab.sqlConnection, !names.contains(chosen) { names.append(chosen) }
        return names
    }

    func learnRedisConnections(_ names: [String]?, for target: TargetRef) {
        guard let names, !names.isEmpty, redisConnectionCatalog.names[target.stableKey] != names else { return }
        redisConnectionCatalog.names[target.stableKey] = names
    }

    /// Run All in MULTI/EXEC, or not. Nothing runs.
    func setRedisTransaction(_ isOn: Bool, for tab: TabModel) {
        guard tab.redisTransaction != isOn else { return }
        tab.redisTransaction = isOn
        window(containing: tab.id)?.markEdited()
        scheduleSessionSave()
    }

    /// Run: the selected command, else the one on the caret's line (`RedisScript.commandToRun`).
    func runRedis(_ tab: TabModel, selectionOnly: Bool) {
        guard !tab.isRunning, tab.language == .redis else { return }
        let editor = tab.editor
        switch RedisScript.commandToRun(in: editor.text, selection: editor.selectedRange, selectionOnly: selectionOnly) {
        case .failure(let error):
            alert = AppAlert(title: error.title, message: error.description)
        case .success(let command):
            runRedisCommands(tab, [command], all: false, isSelection: editor.selectedRange.length > 0)
        }
    }

    /// Run All: every command of the selection, else of the tab, in order on one connection;
    /// in MULTI/EXEC when the tab says so.
    func runAllRedis(_ tab: TabModel) {
        guard !tab.isRunning, tab.language == .redis else { return }
        let editor = tab.editor
        switch RedisScript.commandsToRunAll(in: editor.text, selection: editor.selectedRange) {
        case .failure(let error):
            alert = AppAlert(title: error.title, message: error.description)
        case .success(let commands):
            runRedisCommands(tab, commands, all: true, isSelection: editor.selectedRange.length > 0)
        }
    }

    /// Why `commands` can't run on `choice`, before anything is sent; nil when they can.
    func redisRefusal(_ commands: [RedisScript.Command], choice: SQLConnectionChoice, transaction: Bool) -> AppAlert? {
        if case .missing(let name) = choice {
            return AppAlert(title: "The saved connection isn't defined", message: SQLConnectionChoice.missingMessage(name))
        }
        for command in commands {
            if let why = RedisCommands.refusal(command.strings) {
                return AppAlert(title: "Runlet doesn't send \(RedisCommands.classify(command.strings).name)", message: (commands.count > 1 ? "Line \(command.line): " : "") + why)
            }
        }
        // A read-only connection refuses the whole run when one command isn't a read.
        if let saved = choice.savedConnection, saved.readOnly {
            let refused = commands.compactMap { command in RedisCommands.readOnlyRefusal(command.strings).map { (command, $0) } }
            if let (command, why) = refused.first {
                let message = commands.count == 1
                    ? "Runlet refused this command on the read-only connection “\(saved.name)”: it \(why). Nothing ran."
                    : "Line \(command.line) \(why), so Runlet ran none of the \(commands.count) commands on the read-only connection “\(saved.name)”\(refused.count > 1 ? " (\(refused.count - 1) more line\(refused.count == 2 ? "" : "s") would be refused too)" : ""). Nothing ran."
                return AppAlert(title: "Read-only connection", message: message + " Turn Read-only off in the connection's settings to run writes.")
            }
        }
        if transaction, let control = commands.first(where: { RedisCommands.transaction.contains($0.name) }) {
            return AppAlert(title: "The commands manage their own transaction",
                            message: "Line \(control.line) has \(control.name). Run All wraps the commands in MULTI/EXEC, which \(control.name) would end or nest. Turn off In a Transaction in the Redis bar to run them as written, or remove \(control.name).")
        }
        return nil
    }

    /// Dangerous commands (#190) always confirm, naming each, on every connection: FLUSHALL,
    /// FLUSHDB, KEYS, DEBUG, SHUTDOWN, CONFIG SET, … The confirmation is a sheet over the tab;
    /// `perform` runs only after Run. Without dangerous commands, `perform` runs at once.
    func confirmDangerousRedis(_ commands: [RedisScript.Command], connection: String, tab: TabModel, perform: @escaping () -> Void) {
        let dangerous = commands.compactMap { command -> DatabaseDangerConfirmation.Item? in
            let info = RedisCommands.classify(command.strings)
            return info.dangerous ? DatabaseDangerConfirmation.Item(line: command.line, name: info.name, text: command.displayText, danger: info.danger ?? "is dangerous") : nil
        }
        guard !dangerous.isEmpty else {
            perform()
            return
        }
        let confirmation = DatabaseDangerConfirmation(family: .redis, tabId: tab.id, connection: connection, items: dangerous, perform: perform)
        #if DEBUG
        if let answer = RedisDebugAnswers.dangerousConfirmation {
            redisUI.lastDanger = confirmation.title
            if answer { perform() }
            return
        }
        #endif
        redisUI.danger = confirmation
    }

    func confirmRedisDanger() {
        guard let confirmation = redisUI.danger else { return }
        redisUI.danger = nil
        confirmation.perform()
    }

    func cancelRedisDanger() {
        redisUI.danger = nil
    }

    private func runRedisCommands(_ tab: TabModel, _ commands: [RedisScript.Command], all: Bool, isSelection: Bool) {
        let choice = sqlConnectionChoice(for: tab)
        let transaction = all && tab.redisTransaction
        if let refusal = redisRefusal(commands, choice: choice, transaction: transaction) {
            alert = refusal
            return
        }
        let target = tab.target
        var info = SQLRunInfo(redis: commands, connection: choice.ref?.appName, saved: choice.savedConnection, transaction: all ? transaction : nil)
        info.tunnelProfile = library.tunnelProfile(of: choice.savedConnection)?.name
        let window = window(containing: tab.id)
        let checks = commands.enumerated().map { index, command in
            SQLStatementCheck(index: index + 1, line: command.line, text: command.displayText, warning: Self.redisWarning(command))
        }
        let warning: String? = all
            ? (checks.contains { $0.warning != nil } ? "Some of these commands can change data." : nil)
            : checks.first?.warning
        let maxElements = settings.sqlRowsPerPage
        let code = RedisTabRun.code(commands: commands, connection: info.connection, maxElements: maxElements, all: all, transaction: transaction)
        confirmDangerousRedis(commands, connection: info.connectionLabel, tab: tab) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target, tab.language == .redis, !tab.isRunning else { return }
            self.guardProduction(.redis, target: target, text: info.historyCode, isSelection: isSelection,
                                 sqlWarning: warning, sqlConnection: info.connectionLabel, sqlSaved: info.saved != nil, savedConnection: info.saved,
                                 sqlStatements: all ? checks : nil, sqlTransaction: all ? transaction : nil, in: window) { [weak self, weak tab] in
                guard let self, let tab, tab.target == target, tab.language == .redis, !tab.isRunning else { return }
                self.startRun(tab, code: code, selection: nil, sql: info)
            }
        }
    }

    /// The production confirmation's warning for a command that may write.
    static func redisWarning(_ command: RedisScript.Command) -> String? {
        let info = RedisCommands.classify(command.strings)
        switch info.access {
        case .read, .connection, .transaction: return info.dangerous ? "\(info.name) \(info.danger ?? "is dangerous")." : nil
        case .write: return "This command can change data or the server (\(info.name))."
        case .streaming, .unknown: return "Runlet can't tell whether this command changes data (\(info.name))."
        }
    }

    // MARK: Load More

    /// Load More under a Redis reply: runs the next page's command on the same connection and
    /// adds its rows to the reply. Production asks first.
    func loadMoreRedis(_ tab: TabModel, item id: Int) {
        guard let pager = tab.redisPagers[id], !pager.isDetached, !pager.isLoading, !tab.isRunning,
              let reply = tab.redisReply(id), let next = pager.nextArguments(for: reply) else { return }
        let run = pager.run
        let target = pager.target
        let nextText = next.map(RedisScript.quoted).joined(separator: " ")
        guardProduction(.redis, target: target, text: nextText, sqlWarning: nil, sqlConnection: run.connectionLabel, sqlSaved: run.saved != nil, savedConnection: run.saved,
                        in: window(containing: tab.id)) { [weak self, weak tab, weak pager] in
            guard let self, let tab, let pager, !pager.isDetached else { return }
            pager.phase = .loading
            let task = Task { [weak self, weak tab, weak pager] in
                guard let self else { return }
                do {
                    let snapshot = try await self.sqlSnapshot(for: tab ?? TabModel(state: TabState(title: "", target: target)), saved: run.saved)
                    defer { self.releaseSQLTunnel(snapshot) }
                    let code = RedisTabRun.pageCode(arguments: next, line: pager?.line ?? 1, connection: run.connection, maxElements: reply.maxElements ?? self.settings.sqlRowsPerPage)
                    let page = try await self.engine.runRedisPanel(target: snapshot, code: code, event: "redis", as: RedisReplyInfo.self, saved: run.saved)
                    guard let tab, let pager, !pager.isDetached, let current = tab.redisReply(id) else { return }
                    guard let merged = current.appending(page) else {
                        pager.phase = .failed("The next page has another shape, so Runlet didn't add it.")
                        return
                    }
                    tab.replaceRedisReply(id, with: merged)
                    pager.loaded(next)
                } catch is CancellationError {
                    pager?.phase = .idle
                } catch {
                    pager?.phase = .failed("\(error)")
                }
                pager?.stop = nil
            }
            pager.stop = { task.cancel() }
        }
    }

    func stopRedisPage(_ tab: TabModel, item id: Int) {
        tab.redisPagers[id]?.stop?()
    }
}

/// Redis tabs' sheets and panes (#190): the dangerous-command confirmation, and the Database
/// pane's key browser and server panel state.
@MainActor
@Observable
final class RedisUI {
    /// The shared database danger confirmation (`DatabaseDangerConfirmation`, `DatabaseDangerSheet`).
    var danger: DatabaseDangerConfirmation?
    /// The last confirmation a Debug step answered (printed by `redis-state`).
    @ObservationIgnored var lastDanger: String?
    /// The key browser and server panel per target and connection (`AppModel.redisPaneKey`).
    var browsers: [String: RedisKeyBrowserState] = [:]
    var servers: [String: RedisServerState] = [:]
    /// Open Value's sheet.
    var value: RedisValueSheet?
    /// Kill Client's confirmation.
    var kill: RedisKillConfirmation?

    private static var states: [ObjectIdentifier: RedisUI] = [:]

    static func shared(for model: AppModel) -> RedisUI {
        let key = ObjectIdentifier(model)
        if let existing = states[key] { return existing }
        let created = RedisUI()
        states[key] = created
        return created
    }
}

extension AppModel {
    var redisUI: RedisUI { RedisUI.shared(for: self) }
}

#if DEBUG
/// Debug steps answer the dangerous-command confirmation (screenshots, live checks).
@MainActor
enum RedisDebugAnswers {
    /// true: run; false: cancel; nil: ask.
    static var dangerousConfirmation: Bool?
}
#endif
