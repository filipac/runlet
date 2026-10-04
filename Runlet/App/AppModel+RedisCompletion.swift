import AppKit
import RunletCore
import RunletLanguage

/// The keys Load Keys for Completion read (#206) for one Redis connection and database, in
/// memory while Runlet runs. Completion offers them with the key browser's last scan and the
/// keys this tab's replies named; nothing is read by itself.
@MainActor
final class RedisCompletionKeys {
    /// At most this many names are kept per connection.
    static let limit = 20_000

    let db: Int
    private(set) var names: [String] = []
    private var seen = Set<String>()
    /// Prefixes whose loads reached the end of the database: every key with them is known.
    var complete: Set<String> = []
    /// Where the last load stopped, so the next one for the same prefix continues: its prefix
    /// and the SCAN cursor ("0": the scan is complete).
    var lastPrefix: String?
    var next: String?
    var loading = false

    init(db: Int) {
        self.db = db
    }

    func add(_ new: [String]) {
        for name in new where names.count < Self.limit && seen.insert(name).inserted { names.append(name) }
    }
}

/// Each Redis connection's completion keys (#206), by `AppModel.redisPaneKey`.
@MainActor
final class RedisCompletionStore {
    private var states: [String: RedisCompletionKeys] = [:]
    private static var stores: [ObjectIdentifier: RedisCompletionStore] = [:]

    static func shared(for model: AppModel) -> RedisCompletionStore {
        let key = ObjectIdentifier(model)
        if let existing = stores[key] { return existing }
        let created = RedisCompletionStore()
        stores[key] = created
        return created
    }

    /// The connection's keys for database `db` (another database starts over).
    func keys(_ paneKey: String, db: Int) -> RedisCompletionKeys {
        if let state = states[paneKey], state.db == db { return state }
        let state = RedisCompletionKeys(db: db)
        states[paneKey] = state
        return state
    }

    func existing(_ paneKey: String, db: Int) -> RedisCompletionKeys? {
        states[paneKey].flatMap { $0.db == db ? $0 : nil }
    }
}

/// Completion in Redis tabs (#206): commands, subcommands, options, and values from
/// `RedisCompletion`; key names only from what Runlet already read (the key browser's last scan
/// of this connection and database, Load Keys for Completion, and this tab's replies). Typing
/// never sends anything; Load Keys for Completion runs one SCAN when chosen, and production
/// asks first.
extension AppModel {
    var redisCompletionStore: RedisCompletionStore { RedisCompletionStore.shared(for: self) }

    /// Load Keys for Completion and hover for a Redis tab's editor.
    func installRedisCompletion(_ tab: TabModel) {
        tab.completionActionHandler = { [weak self, weak tab] action in
            guard let self, let tab, tab.language == .redis, action == RedisCompletion.loadKeysAction else { return }
            self.loadRedisCompletionKeys(tab)
        }
        tab.hoverProvider = { [weak tab] text, index in
            guard let tab, tab.language == .redis else { return nil }
            return RedisCompletion.hover(in: text, at: index)
        }
    }

    /// The completions at `caret` in a Redis tab (the keys are gathered only in a key position).
    func redisCompletion(_ tab: TabModel, text: String, caret: Int) -> SQLCompletion.Result? {
        RedisCompletion.suggestions(in: text, caret: caret, keys: redisKnownKeys(for: tab),
                                    loadOffer: redisKeyLoadOffer(for: tab, prefix: RedisCompletion.context(in: text, caret: caret)?.prefix ?? ""))
    }

    /// The database a Redis tab's command runs in, as far as Runlet knows: a saved connection's
    /// database number; for an application connection, the database of the tab's last reply.
    func redisCompletionDatabase(for tab: TabModel) -> Int {
        if let saved = sqlConnectionChoice(for: tab).savedConnection {
            return Int(saved.database.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        for item in tab.output.reversed() {
            if case .redis(_, let reply) = item, let db = reply.db { return db }
        }
        return 0
    }

    /// The keys completion offers: the key browser's last scan when it read this database,
    /// Load Keys for Completion's, and the keys this tab's replies on this connection named.
    func redisKnownKeys(for tab: TabModel) -> [RedisCompletion.KnownKey] {
        guard let paneKey = redisPaneKey(for: tab) else { return [] }
        let db = redisCompletionDatabase(for: tab)
        let browser = redisUI.browsers[paneKey].flatMap { $0.scanned == nil ? nil : (db: $0.db, keys: $0.keys) }
        let loaded = redisCompletionStore.existing(paneKey, db: db)?.names ?? []
        let saved = sqlConnectionChoice(for: tab).savedConnection
        let replies = tab.output.compactMap { item -> RedisReplyInfo? in
            guard case .redis(_, let reply) = item else { return nil }
            // A reply of another connection (the tab's connection changed since).
            if let saved { return reply.saved == true && reply.connection == saved.name ? reply : nil }
            return reply.saved == true ? nil : reply
        }
        return RedisCompletion.knownKeys(db: db, browser: browser, loaded: loaded, replies: replies)
    }

    /// The Load Keys for Completion item; nil without a connection, or when every key that
    /// starts with `prefix` is known: an earlier load, or the key browser's complete scan of a
    /// pattern that covers it (`*`, `user:*`).
    func redisKeyLoadOffer(for tab: TabModel, prefix: String) -> RedisCompletion.KeyLoadOffer? {
        guard let paneKey = redisPaneKey(for: tab) else { return nil }
        let db = redisCompletionDatabase(for: tab)
        if let browser = redisUI.browsers[paneKey], browser.db == db, browser.next == "0", browser.type == nil,
           let covered = RedisCompletion.literalPrefix(of: browser.pattern.isEmpty ? "*" : browser.pattern), prefix.hasPrefix(covered) { return nil }
        let state = redisCompletionStore.existing(paneKey, db: db)
        if let state, state.complete.contains(where: { prefix.hasPrefix($0) }) { return nil }
        let more = state.map { $0.lastPrefix == prefix && $0.next != nil && $0.next != "0" } ?? false
        let cursor = more ? (state?.next ?? "0") : "0"
        return RedisCompletion.KeyLoadOffer(
            title: more ? "Load More Keys for Completion…" : "Load Keys for Completion…",
            detail: "SCAN \(cursor) MATCH \(RedisScript.quoted(RedisCompletion.loadPattern(prefix: prefix))) COUNT \(RedisCompletion.loadCount) in db \(db)"
        )
    }

    /// Load Keys for Completion: one SCAN (`MATCH` the typed prefix, `COUNT` 1,000) of the tab's
    /// connection and database, key names only; again for the same prefix, the next SCAN from
    /// where the last stopped. Production asks first. The list shows again where the caret is.
    func loadRedisCompletionKeys(_ tab: TabModel) {
        guard tab.language == .redis, let paneKey = redisPaneKey(for: tab) else { return }
        let editor = tab.editor
        let caret = editor.selectedRange.location
        let prefix = RedisCompletion.context(in: editor.text, caret: caret)?.prefix ?? ""
        let db = redisCompletionDatabase(for: tab)
        let state = redisCompletionStore.keys(paneKey, db: db)
        guard !state.loading else { return }
        let pattern = RedisCompletion.loadPattern(prefix: prefix)
        let cursor = state.lastPrefix == prefix ? (state.next.flatMap { $0 == "0" ? nil : $0 } ?? "0") : "0"
        let choice = sqlConnectionChoice(for: tab)
        let saved = choice.savedConnection
        let target = tab.target
        let what = "SCAN \(cursor) MATCH \(RedisScript.quoted(pattern)) COUNT \(RedisCompletion.loadCount) in database \(db), for completion (key names only)"
        guardProduction(.redisKeys, target: target, text: what, sqlConnection: redisConnectionText(choice), sqlSaved: saved != nil, savedConnection: saved, in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab else { return }
            state.loading = true
            let task = Task {
                do {
                    let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                    defer { self.releaseSQLTunnel(snapshot) }
                    let page = try await self.engine.loadRedisKeys(target: snapshot, db: db, pattern: pattern, cursor: cursor, count: RedisCompletion.loadCount,
                                                                   type: nil, connection: choice.ref?.appName, saved: saved, details: false)
                    let names = page.keys.compactMap(\.key)
                    state.add(names)
                    state.lastPrefix = prefix
                    state.next = page.next
                    if page.isComplete { state.complete.insert(prefix) }
                    self.learnRedisConnections(page.connections, for: target)
                    let rest = page.isComplete ? "the scan is complete" : "more keys may match: choose Load More Keys for Completion to go on"
                    tab.appendRunLog("server", "Completion: loaded \(names.count) key name\(names.count == 1 ? "" : "s") matching \(pattern) in db \(db); \(rest)", detail: what)
                    // The list again, with the keys, while the caret is where it was.
                    if tab.editorIfLoaded?.selectedRange.location == caret { editor.codeTextViewRequestedCompletion(editor.textView) }
                } catch is CancellationError {
                    tab.appendRunLog("server", "Completion: stopped loading keys", detail: what)
                } catch {
                    tab.appendRunLog("server", "Completion: couldn't load keys: \(error)", detail: what)
                    self.alert = AppAlert(title: "Couldn't load keys for completion", message: "\(error)")
                }
                state.loading = false
            }
            self.trackDatabaseWork(DatabaseWork(purpose: .other(title: "Load keys for completion: \(pattern) in db \(db)", feature: "Redis completion"), tabId: tab.id, tabTitle: tab.title, target: target, connection: choice) { task.cancel() }, until: task)
        }
    }
}

#if DEBUG
/// RUNLET_DEBUG_STEPS for Redis completion (#206), for screenshots and scripted checks:
/// `redis-complete` (Show Completions at the caret) · `redis-type:<text>` (short text typed
/// character by character through the text view, `\s` a space and `\n` a line break, so quote pairing and the
/// list's triggers run) · `redis-complete-select:<label>` (selects that row) ·
/// `redis-complete-accept[:<label>]` (accepts the selected item, or the one with that label) · `redis-hover:<line>:<column>`
/// (hover there, as resting the mouse does) · `redis-load-keys` (Load Keys for Completion at the
/// caret) · `redis-complete-state` (prints the list, the hover, the known keys, and the loads).
/// Steps run from `RedisDebugSteps`.
@MainActor
enum RedisCompletionDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name.hasPrefix("redis-complete") || ["redis-hover", "redis-load-keys", "redis-type"].contains(name) else { return false }
        guard let tab = model.selectedTab else { return true }
        let editor = tab.editor
        switch name {
        case "redis-complete":
            editor.codeTextViewRequestedCompletion(editor.textView)
        case "redis-complete-select":
            if let index = editor.debugCompletionLabels.firstIndex(of: argument) { editor.debugSelectCompletion(index) }
        case "redis-type":
            // Typed as the keyboard types (each character through insertText, so the editor's
            // quote pairing and completion triggers run), without key events.
            editor.focus()
            for character in argument.replacingOccurrences(of: "\\s", with: " ").replacingOccurrences(of: "\\n", with: "\n") {
                editor.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        case "redis-complete-accept":
            if !argument.isEmpty, let index = editor.debugCompletionLabels.firstIndex(of: argument) {
                editor.debugSelectCompletion(index)
            }
            editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        case "redis-hover":
            let parts = argument.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return true }
            let index = TextLineIndex(editor.text).offset(of: LSPPosition(line: parts[0] - 1, character: parts[1] - 1))
            editor.debugHover(at: index)
        case "redis-load-keys":
            model.loadRedisCompletionKeys(tab)
        default:
            let keys = model.redisKnownKeys(for: tab)
            let paneKey = model.redisPaneKey(for: tab)
            let db = model.redisCompletionDatabase(for: tab)
            let loads = paneKey.flatMap { model.redisCompletionStore.existing($0, db: db) }
            RedisDebugSteps.log("redis-complete: list=\(editor.debugCompletionLabels.prefix(40)) hover=\(editor.debugHoverText?.replacingOccurrences(of: "\n", with: "⏎") ?? "-") db=\(db) keys=\(keys.count) loaded=\(loads?.names.count ?? 0) next=\(loads?.next ?? "-") loading=\(loads?.loading ?? false) production=\(model.productionGuard.pending.map { $0.preview } ?? "-") text=\(editor.text.replacingOccurrences(of: "\n", with: "\\n")) caret=\(editor.selectedRange.location)")
        }
        return true
    }

    static func isBusy(_ model: AppModel) -> Bool {
        guard let tab = model.selectedTab, let paneKey = model.redisPaneKey(for: tab) else { return false }
        return model.redisCompletionStore.existing(paneKey, db: model.redisCompletionDatabase(for: tab))?.loading ?? false
    }
}
#endif
