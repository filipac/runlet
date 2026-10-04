import AppKit
import Observation
import RunletCore

/// One relations diagram window (#153): a table of the explorer's schema, the tables it references,
/// and the tables that reference it, drawn from the schema already loaded (`SQLSchemaStore`).
/// Nothing in it reads or runs anything; it is kept only while its window is open and never saved.
@MainActor
@Observable
final class RelationsDocument: Identifiable {
    let id = UUID()
    let target: TargetRef
    let connection: SQLConnectionChoice
    let ref: SQLConnectionRef
    /// The tab it was opened from: Load Schema and Show Definition go through it.
    let tabId: UUID
    /// The window it was opened from: Open in SQL Tab opens there.
    let windowId: UUID?
    /// "the default connection on acme"
    let subtitle: String
    /// Back and Forward: the tables it was centred on.
    private(set) var history: [String]
    private(set) var position = 0
    /// One or two hops out; changing it shows collapsed groups collapsed again.
    var hops = 1 {
        didSet { if hops != oldValue { expanded = []; selectedEdge = nil } }
    }
    /// Every column, or only key columns (primary, foreign, and referenced).
    var allColumns = false
    /// Collapsed groups shown in full ("+N more", clicked).
    var expanded: Set<String> = []
    /// The selected line, by `SQLRelationsLayout.Edge.id`: its JOIN shows in the footer.
    var selectedEdge: String?
    var zoom: CGFloat = 1
    /// Asks the canvas to scroll the focus into view (after re-centring or zooming).
    var scrollRequest = 0
    /// Asks the canvas to zoom so the whole diagram fits (Zoom to Fit).
    var fitRequest = 0
    /// What the last action did, for DEBUG steps.
    var lastAction: String?
    #if DEBUG
    /// DEBUG step `relations-key-menu`: the line whose context menu items show in a popover.
    var debugMenuEdge: String?
    #endif

    @ObservationIgnored private var cachedRelations: (token: String, relations: [SQLRelations.Relation])?
    @ObservationIgnored private var cachedLayout: (key: String, layout: SQLRelationsLayout?)?

    init(table: String, target: TargetRef, connection: SQLConnectionChoice, ref: SQLConnectionRef, tabId: UUID, windowId: UUID?, subtitle: String) {
        history = [table]
        self.target = target
        self.connection = connection
        self.ref = ref
        self.tabId = tabId
        self.windowId = windowId
        self.subtitle = subtitle
    }

    var focus: String { history[position] }
    var canGoBack: Bool { position > 0 }
    var canGoForward: Bool { position < history.count - 1 }
    /// The window's title; `Relations` first, so DEBUG shots can find it by prefix.
    var title: String { "Relations · \(focus)" }

    /// Clicking a table: centres the diagram on it, dropping Forward.
    func recentre(on table: String) {
        guard table != focus else { return }
        history = Array(history.prefix(position + 1)) + [table]
        position = history.count - 1
        changedFocus()
    }

    func back() {
        guard canGoBack else { return }
        position -= 1
        changedFocus()
    }

    func forward() {
        guard canGoForward else { return }
        position += 1
        changedFocus()
    }

    private func changedFocus() {
        expanded = []
        selectedEdge = nil
        scrollRequest += 1
    }

    /// The layout for `schema`, recomputed only when the schema or the options change.
    func layout(for schema: SQLSchemaInfo, token: String) -> SQLRelationsLayout? {
        let key = [token, focus, String(hops), String(allColumns), expanded.sorted().joined(separator: ",")].joined(separator: "\u{1F}")
        if let cachedLayout, cachedLayout.key == key { return cachedLayout.layout }
        if cachedRelations?.token != token { cachedRelations = (token, SQLRelations.relations(in: schema)) }
        let graph = SQLRelations.graph(of: focus, in: schema, hops: hops, relations: cachedRelations?.relations)
        let layout = graph.map { SQLRelationsLayout.make($0, allColumns: allColumns, expanded: expanded) }
        cachedLayout = (key, layout)
        return layout
    }
}

/// Open relations windows, by id (like `ResultWindows`).
@MainActor
enum RelationsWindows {
    static var documents: [UUID: RelationsDocument] = [:]
    private static var order: [UUID] = []
    /// Set by a main window (it has the `openWindow` action).
    static var openAction: ((UUID) -> Void)?

    static func open(_ document: RelationsDocument) {
        documents[document.id] = document
        order.append(document.id)
        openAction?(document.id)
    }

    /// The most recently opened document still open (DEBUG steps).
    static var latest: RelationsDocument? { order.reversed().lazy.compactMap { documents[$0] }.first }
}

/// Show Relations (#153): the explorer's actions for the diagram. They open, copy, or insert
/// text; none of them runs it. Load Schema keeps its production rule.
extension AppModel {
    /// Show Relations: a window with the table's diagram, from the explorer's schema of the tab's
    /// target and connection.
    func showSchemaRelations(_ table: String, from tab: TabModel) {
        let choice = explorerConnection(for: tab)
        guard let ref = choice.ref else {
            if case .missing(let name) = choice {
                alert = AppAlert(title: "The saved connection isn't defined", message: SQLConnectionChoice.missingMessage(name))
            }
            return
        }
        let label = choice.label
        let document = RelationsDocument(table: table, target: tab.target, connection: choice, ref: ref, tabId: tab.id, windowId: window(containing: tab.id)?.id,
                                         subtitle: label.prefix(1).uppercased() + label.dropFirst() + " on " + targetLabel(tab.target))
        RelationsWindows.open(document)
    }

    /// The diagram's schema, and a token that changes when it is read again; nil when it isn't
    /// loaded (never read, or forgotten).
    func relationsSchema(_ document: RelationsDocument) -> (schema: SQLSchemaInfo, token: String)? {
        guard let state = sqlSchemaState(target: document.target, connection: document.ref), let schema = state.schema else { return nil }
        let date: Date? = switch state {
        case .loaded(_, let at): at
        case .failed(_, let at, _): at
        case .loading: nil
        }
        return (schema, "\(schema.tables.count):\(schema.columnCount):\(schema.elapsedMs ?? 0):\(date?.timeIntervalSince1970 ?? 0)")
    }

    /// The tab the diagram came from, while it is open.
    func relationsTab(_ document: RelationsDocument) -> TabModel? {
        windows.lazy.flatMap(\.tabs).first { $0.id == document.tabId }
    }

    /// Whether the diagram's schema is being read.
    func relationsSchemaLoading(_ document: RelationsDocument) -> Bool {
        sqlSchemaState(target: document.target, connection: document.ref)?.isLoading == true
    }

    /// Load Schema from the diagram: the explorer's own, so production asks first.
    func loadRelationsSchema(_ document: RelationsDocument) {
        guard let tab = relationsTab(document) else { return }
        loadSQLSchema(for: tab, connection: document.connection)
    }

    /// The SQL tab Insert Join writes into: the current tab when it is an SQL tab, else the tab
    /// the diagram came from when that is one.
    func relationsInsertTab(_ document: RelationsDocument) -> TabModel? {
        if let tab = selectedTab, tab.language == .sql { return tab }
        if let tab = relationsTab(document), tab.language == .sql { return tab }
        return nil
    }

    /// The JOIN for a line: the table further from the focus joined onto the other (Reverse:
    /// the other way round), quoted for the schema's driver.
    func relationJoin(_ relation: SQLRelations.Relation, in document: RelationsDocument, reverse: Bool = false) -> String? {
        guard let (schema, token) = relationsSchema(document), let layout = document.layout(for: schema, token: token) else { return nil }
        var table = SQLRelations.joinedTable(relation, in: layout.graph)
        if reverse, !relation.isSelfReference { table = table == relation.to ? relation.from : relation.to }
        return SQLRelations.join(relation, joining: table, driver: schema.driver)
    }

    /// Copy Join: the JOIN clause on the clipboard.
    func copyRelationJoin(_ relation: SQLRelations.Relation, in document: RelationsDocument, reverse: Bool = false) {
        guard let join = relationJoin(relation, in: document, reverse: reverse) else { return }
        Pasteboard.copy(join)
        document.lastAction = "copied: \(join)"
    }

    /// Insert Join: the JOIN clause at the cursor of the current SQL tab, on a line of its own.
    /// It doesn't run.
    func insertRelationJoin(_ relation: SQLRelations.Relation, in document: RelationsDocument, reverse: Bool = false) {
        guard let tab = relationsInsertTab(document), let join = relationJoin(relation, in: document, reverse: reverse) else { return }
        let editor = tab.editor
        let text = editor.text as NSString
        let caret = editor.selectedRange.location
        let atLineStart = caret == 0 || caret > text.length || text.character(at: caret - 1) == 10
        editor.insert((atLineStart ? "" : "\n") + join)
        document.lastAction = "inserted into \(tab.title): \(join)"
    }

    /// Open in SQL Tab from the diagram: the table's first rows in a new SQL tab on the diagram's
    /// target and connection, in the window it came from. It doesn't run.
    func openRelationsTable(_ table: String, in document: RelationsDocument) {
        let query = SQLSchemaExplorer.selectQuery(table: table, driver: relationsSchema(document)?.schema.driver)
        let window = document.windowId.flatMap { id in windows.first { $0.id == id } }
        switch document.connection {
        case .saved(let saved):
            newTab(target: document.target, code: query, title: table, in: window, language: .sql, sqlSavedConnection: saved.id, sqlSavedConnectionName: saved.name)
        case .missing(let name):
            newTab(target: document.target, code: query, title: table, in: window, language: .sql, sqlSavedConnectionName: name)
        case .app(let name):
            newTab(target: document.target, code: query, title: table, in: window, language: .sql, sqlConnection: name)
        }
        document.lastAction = "opened \(table) in an SQL tab"
        focusSelectedEditor()
    }

    /// Browse Table (#151) from the diagram, through the tab it came from (production asks first).
    func browseRelationsTable(_ table: String, in document: RelationsDocument) {
        guard let tab = relationsTab(document), let schema = relationsSchema(document)?.schema, let info = schema.tables.first(where: { $0.name == table }) else { return }
        browseSchemaTable(info, schema: schema, from: tab)
        document.lastAction = "browsed \(table)"
    }

    /// Show Definition (#148) from the diagram, through the tab it came from (production asks
    /// first; the sheet shows on that tab's window).
    func showRelationsDefinition(_ table: String, in document: RelationsDocument) {
        guard let tab = relationsTab(document), let schema = relationsSchema(document)?.schema, let info = schema.tables.first(where: { $0.name == table }) else { return }
        showSchemaDefinition(info, schema: schema, from: tab)
        document.lastAction = "showed the definition of \(table)"
    }
}
