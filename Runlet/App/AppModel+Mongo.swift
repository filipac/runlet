import AppKit
import Observation
import RunletCore

@MainActor @Observable
final class MongoUI {
    /// Load More (#207) under a paged read's result (find, aggregate, distinct), like SQL's Load
    /// Next and Redis's Load More: the next page of the captured query, on the same connection,
    /// appended to the result card's table and its Extended JSON tree.
    struct Page {
        enum Phase: Equatable {
            case idle
            /// A page is loading: which documents ("documents 101–200").
            case loading(String)
            /// The last page didn't load: why.
            case failed(String)
        }
        var query: String
        var editorText: String
        var connectionKey: String
        /// The run's connection: the application's (by name) or the saved definition it used.
        var connection: String?
        var saved: DatabaseConnection?
        var target: TargetRef
        var run: SQLRunInfo
        /// Documents per page: what the first run read at most.
        var pageSize: Int
        /// Documents the card shows.
        var loaded: Int
        var pages = 1
        /// The last page was full, so more documents may follow.
        var more: Bool
        var phase: Phase = .idle
        var isLoading: Bool { if case .loading = phase { true } else { false } }
        var nextSize: Int? { MongoPaging.nextPageSize(loaded: loaded, pageSize: pageSize) }
    }
    /// The destructive-operation confirmation (#191): the shared database danger sheet.
    var danger: DatabaseDangerConfirmation?
    /// The Database pane's collections per `AppModel.mongoCacheKey`, and when they were read.
    var collections: [String: SQLResultInfo] = [:]
    var collectionsRead: [String: Date] = [:]
    /// Collections whose sampled fields show in the pane, as `cache key + U+001F + name`.
    var expanded: Set<String> = []
    var fields: [String: [String: SQLResultInfo]] = [:]
    var pages: [UUID: Page] = [:]
    /// The Database pane's Server section per `mongoCacheKey` (#207), and Kill Op's confirmation.
    var servers: [String: MongoServerState] = [:]
    var kill: DatabaseDangerConfirmation?
    /// Stops the page that is loading, per tab.
    @ObservationIgnored var pageStops: [UUID: () -> Void] = [:]
    #if DEBUG
    /// DEBUG step `mongo-menu:<collection>`: that row's context menu items in a popover.
    var debugMenuCollection: String?
    #endif
    static let shared = MongoUI()
}

extension AppModel {
    func runMongo(_ tab: TabModel, selectionOnly: Bool = false, queryText: String? = nil) {
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
                MongoUI.shared.pageStops.removeValue(forKey: tab.id)?()
                MongoUI.shared.pages[tab.id] = nil
                let observer = RunObserver(event: { event in
                    if query.operation == "listCollections", case .sql(let result) = event {
                        MongoUI.shared.collections[key] = result
                        MongoUI.shared.collectionsRead[key] = Date()
                    }
                    if query.operation == "sampleSchema", case .sql(let result) = event { MongoUI.shared.fields[key, default: [:]][query.collection] = result }
                    // Load More under the result (#207): a full page may have more after it.
                    if ["find", "aggregate", "distinct"].contains(query.operation), query.effect == .read,
                       case .sql(let result) = event, result.rows.count == pageSize {
                        MongoUI.shared.pages[tab.id] = .init(query: query.json, editorText: editorText, connectionKey: key, connection: connectionRef?.appName,
                                                              saved: saved, target: target, run: info, pageSize: pageSize, loaded: result.rows.count, more: true)
                    }
                })
                self.startRun(tab, code: query.runnerCode(connection: connectionRef?.appName, pageSize: pageSize, confirmed: true), selection: nil, observer: observer, sql: info)
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

    /// Load More: the last page was full, the card is still in the output, and neither the query
    /// nor the connection changed.
    func canLoadMoreMongo(_ tab: TabModel) -> Bool {
        guard let page = MongoUI.shared.pages[tab.id], page.more, !page.isLoading, page.nextSize != nil else { return false }
        return page.editorText == tab.editor.text && page.connectionKey == mongoCacheKey(tab) && !tab.isRunning && tab.mongoResultItems() != nil
    }

    /// Load More (#207): reads the next page of the captured query in a fresh runner, on the same
    /// target and connection, and appends its documents to the card's table and tree. Production
    /// asks first, like Run; it is a Run History entry of its own.
    func loadMoreMongo(_ tab: TabModel) {
        guard canLoadMoreMongo(tab), let page = MongoUI.shared.pages[tab.id], let size = page.nextSize else { return }
        if let saved = page.saved, library.databaseConnection(saved.id) != saved {
            MongoUI.shared.pages[tab.id]?.phase = .failed("The saved connection “\(saved.name)” changed or was removed since the query ran. Run it again to page.")
            return
        }
        let rows = "documents \((page.loaded + 1).formatted())–\((page.loaded + size).formatted())"
        guardProduction(.mongodb, target: page.target, text: page.query, isSelection: false, sqlWarning: nil,
                        sqlConnection: page.run.connectionLabel, sqlSaved: page.saved != nil, savedConnection: page.saved,
                        in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, self.canLoadMoreMongo(tab) else { return }
            self.startMongoPage(tab, page: page, size: size, rows: rows)
        }
    }

    func stopMongoPage(_ tab: TabModel) {
        MongoUI.shared.pageStops[tab.id]?()
    }

    private func startMongoPage(_ tab: TabModel, page: MongoUI.Page, size: Int, rows: String) {
        guard let query = try? MongoQuery(page.query) else { return }
        let tabId = tab.id
        let target = page.target
        let marking = library.marking(for: target, connection: page.saved)
        let code = query.runnerCode(connection: page.connection, pageSize: size, offset: page.loaded, confirmed: true)
        let hints = page.saved == nil ? sessionHints[target.stableKey] ?? [:] : [:]
        let runId = UUID()
        let engine = self.engine
        MongoUI.shared.pages[tabId]?.phase = .loading(rows)
        let task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            var result: SQLResultInfo?
            var dump: DumpInfo?
            var errors: [RunErrorInfo] = []
            var finished: FinishedInfo?
            var cancelled: SQLCancelReport?
            var label = ""
            do {
                let snapshot = try await self.sqlSnapshot(for: tab, saved: page.saved)
                defer { self.releaseSQLTunnel(snapshot) }
                label = snapshot.label
                try Task.checkCancellation()
                var request = RunRequest(runId: runId, tabId: UUID(), documentVersion: tab.documentVersion, target: snapshot, code: code,
                                         inspector: RunInspectorOptions(enabled: false, interceptMail: false, previews: false), magicComments: false)
                request.sqlConnection = page.saved
                request.hints = hints
                let stream = try await engine.start(request)
                await withTaskCancellationHandler {
                    for await event in stream {
                        switch event.kind {
                        case .sql(let info): result = info
                        case .dump(let info): dump = info
                        case .error(let error): errors.append(TabModel.withoutRunnerLocation(error))
                        case .finished(let info): finished = info
                        case .sqlCancel(let report): cancelled = report
                        default: break
                        }
                    }
                } onCancel: {
                    Task { await engine.cancel(runId: runId) }
                }
            } catch is CancellationError {
            } catch {
                errors.append(RunErrorInfo(stage: .launch, message: "\(error)"))
            }
            MongoUI.shared.pageStops[tabId] = nil
            if let finished {
                self.recordHistory(HistoryEntry(runId: runId, code: page.run.historyCode, target: target, targetLabel: label, status: finished.status, reason: finished.reason,
                                                elapsedMs: finished.elapsedMs, language: .mongodb, targetEnvironment: marking.environment, targetColor: marking.color, connection: page.run.historyConnection))
            }
            guard MongoUI.shared.pages[tabId]?.isLoading == true else { return }
            if Task.isCancelled || finished?.status == .cancelled {
                MongoUI.shared.pages[tabId]?.phase = .failed("Stopped. No documents were added." + (cancelled.map { " " + $0.message } ?? ""))
                return
            }
            guard let result, let items = tab.mongoResultItems(), let base = tab.sqlResult(items.sql) else {
                MongoUI.shared.pages[tabId]?.phase = .failed(errors.first.map { $0.interruptedByStop == true ? SQLCancel.interruptedText($0) : $0.message } ?? "The page ended without documents.")
                return
            }
            guard let merged = MongoPaging.appending(base, page: result) else {
                MongoUI.shared.pages[tabId]?.phase = .failed("The page isn't a MongoDB result, so Runlet didn't add it.")
                return
            }
            tab.replaceSQLResult(items.sql, with: merged)
            if let dumpId = items.dump, let tree = tab.dumpInfo(dumpId), let dump, let appended = MongoPaging.appending(tree, page: dump) {
                tab.replaceDump(dumpId, with: appended)
            }
            MongoUI.shared.pages[tabId]?.loaded += result.rows.count
            MongoUI.shared.pages[tabId]?.pages += 1
            MongoUI.shared.pages[tabId]?.more = result.rows.count == size
            MongoUI.shared.pages[tabId]?.phase = .idle
        }
        MongoUI.shared.pageStops[tabId] = {
            MongoUI.shared.pageStops[tabId] = nil
            Task { if await engine.cancel(runId: runId) == nil { task.cancel() } }
        }
        trackDatabaseWork(DatabaseWork(purpose: .loadNext(rows), tabId: tabId, tabTitle: tab.title, target: target,
                                       connection: page.saved.map { .saved($0) } ?? .app(page.connection), statement: page.query) {
            MongoUI.shared.pageStops[tabId]?()
        }, until: task)
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

    /// Sample Fields: reads up to 50 documents of the collection (production asks first); its
    /// fields then show under it in the pane.
    func sampleMongoFields(_ collection: String, tab: TabModel) {
        MongoUI.shared.expanded.insert(mongoCacheKey(tab) + "\u{1F}" + collection)
        mongoMetadata("sampleSchema", collection: collection, tab: tab)
    }

    func mongoMetadata(_ operation: String, collection: String = "metadata", tab: TabModel) {
        let data = try! JSONSerialization.data(withJSONObject: ["operation": operation, "collection": collection])
        runMongo(tab, queryText: String(decoding: data, as: UTF8.self))
    }
}
