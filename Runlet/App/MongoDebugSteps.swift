#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for MongoDB tabs (#191), for screenshots and scripted checks with scratch
/// data only: `mongo-tab` (switches the current tab to MongoDB) · `mongo-explorer` (shows the
/// Database pane and loads the collections) · `mongo-confirm:yes|no` (answers the open
/// destructive-operation confirmation: yes runs, no cancels) · `mongo-next-page` (Next Page
/// under the result) · `mongo-menu:<collection>|off` (a collection row's context menu items
/// in a popover, since a menu can't be snapshotted) · `mongo-state` (prints the confirmation
/// and the page).
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
        case "mongo-next-page":
            model.loadMoreMongo(tab)
        case "mongo-menu":
            MongoUI.shared.debugMenuCollection = argument == "off" || argument.isEmpty ? nil : argument
        case "mongo-state":
            let page = MongoUI.shared.pages[tab.id]
            RedisDebugSteps.log("mongo connection=\(model.sqlConnectionChoice(for: tab).label) | danger=\(MongoUI.shared.danger?.title ?? "-") | page=\(page.map { "\($0.offset)+\($0.rows) more=\($0.more)" } ?? "-") | canLoadMore=\(model.canLoadMoreMongo(tab)) | alert=\(model.alert.map { "\($0.title): \($0.message)" } ?? "-")")
        default: return false
        }
        return true
    }
}
#endif
