import AppKit
import Observation
import RunletCore

@MainActor @Observable
final class MongoUI {
    struct Page {
        var query: String
        var editorText: String
        var connectionKey: String
        var nextOffset: Int
    }
    struct Confirmation: Identifiable {
        let id = UUID()
        var operation: String
        var collection: String
        var perform: () -> Void
    }
    var confirmation: Confirmation?
    var collections: [String: SQLResultInfo] = [:]
    var fields: [String: [String: SQLResultInfo]] = [:]
    var pages: [UUID: Page] = [:]
    static let shared = MongoUI()
}

extension AppModel {
    func runMongo(_ tab: TabModel, selectionOnly: Bool = false, offset: Int = 0, queryText: String? = nil) {
        guard tab.language == .mongodb, !tab.isRunning else { return }
        let text = queryText ?? (tab.editor.selectedRange.length > 0 ? tab.editor.selectedText ?? "" : tab.editor.text)
        if selectionOnly && tab.editor.selectedRange.length == 0 {
            alert = AppAlert(title: "Nothing selected", message: "Select one complete MongoDB JSON query.")
            return
        }
        let query: MongoQuery
        do { query = try MongoQuery(text) } catch {
            alert = AppAlert(title: "Invalid MongoDB query", message: error.localizedDescription)
            return
        }
        let choice = sqlConnectionChoice(for: tab)
        if case .missing(let name) = choice {
            alert = AppAlert(title: "Missing MongoDB connection", message: SQLConnectionChoice.missingMessage(name))
            return
        }
        let saved = choice.savedConnection
        if saved?.readOnly == true && query.effect != .read {
            alert = AppAlert(title: "Read-only MongoDB connection", message: "Refused \(query.operation) on \(query.collection). Nothing ran.")
            return
        }
        let target = tab.target
        let connectionRef = choice.ref
        let run = { [weak self, weak tab] in
            guard let self, let tab, tab.target == target, tab.language == .mongodb,
                  self.sqlConnectionChoice(for: tab).ref == connectionRef else { return }
            let statement = SQLScript.Statement(text: query.json, range: NSRange(location: 0, length: (query.json as NSString).length), startLine: 1)
            var info = SQLRunInfo(statement: statement, connection: connectionRef?.appName, saved: saved)
            info.language = .mongodb
            info.tunnelProfile = self.library.tunnelProfile(of: saved)?.name
            self.guardProduction(.mongodb, target: target, text: query.json, isSelection: false,
                                 sqlWarning: query.effect == .read ? nil : "MongoDB \(query.operation) can change data.",
                                 sqlConnection: info.connectionLabel, sqlSaved: saved != nil, savedConnection: saved,
                                 in: self.window(containing: tab.id)) { [weak self, weak tab] in
                guard let self, let tab, tab.target == target, tab.language == .mongodb,
                      self.sqlConnectionChoice(for: tab).ref == connectionRef else { return }
                let key = self.mongoCacheKey(tab)
                let editorText = tab.editor.text
                let pageSize = self.settings.sqlRowsPerPage
                MongoUI.shared.pages[tab.id] = nil
                let observer = RunObserver(event: { event in
                    if query.operation == "listCollections", case .sql(let result) = event { MongoUI.shared.collections[key] = result }
                    if query.operation == "sampleSchema", case .sql(let result) = event { MongoUI.shared.fields[key, default: [:]][query.collection] = result }
                    if ["find", "aggregate", "distinct"].contains(query.operation), query.effect == .read,
                       case .sql(let result) = event, result.rows.count == pageSize {
                        MongoUI.shared.pages[tab.id] = .init(query: query.json, editorText: editorText, connectionKey: key, nextOffset: offset + result.rows.count)
                    }
                })
                self.startRun(tab, code: query.runnerCode(connection: connectionRef?.appName, pageSize: self.settings.sqlRowsPerPage, offset: offset, confirmed: true), selection: nil, observer: observer, sql: info)
            }
        }
        if query.effect == .destructive {
            MongoUI.shared.confirmation = .init(operation: query.operation, collection: query.collection, perform: run)
        } else {
            run()
        }
    }

    func mongoCacheKey(_ tab: TabModel) -> String {
        let choice = sqlConnectionChoice(for: tab)
        return tab.target.stableKey + ":" + (choice.ref?.key ?? "missing") + ":" + String(choice.savedConnection?.revision ?? 0)
    }

    func canLoadMoreMongo(_ tab: TabModel) -> Bool {
        guard let page = MongoUI.shared.pages[tab.id] else { return false }
        return page.editorText == tab.editor.text && page.connectionKey == mongoCacheKey(tab) && !tab.isRunning
    }

    func loadMoreMongo(_ tab: TabModel) {
        guard canLoadMoreMongo(tab), let page = MongoUI.shared.pages[tab.id] else { return }
        runMongo(tab, offset: page.nextOffset, queryText: page.query)
    }

    func mongoMetadata(_ operation: String, collection: String = "metadata", tab: TabModel) {
        let data = try! JSONSerialization.data(withJSONObject: ["operation": operation, "collection": collection])
        runMongo(tab, queryText: String(decoding: data, as: UTF8.self))
    }
}
