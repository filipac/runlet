#if DEBUG
import AppKit
import RunletCore
import RunletLanguage
import WebKit

/// More RUNLET_DEBUG_STEPS steps (see `AppDelegate.runDebugInspectorCheck`), for checking
/// keyboard flows and file watching without UI scripting. Key events are sent to Runlet only,
/// so it has to be the active app (`activate` first):
/// `perform:<command id>` · `key:<[cmd+][shift+][opt+][ctrl+]name>` (a letter, digit, or
/// return, escape, delete, tab, up, down, left, right) · `editor-key:<same>` (handed straight
/// to the current tab's editor, so it works in the background too, and prints whether the
/// output pane is shown) · `type:<text>` · `state` (prints the
/// key window's focus and the active window's tabs) · `open:<path>` (like Finder) ·
/// `write:<path>|<text>` (appends in place) · `replace:<path>|<text>` (an atomic save) ·
/// `remove:<path>` · `edit:<text>` (inserts at the current tab's cursor) · `click:<accessibility
/// identifier>` · `dock[:<n>]` (lists the Dock menu, or chooses its nth item) ·
/// `settings-tab:<name>` (picks a tab of the open Settings window) · `auto-run:on|off`
/// (the sandbox tab toolbar opt-in, for background snapshots) · `mcp:on|off` (Settings ▸
/// AI Clients ▸ Allow AI clients to connect) · `mcp-approve` / `mcp-approve:session` /
/// `mcp-decline` (answers the AI client approval sheet on screen, as its Run button with or
/// without "Allow for this session", or Cancel; Debug builds only, for scripted end-to-end
/// checks with scratch data) · `mcp-state` (prints the sheet, queue, and clients) ·
/// `flame:hover|zoom:<frame name>`, `flame:search:<text>`, `flame:reset` (the Profile section's
/// flame graph, #41) · `docker-test` (Test Connection in the open Docker profile form) ·
/// `browse:<path>` and `browse:select:<folder name>` (the open Browse… folder picker lists that
/// folder, or selects a listed subfolder, #62; open it with `press:docker-browse-directory`) ·
/// `editor-check` (checks that a failed line's red background goes away after edits, undo, and
/// new runs, that only the caret's bracket pair stays highlighted, and that loaded, inserted,
/// and restored text has the editor's font, line height, and color, and that the gutter's line
/// numbers sit on their lines' baselines, on an editor of its own that is never shown:
/// `EditorDebugCheck`, #87, #113, #114, and #124) · `snippet-open:<label>`,
/// `snippet-input:<name>=<value>`, and `snippet-inputs:open|cancel|state` (a parameterised
/// snippet's input form, #14; see `SnippetInputDebugSteps`) · `app-info[:card]` (Show App Info for
/// the current tab, from the status bar's framework chip or the tab card's, as a click on it
/// does: it loads only when nothing is cached, and production targets ask first; `app-info:off`
/// closes it; #19) ·
/// `app-info-state` (prints the current tab's App Info state) ·
/// `notifications:allowed|denied|notDetermined|unavailable` (the permission Debug builds'
/// logging notifier reports, for Settings ▸ General ▸ Notifications; #26), `notification-click`
/// (handles a click on the last run notification it logged, as `RunNotificationResponder`
/// does, then prints the selected window and tab), and `notification-state` (prints the
/// setting, threshold, permission, and the last notification). Scripted runs never post real
/// notifications or ask macOS for permission: see `LoggingRunNotifier` ·
/// `promote:artisan:<file>` and `promote:test:<file>` (Save as Artisan Command… or Save as Test…
/// for the current tab, #39, writing `<file>` instead of asking in the save panel, then showing
/// the sheet that follows; `promote:off` closes that sheet) · `promote-state` (prints both
/// commands' availability) · `db-new`, `db-use`, `db-editor`, `db-field`, `db-test`, `db-wait`,
/// `db-save`, `db-cancel`, `db-picker`, `db-list`, and `db-state` (saved database connections,
/// #138, with Read-only and their own environment, #139; see `DatabaseDebugSteps`) ·
/// `sql-param:<placeholder>=<type>[:<value>]`,
/// `sql-params:run|collapse|expand|statement|all|return|escape|tab|shift+tab|type:<text>|write|undo-check|state|timing[:<n>]`, and `sql-history`
/// (the SQL parameters drawer, #145 and #168; see `SQLParameterDebugSteps`) ·
/// `target:<name>` (the current tab's target: a saved local project, Docker profile, or SSH
/// profile by name, or `target:sandbox`; never runs code) · `run-inspector:on|off` (Settings ▸
/// General ▸ Record queries, mail, and logs) · `mail-chip-state` (prints the current tab's mail
/// chip: its state, source, and the target's Mail option, #193) · `mail-chip:on|off` (opens or
/// closes its popover) and `mail-chip:choose:default|intercept|send` (chooses that option in
/// the open popover, as a click does; a production target then shows its confirmation) ·
/// `alert` (prints the app's alert) and `alert:off` (presses its OK; in a ghosted app that
/// isn't active, AppKit's sheet animation can crash then, so shoot an alert last). In
/// texts, `\n`
/// is a newline. A command that shows an alert should be pressed
/// with its shortcut (`key:cmd+s`), not `perform`: run from a step, `NSAlert.runModal` returns
/// at once.
///
/// Screenshot steps, used by scripts/website-screenshots/shoot.sh. They need no key events, so
/// Runlet can stay in the background:
/// `ghost` / `ghost:off` (keeps Runlet's windows drawing but invisible, click-through, and
/// without a Dock icon, so a screenshot run shows nothing on screen; launch with `open -g -j`
/// and make it the first step) · `appearance:light|dark|system` (the Appearance setting, as
/// Settings sets it) · `frame:<width>x<height>` (the main window's size in points; `frame:<window title>=<width>x<height>` for another window) ·
/// `scale:<n>` (`shot` draws at least n pixels per point, e.g. 2 on a 1x screen) · `caret:end` or `caret:<line>[:<column>]` (the current tab's cursor) ·
/// `palette:anything|commands[:<query>]` (opens the palette with that search; `palette:off`
/// closes it) · `palette-return`
/// (↩ in the open palette: chooses its selected row) · `appearance-state` (prints the
/// Appearance setting, saved and in memory, and what the app, each visible window, and a new
/// completion-style popup draw in, #135) · `complete`
/// (Show Completions in the current tab) · `sql-run-all` (Run All Statements, #129, waitable
/// with `wait-run`) · `sql-cancel-state` (#144: the current tab's run state, the Run Log's
/// session and server-cancel lines, and the output's last notice or warning) · `snippet-messages-state`
/// (#196: the output's `\Runlet\notice()`, `warning()`, and `error()` cards, the run's status, and
/// its footer count) · `sql-transaction:on|off` · `sql-schema:load|forget|state` (#128) ·
/// `sql-explain[:analyze]`, `analyze-confirm:yes|no`, and `sql-plan:raw|tree|collapse:<n>|expand|state`
/// (Explain Statement, #147; see `SQLExplainDebugSteps`) ·
/// `sql-load-next`, `sql-page-stop`, `sql-page-state`, `sql-rows-per-page:<n>`,
/// `table-scroll:<row>|end`, `timing:start|report`, and `wait-page[:<seconds>]` (Load Next,
/// #146; see `SQLPagingDebugSteps`) ·
/// `schema-expand:<table>`, `schema-search:<text>`, and `schema-open:<table>` (the Database pane, #21) ·
/// `history-filter:<connection title>` (the History pane's Connection filter, #149; empty for
/// every run) and `connection-state` (prints the current tab's connection and its SQL bar note) ·
/// `schema-definition:<table>` (its Show Definition, #148: production asks first, then a sheet reads the
/// definition; `schema-definition:copy|open|done` press its buttons, `schema-definition:size:<w>x<h>` resizes it),
/// `schema-definition-state`, and `schema-menu:<table>|off` (a row's context menu items in a popover) ·
/// `relations:<table>`, `relations-focus`, `relations-select`, `relations-copy-join`, `relations-export`,
/// `relations-state`, and more (Show Relations' diagram, #153; see `RelationsDebugSteps`) ·
/// `server`, `server-read`, `server-filter`, `server-hide-idle`, `server-refresh`, `server-action`,
/// `server-confirm`, and `server-state` (the Database pane's Server section, #150; see
/// `DatabaseServerDebugSteps`) · `connections`, `connection-close`, `connection-confirm`,
/// `connections-state`, and `connections-wait` (the Connection Manager, #180; see
/// `ConnectionDebugSteps`) · `advanced`, `flag`, and `tableplus-open|select|ssh|scope|duplicates|passwords|import|wait|state`
/// (feature flags, #187, and Import from TablePlus…, #188; see `TablePlusDebugSteps`) · `result-window`
/// (the current tab's last table in a result window), `result-search:<text>`,
/// `result-filter:<column>|<operator>|<value>`, `result-sort:<column>[:desc]`,
/// `result-hide:<column>`, and `result-state` (#21) · `segment:<label prefix>` (picks a segment, e.g.
/// `segment:Table` for a result's table) · `command:<name>` (runs a project command the
/// Commands pane listed, as its ▶ button does) · `terminal:<text>` (types into the active
/// window's selected terminal tab, straight to its process, so Runlet can stay in the
/// background; `\n` is Return, `\c` a comma) · `scroll:<accessibility identifier>` (scrolls
/// the element to the middle of its scroll view, e.g. a toggle low in a sheet's form) ·
/// `search:<identifier>|<query>` (sets a library search without keyboard focus) ·
/// `press:<identifier>` (invokes a control's accessibility press without activating the app) ·
/// `tests:all|file:<path>|filter:<text>` (the Commands pane's Tests buttons for the selected
/// tab, #40) · `tests-prompt:filter|file[:<text>]` (opens the Tests group's prompt with that
/// text) ·
/// `selection:<first line>-<last line>` (selects whole lines in the current tab, for Run
/// Selection) · `editor-scroll` (prints each loaded editor's horizontal offset from its leading
/// edge, #78; see scripts/check-editor-scroll.sh) · `inline:<line>` (shows the inline-value panel of an editor line, as hovering its
/// magic comments' values does; `inline:off` hides it) ·
/// `scroll-check[:<points>]` (scrolls the main window's tallest list, such as the output or a
/// result table, top to bottom and prints each step's layout-and-draw time, #162) ·
/// `table-filter:<text>`, `table-sort:<column>[:desc]`, and `table-state` (the output's last
/// table: its filter, a header click, and the rows it shows, #162) ·
/// `shot:<name>` (writes `<name>.png` to
/// RUNLET_SNAPSHOT_DIR: the main window with its sheet, palette, and popups drawn on top;
/// `shot:<name>@<window title>` draws another window, such as Settings; `\c` in a window title
/// is a comma, and a title ending in `*` matches the start of one).
@MainActor
enum DebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "appearance":
            // The app's setting, as Settings and the Appearance commands change it: it also sets
            // the whole app's appearance, which panels such as the completion list follow (#135).
            model.settings.appearance = AppearancePreference(rawValue: argument) ?? .system
            model.applyAppearance()
        case "frame":
            // `frame:<width>x<height>`, or `frame:<window title>=<width>x<height>` (e.g. Settings).
            let (title, spec) = titled(argument, "=")
            let size = spec.split(separator: "x").compactMap { Double($0) }
            if size.count == 2, let window = title.flatMap(window(titled:)) ?? (title == nil ? mainWindow() : nil) {
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size[1], width: size[0], height: size[1]), display: true)
            }
        case "ghost":
            ghost(argument != "off")
        case "scale":
            shotScale = Double(argument).map { CGFloat($0) } ?? 1
        case "caret":
            guard let editor = model.selectedTab?.editor else { return true }
            if argument == "end" {
                let end = (editor.text as NSString).length
                editor.textView.setSelectedRange(NSRange(location: end, length: 0))
                editor.textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            } else {
                let numbers = argument.split(separator: ":").compactMap { Int($0) }
                if let line = numbers.first { editor.goTo(line: line, column: numbers.count > 1 ? numbers[1] : 1) }
            }
        case "promote":
            // `promote:artisan:<file>` / `promote:test:<file>` (#39): no save panel, the file given.
            if argument == "off" {
                model.promotedFile = nil
                return true
            }
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return true }
            model.promoteCurrentTab(parts[0] == "artisan" ? .artisanCommand : .test, destination: URL(fileURLWithPath: parts[1]))
            let written = (try? String(contentsOfFile: parts[1], encoding: .utf8)) ?? "(nothing written)"
            FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: promoted \(parts[1]):\n\(written)\n".utf8))
        case "promote-state":
            for kind in PromotionKind.allCases {
                let reason = model.promotionUnavailableReason(kind, for: model.selectedTab)
                FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(kind.rawValue) \(reason.map { "disabled: \($0)" } ?? "enabled")\n".utf8))
            }
        case "palette":
            if argument == "off" {
                NSApp.windows.compactMap { ($0 as? PalettePanel)?.controller }.first?.close()
                return true
            }
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            let commands = parts.first == "commands"
            if !NSApp.windows.contains(where: { $0 is PalettePanel && $0.isVisible }) {
                model.perform(commands ? "library.commandPalette" : "library.openAnything")
            }
            if parts.count > 1, let controller = NSApp.windows.compactMap({ ($0 as? PalettePanel)?.controller }).first {
                controller.edit(parts[1])
            }
        case "palette-return":
            // ↩ in the open palette: chooses the selected row, as the search field does, without
            // key focus (#135).
            paletteReturn()
        case "appearance-state":
            // The setting (in memory and saved), the app's appearance, and what each visible
            // window and a completion-style popup draw in (#135).
            log(appearanceState(model))
        case "alert":
            // `alert:off` dismisses the app's alert (e.g. a read-only refusal, #139), as OK does;
            // `alert` prints it.
            if argument == "off" {
                // Presses the alert sheet's default button, as a click does (clearing the binding
                // under an open NSAlert sheet crashes AppKit's sheet animation).
                func buttons(in view: NSView) -> [NSButton] {
                    view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
                }
                let sheet = NSApp.windows.compactMap(\.attachedSheet).first { String(describing: type(of: $0)).contains("Alert") }
                if let button = sheet?.contentView.flatMap({ buttons(in: $0).first { $0.keyEquivalent == "\r" } }) {
                    button.performClick(nil)
                } else {
                    model.alert = nil
                }
            } else {
                log("alert: \(model.alert.map { "\($0.title) — \($0.message)" } ?? "none")")
            }
        case "complete":
            // Show Completions in the current tab's editor, without key focus.
            model.selectedTab?.editor.textView.complete(nil)
        case "sql-run-all":
            // Run All Statements (#129) in the current SQL tab, timed like `run`, so `wait-run` waits.
            if let tab = model.selectedTab {
                DebugRunTiming.start(tab)
                model.runAllSQL(tab)
            }
        case "schema-expand":
            // `schema-expand:<table>` (#21): opens a table in the Database pane; `schema-expand:` closes all.
            guard let tab = model.selectedTab else { return true }
            let prefix = SQLSchemaStore.key(tab.target, model.explorerConnection(for: tab).ref ?? .app(nil)) + "\u{1F}"
            if argument.isEmpty { model.schemaExplorer.expanded = [] } else { model.schemaExplorer.expanded.insert(prefix + argument) }
        case "result-window":
            // Opens the current tab's last table (an SQL result, else a returned value) in a result window (#21).
            guard let tab = model.selectedTab else { return true }
            for item in tab.output.reversed() {
                if case .sql(let id, let result) = item, result.hasResultSet, !result.columns.isEmpty {
                    // With its Load Next (#146), as the card's Open in Window opens it.
                    ResultWindows.open(title: SQLResultCard.windowTitle(tabTitle: tab.title, result: result), subtitle: result.statement?.text ?? result.source, table: result.table, pager: tab.sqlPagers[id])
                    return true
                }
                if case .result(_, let info) = item, let value = info.value, let table = ValueTable.make(from: value) {
                    ResultWindows.open(title: "Table", subtitle: nil, table: table)
                    return true
                }
            }
            log("result-window: no table in the current tab's output")
        case "result-search":
            ResultWindows.latest?.query.search = argument
        case "result-filter":
            // `result-filter:<column>|<operator>|<value>`, e.g. `result-filter:status|equals|paid`.
            let parts = argument.components(separatedBy: "|")
            if let document = ResultWindows.latest, let column = document.table.columns.firstIndex(of: parts[0]),
               let op = ValueTableFilter.Operator(rawValue: parts.count > 1 ? parts[1] : "contains") {
                document.query.filters.append(ValueTableFilter(column: column, op: op, value: parts.count > 2 ? parts[2] : ""))
            }
        case "result-sort":
            // `result-sort:<column>[:desc]`.
            let (name, direction) = argument.hasSuffix(":desc") ? (String(argument.dropLast(5)), false) : (argument, true)
            if let document = ResultWindows.latest, let column = document.table.columns.firstIndex(of: name) {
                document.query.sortColumn = column
                document.query.ascending = direction
            }
        case "result-hide":
            if let document = ResultWindows.latest, let column = document.table.columns.firstIndex(of: argument) { document.hiddenColumns.insert(column) }
        case "result-state":
            if let document = ResultWindows.latest {
                // How long the query takes (off the main thread in the window, #146).
                let started = ProcessInfo.processInfo.systemUptime
                _ = document.query.rowIndices(in: document.table)
                let ms = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
                log("result-state: \(document.title) shows \(document.shownRows.count) of \(document.table.rows.count) rows, columns \(document.visibleColumns.map { document.table.columns[$0] }) (query takes \(ms) ms)")
            } else {
                log("result-state: none")
            }
        case "schema-open":
            // `schema-open:<table>` (#21): the Database pane's Open in SQL Tab (nothing runs).
            if let tab = model.selectedTab, let schema = model.explorerConnection(for: tab).ref.flatMap({ model.sqlSchemaState(target: tab.target, connection: $0) })?.schema {
                model.openSchemaTable(argument, schema: schema, from: tab)
            }
        case "schema-definition":
            // `schema-definition:<table>` (#148): the Database pane's Show Definition (production asks
            // first; the sheet reads the catalog, nothing runs). `schema-definition:copy|open|done`
            // press the sheet's buttons; `schema-definition:size:<width>x<height>` resizes the sheet.
            if argument == "copy" {
                // Copies, reports what was copied, and puts the clipboard back as it was.
                let pasteboard = NSPasteboard.general
                let saved = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
                model.copySchemaDefinition()
                let copied = pasteboard.string(forType: .string) ?? ""
                log("schema-definition: copied \(copied.count) characters, header \(copied.hasPrefix("-- Definition of ") ? "yes" : "no"), same as the sheet \(copied == model.schemaExplorer.definitionSheet?.text)")
                pasteboard.clearContents()
                pasteboard.writeObjects(saved.map { entries in
                    let item = NSPasteboardItem()
                    for (type, data) in entries { item.setData(data, forType: type) }
                    return item
                })
            } else if argument == "open" {
                model.openSchemaDefinitionInTab()
            } else if argument == "done" {
                model.closeSchemaDefinition()
            } else if argument.hasPrefix("size:") {
                let size = argument.dropFirst(5).split(separator: "x").compactMap { Double($0) }
                if size.count == 2, let sheet = mainWindow()?.attachedSheet {
                    // As a drag would: no smaller than the sheet's minimum.
                    let width = max(size[0], sheet.minSize.width), height = max(size[1], sheet.minSize.height)
                    sheet.setFrame(NSRect(x: sheet.frame.minX, y: sheet.frame.maxY - height, width: width, height: height), display: true)
                }
            } else if let tab = model.selectedTab, let schema = model.explorerConnection(for: tab).ref.flatMap({ model.sqlSchemaState(target: tab.target, connection: $0) })?.schema,
                      let table = schema.table(named: argument) {
                model.showSchemaDefinition(table, schema: schema, from: tab)
            } else {
                log("schema-definition: no table \(argument) in the loaded schema")
            }
        case "schema-definition-state":
            let sheet = model.schemaExplorer.definitionSheet
            let state = switch sheet?.state {
            case nil: "no sheet"
            case .loading: "loading"
            case .loaded(let info, let text): "loaded \(info.kind ?? "?") via \(info.how ?? "?"), \(text.count) characters, header \(text.hasPrefix("-- Definition of ") ? "yes" : "no")"
            case .failed(let message): "failed: \(message)"
            }
            let window = mainWindow()?.attachedSheet
            let frame = window.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) resizable=\($0.styleMask.contains(.resizable))" } ?? "none"
            log("schema-definition: \(sheet.map { "\($0.title) — \($0.subtitle)" } ?? "-") · \(state) · sheet window \(frame) · last: \(model.schemaExplorer.lastDefinition ?? "none") · tab: \(model.selectedTab.map { "\($0.title) [\($0.language)] output=\(model.isOutputPaneShown(for: $0))" } ?? "none") · tabs: \(model.activeWindow?.tabs.count ?? 0)")
        case "target":
            // `target:<name>` (#193): switches the current tab's target, as the target menu does.
            let library = model.library
            let target: TargetRef? = argument == "sandbox" ? .sandbox
                : library.localProjects.first { $0.name == argument }.map { .local($0.id) }
                ?? library.dockerProfiles.first { $0.name == argument }.map { .docker($0.id) }
                ?? library.sshProfiles.first { $0.name == argument }.map { .ssh($0.id) }
            if let tab = model.selectedTab, let target { model.setTarget(target, for: tab) } else { log("target \(argument) not found") }
        case "run-inspector":
            model.settings.runInspector = argument != "off"
        case "mail-chip":
            NotificationCenter.default.post(name: .debugMailChip, object: argument)
        case "mail-chip-state":
            // #193: what the current tab's mail chip shows.
            guard let tab = model.selectedTab else { return true }
            let mode = model.mailInterception(for: tab.target)
            log("mail-chip: \(mode.state.rawValue) source=\(mode.source.rawValue) option=\(mode.hasOption ? mode.override.map { $0 ? "intercept" : "send" } ?? "default" : "none") production=\(model.isProduction(tab.target)) report=\(model.mailInterceptionReport(for: tab.target).map { $0.interceptionUnsupported ? "unconfirmed" : "confirmed" } ?? "none")")
        case "schema-menu":
            // `schema-menu:<table>` (#148): the row's context menu items in a popover, for a
            // screenshot (a menu can't be drawn); `schema-menu:off` closes it.
            model.schemaExplorer.debugMenuTable = argument == "off" ? nil : argument
        case "schema-search":
            // `schema-search:<text>` (#21): the Database pane's filter.
            model.schemaExplorer.search = argument
        case "history-filter":
            // `history-filter:<connection title>` (#149): the History pane's Connection filter.
            NotificationCenter.default.post(name: .debugHistoryConnectionFilter, object: argument)
        case "connection-state":
            // #149: the current tab's connection after opening a history entry or snippet.
            guard let tab = model.selectedTab else { return true }
            log("connection-state: \(tab.title) [\(tab.language)] on \(model.sqlConnectionChoice(for: tab).label) · note: \(tab.sqlConnectionNote ?? "none") · production: \(model.isProduction(tab.target, connection: model.sqlConnectionChoice(for: tab).savedConnection))")
        case "sql-transaction":
            // `sql-transaction:on|off` (#129): the SQL bar's In a Transaction box.
            if let tab = model.selectedTab { model.setSQLTransaction(argument != "off", for: tab) }
        case "sql-schema":
            // `sql-schema:load|forget|state` (#128): the current SQL tab's schema for completion.
            guard let tab = model.selectedTab else { return true }
            switch argument {
            case "load": model.loadSQLSchema(for: tab)
            case "forget": model.forgetSQLSchema(for: tab)
            default:
                switch model.sqlSchemaState(for: tab) {
                case nil: log("sql-schema: none")
                case .loading: log("sql-schema: loading")
                case .loaded(let schema, _): log("sql-schema: \(schema.summary) via \(schema.how ?? "?"): " + schema.tables.map { "\($0.name)(\($0.columns.map(\.name).joined(separator: " ")))" }.joined(separator: ", "))
                case .failed(let message, _, _): log("sql-schema: failed: \(message)")
                }
            }
        case "selection":
            // `selection:<first line>-<last line>`: whole lines, for Run Selection.
            let lines = argument.split(separator: "-").compactMap { Int($0) }
            guard let editor = model.selectedTab?.editor, lines.count == 2 else { return true }
            let text = editor.text as NSString
            let index = TextLineIndex(editor.text)
            let start = index.offset(of: LSPPosition(line: lines[0] - 1, character: 0))
            let end = NSMaxRange(text.lineRange(for: NSRange(location: index.offset(of: LSPPosition(line: lines[1] - 1, character: 0)), length: 0)))
            editor.textView.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
        case "inline":
            // `inline:<line>`: the inline-value panel of an editor line, as on hover; `inline:off` hides it.
            if argument == "off" {
                model.selectedTab?.editor.inlineValues.hidePanel()
            } else if let line = Int(argument), model.selectedTab?.editor.showInlineValue(line: line) != true {
                log("inline: no values on line \(line)")
            }
        case "segment":
            // `segment:<label prefix>` picks the first segment whose label starts with it (the
            // last such control in the main window), e.g. `segment:Table` for a result's table.
            let controls = segmentedControls(in: mainWindow().flatMap { $0.contentView?.superview ?? $0.contentView })
            guard let control = controls.last(where: { control in (0..<control.segmentCount).contains { (control.label(forSegment: $0) ?? "").hasPrefix(argument) } }),
                  let index = (0..<control.segmentCount).first(where: { (control.label(forSegment: $0) ?? "").hasPrefix(argument) }) else {
                log("segment \(argument) not found among \(controls.map { control in (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "?" } })")
                return true
            }
            control.selectedSegment = index
            control.sendAction(control.action, to: control.target)
        case "scroll":
            scroll(to: argument)
        case "scroll-check":
            // `scroll-check[:<points per step>]` (#162): scrolls the main window's tallest list.
            scrollCheck(step: Double(argument).map { CGFloat($0) } ?? 60)
        case "table-filter", "table-sort", "table-state":
            // The output's last table (#162): `table-filter:<text>` types into its filter,
            // `table-sort:<column>[:desc]` clicks a header, `table-state` prints what it shows.
            outputTable(name, argument)
        case "shot":
            // `shot:<name>`, or `shot:<name>@<window title>` for another window (e.g. Settings).
            let (title, name) = titled(argument, "@", titleFirst: false)
            shot(name.isEmpty ? "shot" : name, window: title.flatMap(window(titled:)))
        case "command":
            // Runs a listed project command like its ▶ button (the Commands pane must have listed it).
            if let tab = model.selectedTab, let command = model.commands(for: tab.target)?.commands.first(where: { $0.name == argument }) {
                model.runProjectCommand(command, in: tab)
            } else {
                log("command \(argument) not listed")
            }
        case "tests":
            // `tests:all`, `tests:file:<path>`, `tests:filter:<text>` (#40): the Commands pane's
            // Tests buttons for the selected tab, with that file or filter.
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1].replacingOccurrences(of: "\\c", with: ",") : ""
            guard let tab = model.selectedTab else { return true }
            switch parts.first {
            case "all": model.runTests(.all, in: tab)
            case "file": model.runTests(.file(value), in: tab)
            case "filter": model.runTests(.filter(value), in: tab)
            default: log("tests: \(argument)?")
            }
            log("tests offered=\(model.offersTests(for: tab.target)) runner=\(model.testDetection(for: tab.target)?.summary ?? "chosen on the target") production=\(model.isProduction(tab.target)) notice=\(model.projectCommands.notice.map { "\($0.kind)" } ?? "none")")
        case "tests-prompt":
            // `tests-prompt:filter|file[:<text>]` (#40): opens the Tests group's prompt with that text.
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            NotificationCenter.default.post(name: .debugTestsPrompt, object: nil, userInfo: ["kind": parts.first ?? "filter", "text": parts.count > 1 ? parts[1].replacingOccurrences(of: "\\c", with: ",") : ""])
        case "terminal":
            // Typed into the selected terminal tab's process, like keys (no key window needed).
            if let session = model.activeWindow?.terminals.selected, session.isRunning {
                session.view.send(txt: argument.replacingOccurrences(of: "\\n", with: "\r").replacingOccurrences(of: "\\c", with: ","))
            } else {
                log("terminal: no running terminal tab")
            }
        case "perform":
            model.perform(argument)
        case "key":
            press(argument)
        case "editor-key":
            // `editor-key:<key>` (named as for `key:`): one press handed straight to the current
            // tab's editor, as if it had the keyboard, so Runlet can stay in the background
            // (#60: Escape closes a completion list first, then may hide the output pane).
            guard let textView = model.selectedTab?.editor.textView, let (code, flags) = keySpec(argument),
                  let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: true) else { return true }
            event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            textView.window?.makeFirstResponder(textView)
            // A background window's text input context is inactive and would drop the key.
            textView.inputContext?.activate()
            NSEvent(cgEvent: event).map { textView.keyDown(with: $0) }
            log("editor-key \(argument): output pane \(model.isOutputPaneShown(for: model.selectedTab) ? "shown" : "hidden")")
        case "type":
            for character in argument { key(code(for: character) ?? 0, text: String(character)) }
        case "state":
            log(state(model))
        case "sql-cancel-state":
            // #144: the current tab's run state, its Run Log lines about the database session and
            // Stop's server cancel, and the output's last notice or warning.
            guard let tab = model.selectedTab else { return true }
            let lines = tab.runLog.filter { $0.source == "sql" || $0.source == "cancel" }.map { "[\($0.source)] \($0.message)" }
            let last = tab.output.last { if case .notice = $0 { true } else if case .warning = $0 { true } else { false } }
            let note: String = switch last {
            case .notice(_, let text)?, .warning(_, let text)?: text
            default: "none"
            }
            let errors = tab.output.compactMap { item -> String? in
                guard case .error(_, let error, _) = item else { return nil }
                return error.interruptedByStop == true ? "grey:" + SQLCancel.interruptedText(error) : "card:" + error.message
            }
            log("sql-cancel-state: state=\(tab.runState) log=\(lines) errors=\(errors) note=\(note)")
        case "snippet-messages-state":
            // #196: the current tab's \Runlet\notice(), warning(), and error() cards as the output
            // reads them (level, editor line, text), its error cards, the run's status, and the footer.
            guard let tab = model.selectedTab else { return true }
            let cards = tab.output.compactMap { item -> String? in
                guard case .snippetMessage(_, let message, let line) = item else { return nil }
                return "\(message.level.rawValue)@\(line.map(String.init) ?? message.file ?? "?"): \(message.text)" + (message.context != nil ? " +context" : "") + (message.exception?.trace?.isEmpty == false ? " +trace" : "")
            }
            let errors = tab.output.filter { if case .error = $0 { true } else { false } }.count
            let status: String = if case .finished(let info) = tab.runState { "\(info.status.rawValue)/\(info.reason)" } else { "\(tab.runState)" }
            log("snippet-messages-state: status=\(status) errorCards=\(errors) footer=\(tab.finishedMessageCounts.footer ?? "none") cards=\(cards)")
        case "editor-scroll":
            // #78: the loaded editors' horizontal scroll offset from their leading edge.
            log(editorScroll(model))
        case "open":
            AppDelegate.open(URL(fileURLWithPath: argument))
        case "write", "replace":
            let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return true }
            let text = parts[1].replacingOccurrences(of: "\\n", with: "\n")
            if name == "replace" {
                try? Data(text.utf8).write(to: URL(fileURLWithPath: parts[0]), options: .atomic)
            } else if let handle = FileHandle(forWritingAtPath: parts[0]) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                handle.closeFile()
            }
        case "remove":
            try? FileManager.default.removeItem(atPath: argument)
        case "auto-run":
            model.selectedTab?.setAutoRunEnabled(argument == "on")
        case "edit":
            model.selectedTab?.editor.insert(argument.replacingOccurrences(of: "\\n", with: "\n"))
        case "search":
            let parts = argument.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2,
                  let field = views(of: FocusableSearchField.self, in: mainWindow()?.contentView)
                    .first(where: { $0.accessibilityIdentifier() == parts[0] }) else {
                log("search field not found: \(argument)")
                return true
            }
            field.stringValue = parts[1]
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        case "press":
            if !NSApp.windows.filter(\.isVisible).contains(where: { pressAccessibility(argument, in: $0) }) {
                log("accessibility press unavailable: \(argument)")
            }
        case "click":
            click(argument)
        case "settings-tab":
            // `settings-tab:<name>` picks a Settings tab (its toolbar item), e.g. `settings-tab:PHP`.
            let items = NSApp.windows.compactMap(\.toolbar).flatMap(\.items)
            if let item = items.first(where: { $0.label == argument }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            } else {
                log("settings tab \(argument) not found among \(items.map(\.label))")
            }
        case "mcp":
            model.setMCPServerEnabled(argument != "off")
            log("mcp listening=\(model.mcp.isListening) socket=\(model.mcpSocketPath) error=\(model.mcp.listenerError ?? "none")")
        case "mcp-state":
            let connections = model.mcp.connections.map { "\($0.displayName)\($0.sandboxAllowed ? "(sandbox allowed)" : "")" }
            log("mcp presented=\(model.mcp.presented.map { "\($0.clientName) → \($0.targetName)" } ?? "none") waiting=\(model.mcp.queue.count) connections=\(connections)")
        case "mcp-approve", "mcp-decline":
            guard let request = model.mcp.presented else {
                log("\(name): no approval sheet")
                return true
            }
            if name == "mcp-decline" {
                model.declineMCPRun(request)
            } else {
                model.approveMCPRun(request, allowSession: argument == "session")
            }
        case "flame":
            // `flame:hover:<frame>`, `flame:zoom:<frame>`, `flame:search:<text>`, `flame:reset`.
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            NotificationCenter.default.post(name: .flameGraphDebugAction, object: nil, userInfo: ["action": parts.first ?? "", "argument": parts.count > 1 ? parts[1] : ""])
        case "docker-test":
            NotificationCenter.default.post(name: .debugDockerTestConnection, object: nil)
        case "browse":
            NotificationCenter.default.post(name: .debugRemoteBrowser, object: nil, userInfo: ["argument": argument])
        case "editor-check":
            EditorDebugCheck.run()
        case "app-info":
            // As a click on the framework chip: `app-info` (status bar) or `app-info:card`;
            // `app-info:off` closes the popover.
            if let tab = model.selectedTab {
                let info: [String: Any] = argument == "off" ? ["close": true] : ["anchor": argument.isEmpty ? "status" : argument]
                NotificationCenter.default.post(name: .appInfoRequested, object: tab.id, userInfo: info)
            }
        case "app-info-state":
            if let tab = model.selectedTab {
                let state = model.appInfoState(for: tab.target)
                let report = state.report
                log("app-info \(state.isLoading ? "loading" : state.hasResult ? "loaded" : "idle") sections=\(report?.sections.map(\.title) ?? []) redacted=\(report?.redactedCount ?? 0) errors=\(report?.errors.map(\.message) ?? []) pending-confirmation=\(model.productionGuard.pending?.action == .appInfo)")
            }
        case "notifications":
            // `notifications:<state>` (#26): what the logging notifier says macOS allows.
            guard let logging = model.runNotifier as? LoggingRunNotifier else {
                log("notifications: not the logging notifier")
                return true
            }
            logging.setAuthorization(LoggingRunNotifier.authorization(named: argument))
            model.refreshNotificationAuthorization()
        case "notification-click":
            // As a click on the last logged run notification (#26).
            guard let logging = model.runNotifier as? LoggingRunNotifier else {
                log("notification-click: not the logging notifier")
                return true
            }
            guard let last = logging.last else {
                log("notification-click: nothing was posted")
                return true
            }
            model.openRunNotification(last.destination)
            log("notification-click: window=\(model.activeWindowId == last.destination.windowId ? "same" : "other") tab=\(model.selectedTab?.title ?? "none") selected=\(model.selectedTabId == last.destination.tabId)")
        case "notification-state":
            let last = (model.runNotifier as? LoggingRunNotifier)?.last
            log("notification-state: enabled=\(model.settings.notifyLongRuns) after=\(model.settings.longRunNotificationSeconds)s permission=\(model.notificationAuthorization.map { "\($0)" } ?? "unread") last=\(last.map { "\($0.title) | \($0.body)" } ?? "none") active=\(NSApp.isActive)")
        case "dock":
            // `dock` lists the Dock menu; `dock:<n>` chooses its nth item.
            let menu = DockMenu.make(model: model)
            log("dock menu: \(menu?.items.map(\.title) ?? [])")
            if let index = Int(argument), let menu, menu.items.indices.contains(index) { menu.performActionForItem(at: index) }
        default:
            // Saved database connections (#138), the SQL parameters drawer (#168), then
            // parameterised snippets' input form (#14).
            if DatabaseDebugSteps.run(name, argument, model: model) { return true }
            if ConnectionDebugSteps.run(name, argument, model: model) { return true }
            if SQLParameterDebugSteps.run(name, argument, model: model) { return true }
            if SQLExplainDebugSteps.run(name, argument, model: model) { return true }
            if SQLPagingDebugSteps.run(name, argument, model: model) { return true }
            if DatabaseServerDebugSteps.run(name, argument, model: model) { return true }
            if TablePlusDebugSteps.run(name, argument, model: model) { return true }
            if RelationsDebugSteps.run(name, argument, model: model) { return true }
            return SnippetInputDebugSteps.run(name, argument, model: model)
        }
        return true
    }

    /// The editor window screenshots are taken of: the active document window, never a panel or sheet.
    private static func mainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && $0.sheetParent == nil && !($0 is NSPanel) }
        return candidates.first { $0.isMainWindow } ?? candidates.first
    }

    /// A visible window by title (Settings is titled after its current tab, e.g. "PHP").
    private static func window(titled title: String) -> NSWindow? {
        // `\c` is a comma, which would end the step (a result window's "2,600 rows"); a title
        // ending in `*` matches by its start (a title with numbers in the Mac's format).
        let title = title.replacingOccurrences(of: "\\c", with: ",")
        let window = title.hasSuffix("*")
            ? NSApp.windows.first { $0.isVisible && $0.title.hasPrefix(String(title.dropLast())) }
            : NSApp.windows.first { $0.isVisible && $0.title == title }
        if window == nil { log("no window titled \(title)") }
        return window
    }

    /// Splits `<title><separator><rest>` (or `<rest><separator><title>`); no title without the separator.
    private static func titled(_ argument: String, _ separator: Character, titleFirst: Bool = true) -> (title: String?, rest: String) {
        let parts = argument.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return (nil, argument) }
        return titleFirst ? (parts[0], parts[1]) : (parts[1], parts[0])
    }

    private static var ghostTimer: Timer?
    /// Whether `ghost` keeps Runlet invisible (approval sheets then don't activate the app).
    static var isGhosted: Bool { ghostTimer != nil }
    /// Seconds `mcp-wait` has waited so far.
    static var mcpWaited = 0.0
    /// How long `db-wait` (#138) has waited.
    static var dbWaited = 0.0
    /// Minimum pixels per point for `shot` (`scale:<n>`); the window's own scale when higher.
    private static var shotScale: CGFloat = 1

    /// Keeps every Runlet window transparent and click-through (re-applied to windows that open
    /// later), so screenshot runs don't cover the screen. Views still draw for `shot`.
    private static func ghost(_ on: Bool) {
        ghostTimer?.invalidate()
        ghostTimer = nil
        applyGhost(on)
        // No Dock icon or menu bar while ghosted (nothing to click or quit by mistake).
        NSApp.setActivationPolicy(on ? .accessory : .regular)
        // A launch with `open -g -j` starts hidden; show the (now invisible) windows without
        // activating Runlet, so the user's frontmost app keeps the keyboard.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if on {
            let timer = Timer(timeInterval: 0.03, repeats: true) { _ in MainActor.assumeIsolated { applyGhost(true) } }
            RunLoop.main.add(timer, forMode: .common)
            ghostTimer = timer
        }
    }

    private static func applyGhost(_ on: Bool) {
        for window in NSApp.windows {
            window.alphaValue = on ? 0 : 1
            window.ignoresMouseEvents = on
            // Completion and info popups hide while Runlet is in the background.
            if on, let popup = window as? PopupPanel { popup.hidesOnDeactivate = false }
        }
    }

    /// Renders the main window, then its sheets and child windows (palette, completion and info
    /// popups) at their positions, into `<name>.png` in RUNLET_SNAPSHOT_DIR. Like
    /// `WindowSnapshots`, it uses AppKit drawing: no Screen Recording permission, nothing
    /// outside Runlet. Window corners and shadows are left to whatever shows the image;
    /// overlays get a rounded backing and a soft shadow, since their materials are composited
    /// by the window server and don't draw here. Web views and terminals are drawn on their own
    /// (see below), and the window buttons in their active colors.
    private static func shot(_ name: String, window: NSWindow? = nil) {
        guard let main = window ?? mainWindow() else { return log("shot: no window") }
        let scale = max(main.backingScaleFactor, shotScale)
        // Web views (mail and HTML previews) don't draw through cacheDisplay at another scale:
        // ask WebKit for their pictures first, then compose.
        let webViews = views(of: WKWebView.self, in: main.contentView).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
        guard !webViews.isEmpty else { return compose(name, main: main, scale: scale, web: []) }
        var pictures: [(image: CGImage, frame: CGRect, visible: CGRect)] = []
        var pending = webViews.count
        for webView in webViews {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width * scale / main.backingScaleFactor))
            let frame = webView.convert(webView.bounds, to: nil)
            let visible = webView.convert(webView.visibleRect, to: nil)
            webView.takeSnapshot(with: configuration) { image, _ in
                MainActor.assumeIsolated {
                    if let image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) { pictures.append((image, frame, visible)) }
                    pending -= 1
                    if pending == 0 { compose(name, main: main, scale: scale, web: pictures) }
                }
            }
        }
    }

    private static func compose(_ name: String, main: NSWindow, scale: CGFloat, web: [(image: CGImage, frame: CGRect, visible: CGRect)]) {
        guard let directory = WindowSnapshots.directory else { return log("shot: no RUNLET_SNAPSHOT_DIR") }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = main.frame.size
        let dark = main.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        var overlays: [NSWindow] = []
        var sheet = main.attachedSheet
        while let current = sheet {
            overlays.append(current)
            sheet = current.attachedSheet
        }
        overlays += (main.childWindows ?? []).sorted { $0.level.rawValue < $1.level.rawValue }
        // A popover (App Info, #19) draws its content on a card of its own: its glass frame and
        // arrow don't draw through cacheDisplay. The image grows to hold an overlay that reaches
        // past the main window, as a popover at its edge does.
        func isPopover(_ window: NSWindow) -> Bool { String(describing: type(of: window)).contains("Popover") }
        func drawnFrame(_ window: NSWindow) -> CGRect {
            guard isPopover(window), let content = window.contentView else { return window.frame }
            return window.convertToScreen(content.convert(content.bounds, to: nil))
        }
        let canvas = overlays.reduce(main.frame) { $0.union(drawnFrame($1)) }
        let offset = CGPoint(x: main.frame.minX - canvas.minX, y: main.frame.minY - canvas.minY)
        guard let context = CGContext(data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: offset.x, y: offset.y)
        for window in [main] + overlays {
            guard let view = isPopover(window) ? window.contentView : window.contentView?.superview ?? window.contentView, view.bounds.width > 1, view.bounds.height > 1,
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = view.bounds.size
            // Behind-window materials are blended by the window server and draw as flat gray
            // here; blend them within the window instead while drawing.
            let effects = window === main ? [] : visualEffectViews(in: view).filter { $0.blendingMode == .behindWindow }
            effects.forEach { $0.blendingMode = .withinWindow }
            view.cacheDisplay(in: view.bounds, to: rep)
            effects.forEach { $0.blendingMode = .behindWindow }
            guard let image = rep.cgImage else { continue }
            let frame = drawnFrame(window)
            let rect = window === main ? CGRect(origin: .zero, size: size)
                : CGRect(x: frame.minX - main.frame.minX, y: frame.minY - main.frame.minY, width: frame.width, height: frame.height)
            context.saveGState()
            if window !== main {
                let radius = isPopover(window) ? 14 : window.isOpaque ? 16 : (window.contentView?.layer?.cornerRadius ?? 10)
                let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                context.setShadow(offset: CGSize(width: 0, height: -6), blur: 28, color: NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28).cgColor)
                context.addPath(path)
                context.setFillColor(dark ? NSColor(white: 0.17, alpha: 1).cgColor : NSColor(white: 0.985, alpha: 1).cgColor)
                context.fillPath()
                context.setShadow(offset: .zero, blur: 0, color: nil)
                context.addPath(path)
                context.clip()
            }
            context.draw(image, in: rect)
            context.restoreGState()
            if window === main {
                // Runlet stays in the background, so its window draws inactive: give the close,
                // minimize, and zoom buttons their active colors, as on a window in use (muted
                // while a sheet dims the window).
                let alpha: CGFloat = main.attachedSheet == nil ? 1 : 0.6
                let buttons: [(NSWindow.ButtonType, NSColor)] = [
                    (.closeButton, NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: alpha)),
                    (.miniaturizeButton, NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: alpha)),
                    (.zoomButton, NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: alpha)),
                ]
                // Paint over the inactive buttons with the title bar's own color (sampled just
                // right of them) first.
                let frames = buttons.compactMap { main.standardWindowButton($0.0) }.filter { !$0.isHiddenOrHasHiddenAncestor }.map { $0.convert($0.bounds, to: nil) }
                if let group = frames.dropFirst().reduce(frames.first, { $0?.union($1) }),
                   let backdrop = context.makeImage()?.cropping(to: CGRect(x: (group.maxX + 6 + offset.x) * scale, y: (canvas.height - group.midY - offset.y) * scale, width: 1, height: 1)) {
                    context.draw(backdrop, in: group.insetBy(dx: -4, dy: -4))
                }
                for (kind, color) in buttons {
                    guard let button = main.standardWindowButton(kind), !button.isHiddenOrHasHiddenAncestor else { continue }
                    let frame = button.convert(button.bounds, to: nil)
                    let diameter = min(frame.width, frame.height)
                    let circle = CGRect(x: frame.midX - diameter / 2, y: frame.midY - diameter / 2, width: diameter, height: diameter)
                    context.setFillColor(color.cgColor)
                    context.fillEllipse(in: circle)
                    context.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
                    context.setLineWidth(0.5)
                    context.strokeEllipse(in: circle.insetBy(dx: 0.25, dy: 0.25))
                }
                for picture in web {
                    context.saveGState()
                    context.clip(to: picture.visible)
                    context.draw(picture.image, in: picture.frame)
                    context.restoreGState()
                }
                // SwiftTerm draws glyphs with the context's text matrix, which earlier views in
                // the same pass leave flipped: draw terminals again in a context of their own.
                for terminal in views(of: RunletTerminalView.self, in: view) where !terminal.isHiddenOrHasHiddenAncestor && !terminal.visibleRect.isEmpty {
                    guard let own = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(terminal.bounds.width * scale), pixelsHigh: Int(terminal.bounds.height * scale),
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                    else { continue }
                    own.size = terminal.bounds.size
                    terminal.cacheDisplay(in: terminal.bounds, to: own)
                    guard let picture = own.cgImage else { continue }
                    context.saveGState()
                    context.clip(to: terminal.convert(terminal.visibleRect, to: nil))
                    context.draw(picture, in: terminal.convert(terminal.bounds, to: nil))
                    context.restoreGState()
                }
            }
        }
        guard let output = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: output)
        let url = directory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".png")
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            log("shot \(url.lastPathComponent) \(output.width)x\(output.height) active=\(NSApp.isActive) key=\(main.isKeyWindow) web=\(web.count) overlays=\(overlays.map { String(describing: type(of: $0)) })")
        } catch {
            log("shot failed: \(error)")
        }
    }

    private static func segmentedControls(in view: NSView?) -> [NSSegmentedControl] {
        views(of: NSSegmentedControl.self, in: view)
    }

    private static func visualEffectViews(in view: NSView) -> [NSVisualEffectView] {
        views(of: NSVisualEffectView.self, in: view)
    }

    private static func views<V: NSView>(of type: V.Type, in view: NSView?) -> [V] {
        guard let view else { return [] }
        let own: [V] = (view as? V).map { [$0] } ?? []
        return own + view.subviews.flatMap { views(of: type, in: $0) }
    }

    /// Clicks the element with this accessibility identifier in the frontmost window that has it.
    private static func click(_ identifier: String) {
        let windows = NSApp.orderedWindows.filter(\.isVisible)
        guard let (window, frame) = windows.lazy.compactMap({ window in accessibilityFrame(of: identifier, in: window).map { (window, $0) } }).first else {
            return log("\(identifier) not found")
        }
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Scrolls the element with this accessibility identifier (a sheet's first) to the middle of
    /// the innermost scroll view that holds it.
    private static func scroll(to identifier: String) {
        let windows = NSApp.windows.filter(\.isVisible).sorted { ($0.sheetParent != nil ? 0 : 1) < ($1.sheetParent != nil ? 0 : 1) }
        guard let (window, frame) = windows.lazy.compactMap({ window in accessibilityFrame(of: identifier, in: window).map { (window, $0) } }).first else {
            return log("\(identifier) not found")
        }
        let rect = window.convertFromScreen(frame)
        let scrollViews = views(of: NSScrollView.self, in: window.contentView?.superview ?? window.contentView)
        guard let scrollView = scrollViews.last(where: { scroll in
            guard let document = scroll.documentView else { return false }
            return document.frame.contains(scroll.contentView.convert(NSPoint(x: rect.midX, y: rect.midY), from: nil))
        }), let document = scrollView.documentView else { return log("no scroll view holds \(identifier)") }
        let clip = scrollView.contentView
        let target = clip.convert(rect, from: nil)
        var origin = clip.bounds.origin
        origin.y = min(max(target.midY - clip.bounds.height / 2, document.frame.minY), max(document.frame.minY, document.frame.maxY - clip.bounds.height))
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// #52: a native accessibility action for screenshots while the app is ghosted.
    private static func pressAccessibility(_ identifier: String, in element: AnyObject, depth: Int = 0) -> Bool {
        guard depth < 40 else { return false }
        if element.accessibilityIdentifier?() == identifier { return element.accessibilityPerformPress?() ?? false }
        return (element.accessibilityChildren?() ?? []).contains { pressAccessibility(identifier, in: $0 as AnyObject, depth: depth + 1) }
    }

    private static func accessibilityFrame(of identifier: String, in element: AnyObject, depth: Int = 0) -> NSRect? {
        guard depth < 40 else { return nil }
        if element.accessibilityIdentifier?() == identifier { return element.accessibilityFrame?() }
        for child in element.accessibilityChildren?() ?? [] {
            if let frame = accessibilityFrame(of: identifier, in: child as AnyObject, depth: depth + 1) { return frame }
        }
        return nil
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }

    /// `table-filter`, `table-sort`, and `table-state` (#162) on the output's last table grid.
    private static func outputTable(_ step: String, _ argument: String) {
        guard let root = mainWindow()?.contentView,
              let table = views(of: NSTableView.self, in: root).last(where: { $0.accessibilityIdentifier() == "value-table-grid" }) else {
            return log("\(step): no table in the output")
        }
        switch step {
        case "table-filter":
            // The filter beside it, as typing would change it.
            guard let field = views(of: NSTextField.self, in: root).last(where: { $0.placeholderString == "Filter rows" }) else {
                return log("table-filter: no filter field")
            }
            field.stringValue = argument
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        case "table-sort":
            let (name, ascending) = argument.hasSuffix(":desc") ? (String(argument.dropLast(5)), false) : (argument, true)
            guard let column = table.tableColumns.first(where: { $0.title == name }) else { return log("table-sort: no column \(name)") }
            table.sortDescriptors = [NSSortDescriptor(key: column.identifier.rawValue, ascending: ascending)]
        default:
            let columns = table.tableColumns.map(\.title)
            let firstRows = (0..<min(3, table.numberOfRows)).map { row in
                (0..<min(4, table.numberOfColumns)).map { column in
                    (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue ?? "?"
                }.joined(separator: " ")
            }
            log("table-state: \(table.numberOfRows) rows, columns \(columns.prefix(6).joined(separator: ",")), first rows [\(firstRows.joined(separator: " | "))]")
        }
    }

    /// `scroll-check` (#162): scrolls the main window's tallest scrollable list (a scroll view
    /// whose document isn't a text view, such as the output or a result table) from its top to
    /// its bottom, `step` points at a time, laying out and drawing the window after each step as
    /// a scroll-wheel frame would. Prints `RUNLET_DEBUG_SCROLL: steps= total= avg= max= slow=`
    /// (ms; `slow` counts steps over one 60 Hz frame).
    private static func scrollCheck(step: CGFloat) {
        guard let window = mainWindow(), let root = window.contentView?.superview ?? window.contentView else { return }
        var scrollViews: [NSScrollView] = []
        func collect(_ view: NSView) {
            if let scrollView = view as? NSScrollView { scrollViews.append(scrollView) }
            view.subviews.forEach(collect)
        }
        collect(root)
        let candidates = scrollViews.filter { scrollView in
            guard let document = scrollView.documentView, !(document is NSTextView) else { return false }
            return document.frame.height - scrollView.contentView.bounds.height > step
        }
        guard let scrollView = candidates.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scrollView.documentView else {
            return log("scroll-check: nothing to scroll")
        }
        let clip = scrollView.contentView
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        func bottom() -> CGFloat { max(0, document.frame.height - clip.bounds.height) }
        // Start at the top.
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: document.isFlipped ? 0 : bottom()))
        scrollView.reflectScrolledClipView(clip)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        var times: [TimeInterval] = []
        var travelled: CGFloat = 0
        while travelled < bottom(), times.count < 3000 {
            travelled = min(bottom(), travelled + step)
            let started = now()
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: document.isFlipped ? travelled : bottom() - travelled))
            scrollView.reflectScrolledClipView(clip)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            times.append(now() - started)
        }
        func ms(_ value: TimeInterval) -> String { String(format: "%.1f", value * 1000) }
        let total = times.reduce(0, +)
        let line = "RUNLET_DEBUG_SCROLL: steps=\(times.count) total=\(ms(total)) avg=\(ms(times.isEmpty ? 0 : total / Double(times.count))) max=\(ms(times.max() ?? 0)) slow=\(times.filter { $0 > 1.0 / 60 }.count) height=\(Int(document.frame.height)) view=\(type(of: scrollView))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// The open palette's search field gets ↩, through its delegate as the field editor sends it.
    private static func paletteReturn() {
        guard let panel = NSApp.windows.first(where: { $0 is PalettePanel && $0.isVisible }), let content = panel.contentView,
              let field = descendant(of: content, where: { $0.accessibilityIdentifier() == "palette-search" }) as? NSTextField else {
            return log("palette-return: no open palette")
        }
        _ = field.delegate?.control?(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    private static func descendant(of view: NSView, where matches: (NSView) -> Bool) -> NSView? {
        if matches(view) { return view }
        for subview in view.subviews {
            if let found = descendant(of: subview, where: matches) { return found }
        }
        return nil
    }

    /// `appearance-state`: e.g. `setting=dark saved=dark app=dark mac=light Runlet=dark PalettePanel=dark popup=dark`.
    private static func appearanceState(_ model: AppModel) -> String {
        func name(_ appearance: NSAppearance?) -> String {
            guard let appearance else { return "nil" }
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        }
        // settings.json is an envelope: {"schemaVersion": …, "data": {"appearance": …}}.
        struct Saved: Decodable {
            struct Settings: Decodable { var appearance: String? }
            var data: Settings
        }
        let saved = (try? Data(contentsOf: model.paths.settings)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }?.data.appearance ?? "none"
        let mac = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? "dark" : "light"
        let windows = NSApp.windows.filter(\.isVisible).map { window in
            let title = window is NSPanel ? String(describing: type(of: window)) : (window.title.isEmpty ? "window" : window.title)
            return "\(title.replacingOccurrences(of: " ", with: "_"))=\(name(window.effectiveAppearance))"
        }
        // A completion list or hover popup opened now: such panels follow the app's appearance.
        let popup = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10))
        return "appearance-state: setting=\(model.settings.appearance.rawValue) saved=\(saved) app=\(name(NSApp.appearance)) mac=\(mac) "
            + windows.joined(separator: " ") + " popup=\(name(popup.effectiveAppearance))"
    }

    private static func state(_ model: AppModel) -> String {
        let keyWindow = NSApp.keyWindow
        var focus = keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        if let editor = keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            focus = "field:\(field.accessibilityIdentifier())"
        } else if keyWindow?.firstResponder is CodeTextView {
            focus = "editor"
        }
        let window = model.activeWindow
        let tabs = window?.tabs.map { tab in
            let code = (tab.editorIfLoaded?.text ?? tab.code).replacingOccurrences(of: "\n", with: "\\n")
            let issue = model.diskIssue(for: tab).map { " issue=\($0)" } ?? ""
            return "\(tab.id == window?.selectedTabId ? "*" : "")\(tab.title)\(tab.isFileDirty ? "•" : "") [\(model.targetLabel(tab.target))] \"\(code.prefix(60))\"\(issue)"
        } ?? []
        let floating = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.map { "\($0.title):\($0.level.rawValue)" }
        return "key=\(keyWindow.map { $0 is PalettePanel ? "palette" : $0.title } ?? "none") focus=\(focus) inspector=\(model.showInspector ? "\(model.inspectorPane)" : "hidden") php=\(model.hasDiscoveredPHP ? "\(model.phpInstallations.count) found" : "checking") offer-runlet-php=\(model.shouldOfferRunletPHP) windows=\(floating) tabs=\(tabs)"
    }

    /// Each loaded editor in the active window (`*` the selected one): `offset` is how far the
    /// clip view is scrolled right of the leading edge (0 when column 1 sits just right of
    /// the gutter), with the clip view's origin and left inset, the ruler's thickness, and widths.
    private static func editorScroll(_ model: AppModel) -> String {
        let window = model.activeWindow
        let editors = window?.tabs.compactMap { tab in tab.editorIfLoaded.map { (tab, $0) } } ?? []
        return "editor-scroll " + editors.map { tab, editor in
            let clip = editor.scrollView.contentView
            let offset = clip.bounds.origin.x + clip.contentInsets.left
            let ruler = editor.scrollView.verticalRulerView?.ruleThickness ?? 0
            let fmt = { (value: CGFloat) in String(format: "%.1f", value) }
            return "\(tab.id == window?.selectedTabId ? "*" : "")\(tab.title)[offset=\(fmt(offset)) originX=\(fmt(clip.bounds.origin.x)) insetLeft=\(fmt(clip.contentInsets.left)) ruler=\(fmt(ruler)) clipW=\(fmt(clip.bounds.width)) textW=\(fmt(editor.textView.frame.width)) installed=\(editor.scrollView.window != nil)]"
        }.joined(separator: " ")
    }

    /// ANSI key codes 0–50, by the character they type.
    private static let keyCodes = Array("asdfhgzxcv§bqweryt123465=97-80]ou[ip\rlj'k;\\,/nm.\t `")
    private static let named: [String: UInt16] = ["return": 36, "escape": 53, "delete": 51, "tab": 48, "space": 49, "up": 126, "down": 125, "left": 123, "right": 124]

    private static func code(for character: Character) -> UInt16? {
        keyCodes.firstIndex(of: Character(character.lowercased())).map(UInt16.init)
    }

    private static func press(_ spec: String) {
        guard let (code, flags) = keySpec(spec) else { return }
        key(code, flags)
    }

    /// `[cmd+][shift+][opt+][ctrl+]name` as a key code and modifiers.
    private static func keySpec(_ spec: String) -> (UInt16, NSEvent.ModifierFlags)? {
        var parts = spec.split(separator: "+").map(String.init)
        let name = parts.popLast() ?? ""
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts {
            switch modifier {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        guard let code = named[name] ?? name.first.flatMap(code(for:)) else {
            log("unknown key \(spec)")
            return nil
        }
        return (code, flags)
    }

    /// One key press, made the way the window server makes them (see `PaletteDebugCheck`), and
    /// queued like a real one, so `NSApp.currentEvent` is that press while it is handled.
    private static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], text: String? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { continue }
            event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            if let text { event.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16)) }
            if let event = NSEvent(cgEvent: event) { NSApp.postEvent(event, atStart: false) }
        }
    }
}
#endif

#if DEBUG
extension Notification.Name {
    /// DEBUG step `docker-test`: the open Docker profile form runs Test Connection.
    static let debugDockerTestConnection = Notification.Name("RunletDebugDockerTestConnection")
}
#endif

#if DEBUG
/// Timings for one run started by the `run` step and reported by `wait-run` (#82), to measure
/// how the output keeps up with large or fast output. Prints, to stderr:
/// `wall` (ms from Run to the `finished` event applied in the tab), `runner` (the run's own
/// elapsed ms, process start to exit), `first` (ms from Run to the first output after the
/// header), `settle` (ms to lay out and draw the window afterwards), `events` (applied),
/// `items` (output cards), and the main thread's responsiveness while the run was going:
/// `frozen` (total ms of main-thread gaps over 50 ms) and `longest` (the longest gap), seen by
/// a 10 ms timer; and `lag` / `lagMax` (#162): how long work sent to the main queue waited, as
/// a click or key press would, measured from another thread with one ping in flight at a time
/// (`lag` sums the waits over 50 ms). The timer can miss a stall that SwiftUI spreads over many
/// short run-loop passes; the ping can't.
@MainActor
enum DebugRunTiming {
    private static var startedAt: TimeInterval = 0
    private static var timer: Timer?
    private static var lastTick: TimeInterval = 0
    private static var frozen: TimeInterval = 0
    private static var longest: TimeInterval = 0
    private static var lagProbe: MainQueueLagProbe?

    static func start(_ tab: TabModel) {
        tab.debugEvents = 0
        tab.debugFirstOutputAt = nil
        tab.debugFinishedAt = nil
        frozen = 0
        longest = 0
        startedAt = ProcessInfo.processInfo.systemUptime
        lastTick = startedAt
        lagProbe?.stop()
        lagProbe = MainQueueLagProbe()
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                let gap = now - lastTick
                if gap > 0.05 { frozen += gap }
                longest = max(longest, gap)
                lastTick = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Seconds since the `run` step.
    static var sinceStart: TimeInterval { ProcessInfo.processInfo.systemUptime - startedAt }

    static func report(_ tab: TabModel?) {
        timer?.invalidate()
        timer = nil
        let lag = lagProbe?.stop() ?? (blocked: 0, longest: 0)
        lagProbe = nil
        guard let tab else { return }
        let settleStart = ProcessInfo.processInfo.systemUptime
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let settle = ProcessInfo.processInfo.systemUptime - settleStart
        func ms(_ value: TimeInterval?) -> String { value.map { String(Int(($0 * 1000).rounded())) } ?? "-" }
        var runner = "-", status = tab.isRunning ? "still-running" : "-"
        if case .finished(let info) = tab.runState {
            runner = String(info.elapsedMs)
            status = info.status.rawValue + "/" + info.reason + (info.truncation != nil ? "/truncated" : "")
        }
        let line = "RUNLET_DEBUG_TIMING: status=\(status) wall=\(ms(tab.debugFinishedAt.map { $0 - startedAt })) runner=\(runner) first=\(ms(tab.debugFirstOutputAt.map { $0 - startedAt })) settle=\(ms(settle)) events=\(tab.debugEvents) items=\(tab.output.count) frozen=\(ms(frozen)) longest=\(ms(longest)) lag=\(ms(lag.blocked)) lagMax=\(ms(lag.longest)) text=\(tab.rawOutput.utf8.count) after=\(ms(sinceStart))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// Pings the main queue from a thread of its own, one ping at a time, and keeps how long the
/// pings waited (#162): what a click or key press would have waited for the main thread.
final class MainQueueLagProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var blocked: TimeInterval = 0
    private var longest: TimeInterval = 0

    init() {
        let thread = Thread { [self] in
            let answered = DispatchSemaphore(value: 0)
            while isRunning {
                let sent = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let waited = ProcessInfo.processInfo.systemUptime - sent
                lock.lock()
                if waited > 0.05 { blocked += waited }
                longest = max(longest, waited)
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Stops pinging; returns the total wait over 50 ms per ping, and the longest wait.
    @discardableResult
    func stop() -> (blocked: TimeInterval, longest: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        running = false
        return (blocked, longest)
    }
}
#endif
