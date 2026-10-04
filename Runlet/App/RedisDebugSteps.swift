#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for Redis tabs (#190), for screenshots and scripted checks with scratch
/// data and fixture passwords only (see `DebugSteps`; save a Redis connection with `db-new:<name>|redis|<host>|<port>|<db>|<user>|<password>|mac`
/// and pick it with `db-use:<name>`):
/// `redis-run-all` (Run All in the current Redis tab, waitable with `wait-run`) ·
/// `redis-transaction:on|off` (In a Transaction) · `redis-danger:yes|no|ask` (answers the
/// dangerous-command confirmation: yes runs, no cancels, ask shows the sheet) ·
/// `redis-danger:confirm|cancel` (presses the sheet's buttons) ·
/// `redis-section:keys|server` (the Database pane's section) · `redis-db:<n>`,
/// `redis-pattern:<pattern>`, `redis-type:<type>|any` (the key browser's fields) ·
/// `redis-scan` and `redis-scan-more` (Scan, Load More) · `redis-memory:<key>` (Memory Usage
/// of a listed key) · `redis-value:<key>` (Open Value; `redis-value:off` closes it) ·
/// `redis-server` (Read Server Details) · `redis-kill:<client id>|blocked` (asks to kill that
/// client, or the first blocked one; `redis-kill:confirm|cancel` answers) ·
/// `redis-load-more` (Load More under the output's last Redis reply that pages) ·
/// `redis-wait[:<seconds>]` (in `RunletApp`: holds the steps until the key browser, the
/// server panel, Open Value, and Load More are idle) · `redis-state` (prints them) · the
/// command builder's `redis-builder…` and `redis-key-menu` steps (#218, `RedisBuilderDebugSteps`) ·
/// completion's `redis-complete…`, `redis-hover`, and `redis-load-keys` steps (#206,
/// `RedisCompletionDebugSteps`).
@MainActor
enum RedisDebugSteps {
    static var waited: Double = 0

    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name.hasPrefix("redis-") else { return false }
        if RedisBuilderDebugSteps.run(name, argument, model: model) { return true } // #218
        if RedisCompletionDebugSteps.run(name, argument, model: model) { return true } // #206
        guard let tab = model.selectedTab else { return true }
        let key = model.redisPaneKey(for: tab)
        switch name {
        case "redis-run-all":
            DebugRunTiming.start(tab)
            model.runAllRedis(tab)
        case "redis-transaction":
            model.setRedisTransaction(argument != "off", for: tab)
        case "redis-danger":
            switch argument {
            case "yes": RedisDebugAnswers.dangerousConfirmation = true
            case "no": RedisDebugAnswers.dangerousConfirmation = false
            case "confirm": model.confirmRedisDanger()
            case "cancel": model.cancelRedisDanger()
            default: RedisDebugAnswers.dangerousConfirmation = nil
            }
        case "redis-section":
            model.databaseServer.section = argument == "server" ? .server : .tables
        case "redis-db":
            if let key, let db = Int(argument) { model.redisUI.browser(key).select(db: db) }
        case "redis-pattern":
            if let key { model.redisUI.browser(key).pattern = argument }
        case "redis-type":
            if let key { model.redisUI.browser(key).type = argument == "any" || argument.isEmpty ? nil : argument }
        case "redis-scan":
            model.databaseServer.section = .tables
            model.scanRedisKeys(tab)
        case "redis-scan-more":
            model.scanRedisKeys(tab, more: true)
        case "redis-memory":
            if let key, let entry = model.redisUI.browser(key).keys.first(where: { $0.displayName == argument }) {
                model.loadRedisKeyDetails(tab, key: entry)
            } else {
                log("redis-memory: no listed key \(argument)")
            }
        case "redis-value":
            if argument == "off" {
                model.redisUI.value = nil
            } else if let key, let entry = model.redisUI.browser(key).keys.first(where: { $0.displayName == argument }) {
                model.openRedisValue(tab, key: entry)
            } else {
                log("redis-value: no listed key \(argument)")
            }
        case "redis-server":
            model.databaseServer.section = .server
            model.loadRedisServer(tab)
        case "redis-kill":
            switch argument {
            case "confirm": model.confirmKillRedisClient()
            case "cancel": model.cancelKillRedisClient()
            default:
                guard let key, let report = model.redisUI.servers[key]?.report else {
                    log("redis-kill: read the server first")
                    return true
                }
                let client = argument == "blocked" ? report.clientList.first(where: \.isBlocked) : report.clientList.first { String($0.id) == argument }
                if let client { model.askKillRedisClient(tab, client: client) } else { log("redis-kill: no client \(argument)") }
            }
        case "redis-load-more":
            if let id = tab.redisPagers.keys.max() { model.loadMoreRedis(tab, item: id) }
        case "redis-state":
            log("redis-state: \(state(model))")
        default:
            log("unknown step \(name)")
        }
        return true
    }

    /// Whether a key browser read, a server read, Open Value, or Load More is under way.
    static func isBusy(_ model: AppModel) -> Bool {
        model.redisUI.browsers.values.contains { $0.loading || !$0.detailLoading.isEmpty }
            || model.redisUI.servers.values.contains { $0.loading || $0.killing != nil }
            || (model.redisUI.value.map { $0.reply == nil && $0.error == nil } ?? false)
            || (model.selectedTab?.redisPagers.values.contains { $0.isLoading } ?? false)
            || RedisCompletionDebugSteps.isBusy(model)
    }

    static func state(_ model: AppModel) -> String {
        guard let tab = model.selectedTab else { return "no tab" }
        var parts = ["language=\(tab.language.rawValue)", "connection=\(model.sqlConnectionChoice(for: tab).label)"]
        if let key = model.redisPaneKey(for: tab) {
            let browser = model.redisUI.browser(key)
            parts.append("keys=\(browser.keys.count) next=\(browser.next ?? "-") error=\(browser.error ?? "-") details=\(browser.details.count)")
            let server = model.redisUI.server(key)
            parts.append("server=\(server.report?.summary ?? "-") clients=\(server.report?.clientList.count ?? 0) kill=\(server.lastKill.map { "\($0.outcome.rawValue): \($0.detail)" } ?? "-") serverError=\(server.error ?? "-")")
        }
        let replies = tab.output.compactMap { if case .redis(_, let reply) = $0 { reply } else { nil } }
        parts.append("replies=\(replies.map { "\($0.name):\($0.view.kind.rawValue):\($0.summary)" })")
        parts.append("danger=\(model.redisUI.danger?.title ?? model.redisUI.lastDanger ?? "-")")
        parts.append("alert=\(model.alert.map { "\($0.title): \($0.message)" } ?? "-")")
        return parts.joined(separator: " | ")
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
