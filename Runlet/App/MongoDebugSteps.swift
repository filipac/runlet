#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for MongoDB tabs (#191), for screenshots and scripted checks with scratch
/// data only: `mongo-tab` (switches the current tab to MongoDB) · `mongo-explorer` (shows the
/// Database pane and loads the collections) · `mongo-confirm:yes|no` (answers the open
/// destructive-operation confirmation: yes runs, no cancels) · `mongo-sample:<collection>`
/// (Sample Fields of a listed collection) · `mongo-next-page` (Load More
/// under the result, #207) · `mongo-menu:<collection>|off` (a collection row's context menu items
/// in a popover, since a menu can't be snapshotted) · `mongo-state` (prints the confirmation
/// and the page) · `mongo-section:collections|server` and `mongo-server` (the Database pane's
/// Server section, #207, and Read Server Details) · `mongo-kill:runlet|<opid>` (Kill Op on the
/// first operation a Runlet run tagged, or on that opid: the danger sheet asks) ·
/// `mongo-kill-confirm:yes|no` · `mongo-server-state` (prints the panel).
@MainActor
enum MongoDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard let tab = model.selectedTab else { return false }
        switch name {
        case "mongo-tab": model.setLanguage(.mongodb, for: tab)
        case "mongo-explorer":
            model.inspectorPane = .database
            model.mongoMetadata("listCollections", tab: tab)
        case "mongo-confirm":
            if argument == "yes" { model.confirmMongoDanger() } else { model.cancelMongoDanger() }
        case "mongo-sample":
            model.sampleMongoFields(argument, tab: tab)
        case "mongo-next-page":
            model.loadMoreMongo(tab)
        case "mongo-menu":
            MongoUI.shared.debugMenuCollection = argument == "off" || argument.isEmpty ? nil : argument
        case "mongo-section":
            model.inspectorPane = .database
            model.databaseServer.section = argument == "server" ? .server : .tables
        case "mongo-server":
            model.inspectorPane = .database
            model.databaseServer.section = .server
            model.loadMongoServer(tab)
        case "mongo-kill":
            guard let key = model.mongoServerKey(for: tab), let report = MongoUI.shared.servers[key]?.report,
                  let operation = report.operations?.first(where: { argument == "runlet" ? $0.isRunlet && $0.own != true : $0.opid == argument }) else {
                RedisDebugSteps.log("mongo-kill: no such operation")
                return true
            }
            model.askKillMongoOperation(tab, operation: operation)
        case "mongo-kill-confirm":
            if argument == "yes" { model.confirmMongoKill() } else { model.cancelMongoKill() }
        case "mongo-server-state":
            let state = model.mongoServerKey(for: tab).flatMap { MongoUI.shared.servers[$0] }
            RedisDebugSteps.log("mongo server summary=\(state?.report?.summary ?? "-") | operations=\(state?.report?.operations?.map { "\($0.opid):\($0.op ?? "?") \($0.ns ?? "-")\($0.own == true ? " (own)" : "")" }.joined(separator: ", ") ?? "-") | error=\(state?.error ?? "-") | kill=\(MongoUI.shared.kill?.title ?? "-") | last=\(state?.lastKill.map { "\($0.outcome.rawValue): \($0.detail)" } ?? "-")")
        case "mongo-state":
            let page = MongoUI.shared.pages[tab.id]
            RedisDebugSteps.log("mongo connection=\(model.sqlConnectionChoice(for: tab).label) | danger=\(MongoUI.shared.danger?.title ?? "-") | page=\(page.map { "\($0.loaded) in \($0.pages) more=\($0.more) phase=\($0.phase)" } ?? "-") | canLoadMore=\(model.canLoadMoreMongo(tab)) | alert=\(model.alert.map { "\($0.title): \($0.message)" } ?? "-")")
        default: return false
        }
        return true
    }
}
#endif
