import AppKit
import Observation
import RunletCore

@MainActor @Observable
final class MongoUI {
    /// The page a paged read (find, aggregate, distinct) shows: Next Page under its result
    /// runs the captured query again from `offset + rows`, replacing the output.
    struct Page {
        var query: String
        var editorText: String
        var connectionKey: String
        /// Documents skipped before this page.
        var offset: Int
        /// Documents on this page.
        var rows: Int
        /// The page was full, so more documents may follow.
        var more: Bool
        var nextOffset: Int { offset + rows }
    }
    /// The destructive-operation confirmation (#191): the shared database danger sheet.
    var danger: DatabaseDangerConfirmation?
    /// The Database pane's collections per `AppModel.mongoCacheKey`, and when they were read.
    var collections: [String: SQLResultInfo] = [:]
    var collectionsRead: [String: Date] = [:]
    var fields: [String: [String: SQLResultInfo]] = [:]
    var pages: [UUID: Page] = [:]
    #if DEBUG
    /// DEBUG step `mongo-menu:<collection>`: that row's context menu items in a popover.
    var debugMenuCollection: String?
    #endif
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
        let statement = SQLScript.Statement(text: query.json, range: NSRange(location: 0, length: (query.json as NSString).length), startLine: 1)
        var runInfo = SQLRunInfo(statement: statement, connection: connectionRef?.appName, saved: saved)
        runInfo.language = .mongodb
        runInfo.tunnelProfile = library.tunnelProfile(of: saved)?.name
        let info = runInfo
        let run = { [weak self, weak tab] in
            guard let self, let tab, tab.target == target, tab.language == .mongodb,
                  self.sqlConnectionChoice(for: tab).ref == connectionRef else { return }
            self.guardProduction(.mongodb, target: target, text: query.json, isSelection: false,
                                 sqlWarning: query.effect == .read ? nil : "MongoDB \(query.operation) can change data.",
                                 sqlConnection: info.connectionLabel, sqlSaved: saved != nil, savedConnection: saved,
                                 in: self.window(containing: tab.id)) { [weak self, weak tab] in
                guard let self, let tab, tab.target == target, tab.language == .mongodb,
                      self.sqlConnectionChoice(for: tab).ref == connectionRef else { return }
                let key = self.mongoCacheKey(tab)
                let editorText = tab.editor.text
                let pageSize = min(1000, max(1, self.settings.sqlRowsPerPage))
                MongoUI.shared.pages[tab.id] = nil
                let observer = RunObserver(event: { event in
                    if query.operation == "listCollections", case .sql(let result) = event {
                        MongoUI.shared.collections[key] = result
                        MongoUI.shared.collectionsRead[key] = Date()
                    }
                    if query.operation == "sampleSchema", case .sql(let result) = event { MongoUI.shared.fields[key, default: [:]][query.collection] = result }
                    // Next Page under the result: a full page may have more after it.
                    if ["find", "aggregate", "distinct"].contains(query.operation), query.effect == .read,
                       case .sql(let result) = event, offset > 0 || result.rows.count == pageSize {
                        MongoUI.shared.pages[tab.id] = .init(query: query.json, editorText: editorText, connectionKey: key,
                                                              offset: offset, rows: result.rows.count, more: result.rows.count == pageSize)
                    }
                })
                self.startRun(tab, code: query.runnerCode(connection: connectionRef?.appName, pageSize: pageSize, offset: offset, confirmed: true), selection: nil, observer: observer, sql: info)
            }
        }
        // Destructive operations always ask first, on every connection (the shared danger sheet).
        let line = queryText == nil ? MongoQuery.startLine(in: tab.editor.text, from: tab.editor.selectedRange.length > 0 ? tab.editor.selectedRange.location : 0) : nil
        if let danger = DatabaseDangerConfirmation.mongo(query, line: line, database: saved?.database, connection: info.connectionLabel, tabId: tab.id, perform: run) {
            MongoUI.shared.danger = danger
        } else {
            run()
        }
    }

    func confirmMongoDanger() {
        guard let danger = MongoUI.shared.danger else { return }
        MongoUI.shared.danger = nil
        danger.perform()
    }

    func cancelMongoDanger() {
        MongoUI.shared.danger = nil
    }

    func mongoCacheKey(_ tab: TabModel) -> String {
        let choice = sqlConnectionChoice(for: tab)
        return tab.target.stableKey + ":" + (choice.ref?.key ?? "missing") + ":" + String(choice.savedConnection?.revision ?? 0)
    }

    /// Next Page: the shown page was full, and neither the query nor the connection changed.
    func canLoadMoreMongo(_ tab: TabModel) -> Bool {
        guard let page = MongoUI.shared.pages[tab.id], page.more else { return false }
        return page.editorText == tab.editor.text && page.connectionKey == mongoCacheKey(tab) && !tab.isRunning
    }

    func loadMoreMongo(_ tab: TabModel) {
        guard canLoadMoreMongo(tab), let page = MongoUI.shared.pages[tab.id] else { return }
        runMongo(tab, offset: page.nextOffset, queryText: page.query)
    }

    /// Open Find Query (#191), like the SQL explorer's Open in SQL Tab: a new MongoDB tab on the
    /// same target and connection, with a find of the collection's first 50 documents. Nothing runs.
    func openMongoFindQuery(_ collection: String, from tab: TabModel) {
        let code = MongoQuery.findTemplate(collection: collection)
        switch sqlConnectionChoice(for: tab) {
        case .saved(let connection):
            newTab(target: tab.target, code: code, title: collection, language: .mongodb, sqlSavedConnection: connection.id, sqlSavedConnectionName: connection.name)
        case .missing(let name):
            newTab(target: tab.target, code: code, title: collection, language: .mongodb, sqlSavedConnectionName: name)
        case .app(let name):
            newTab(target: tab.target, code: code, title: collection, language: .mongodb, sqlConnection: name)
        }
        focusSelectedEditor()
    }

    /// Forget Collections: the pane's collections and sampled fields for the tab's connection.
    func forgetMongoCollections(_ tab: TabModel) {
        let key = mongoCacheKey(tab)
        MongoUI.shared.collections[key] = nil
        MongoUI.shared.collectionsRead[key] = nil
        MongoUI.shared.fields[key] = nil
    }

    func mongoMetadata(_ operation: String, collection: String = "metadata", tab: TabModel) {
        let data = try! JSONSerialization.data(withJSONObject: ["operation": operation, "collection": collection])
        runMongo(tab, queryText: String(decoding: data, as: UTF8.self))
    }
}
