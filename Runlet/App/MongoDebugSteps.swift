#if DEBUG
import RunletCore

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
            let confirmation = MongoUI.shared.confirmation
            MongoUI.shared.confirmation = nil
            if argument == "yes" { confirmation?.perform() }
        default: return false
        }
        return true
    }
}
#endif
