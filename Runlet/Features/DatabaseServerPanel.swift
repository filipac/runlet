import AppKit
import RunletCore
import SwiftUI

/// The Database pane's Server section (#150): the server's version, uptime, and TLS; the
/// database's size and largest tables; and its sessions with Cancel Query and Kill Session.
/// Nothing reads by itself: Read Server Details (production asks first) or, off production, a
/// refresh interval the user turns on, which stops when this view hides, the tab changes, or
/// Runlet goes to the background.
struct DatabaseServerView: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let connection: SQLConnectionChoice

    var body: some View {
        let state = model.serverState(for: tab)
        Group {
            if case .missing(let name) = connection {
                ServerPlaceholder(tab: tab, connection: connection, state: nil, missing: name)
            } else if let state, let info = state.info {
                ServerDetails(tab: tab, connection: connection, state: state, info: info)
            } else {
                ServerPlaceholder(tab: tab, connection: connection, state: state, missing: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear { model.stopServerRefresh(reason: "the Server section was hidden") }
        .onChange(of: tab.id) { model.stopServerRefresh(reason: "the tab changed") }
        .onChange(of: model.serverKey(for: tab)) { model.stopServerRefresh(reason: "the connection changed") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.stopServerRefresh(reason: "Runlet went to the background")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            model.stopServerRefresh(reason: "Runlet was hidden")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("database-server")
    }
}

/// Before the first read: what Read Server Details does, and the button.
private struct ServerPlaceholder: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let connection: SQLConnectionChoice
    let state: DatabaseServerState?
    let missing: String?

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 20)
            if let missing {
                Image(systemName: "questionmark.diamond").font(.largeTitle).foregroundStyle(.orange)
                Text(SQLConnectionChoice.missingMessage(missing))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state?.isLoading == true {
                ProgressView()
                Text("Reading the server's details…").foregroundStyle(.secondary)
            } else {
                Image(systemName: state?.failure == nil ? "server.rack" : "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(state?.failure == nil ? Color.teal : Color.orange)
                if let failure = state?.failure {
                    Text("Runlet could not read the server's details").font(.headline)
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("server-error")
                } else {
                    Text("The database server").font(.headline)
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(state?.failure == nil ? "Read Server Details" : "Try Again") { model.readDatabaseServer(for: tab) }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .accessibilityIdentifier("server-read")
            }
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var explanation: String {
        let how = connection.savedConnection == nil ? "boots the application and asks its connection" : "opens the saved connection (no application code runs)"
        let production = model.serverIsProduction(for: tab) ? " This connection is production, so Runlet asks before every read." : ""
        return "See the server's version, uptime, and TLS, the database's size and largest tables, and who is connected: what each session runs, for how long, and what it waits for. Runlet \(how) and reads only the catalog and the server's status, never rows. Nothing refreshes by itself.\(production)"
    }
}

/// The report: the server, the sizes, the sessions, and the last action.
private struct ServerDetails: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let connection: SQLConnectionChoice
    let state: DatabaseServerState
    let info: SQLServerInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(readText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("server-status")
                    Spacer(minLength: 4)
                    if state.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        model.readDatabaseServer(for: tab)
                    } label: {
                        Label("Read All", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(state.isLoading)
                    .help("Read the server's details, sizes, and sessions again\(model.serverIsProduction(for: tab) ? " (production asks first)" : "")")
                    .accessibilityIdentifier("server-read-all")
                }
                if let failure = state.failure {
                    Label("The last read failed: \(failure)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let report = state.lastAction {
                    ServerActionBanner(report: report, at: state.lastActionAt)
                }
                ServerOverviewCard(info: info, error: info.error(for: .overview))
                ServerSizesCard(info: info, error: info.error(for: .sizes))
                ServerSessionsCard(tab: tab, state: state, info: info)
            }
            .padding(10)
        }
    }

    private var readText: String {
        let dates = state.readAt.values
        guard let oldest = dates.min() else { return "Not read yet" }
        let source = info.source.map { " via \($0)" } ?? ""
        return "Read \(oldest.formatted(.relative(presentation: .named)))\(source)"
    }
}

/// A titled group of the Server section.
private struct ServerCard<Trailing: View, Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.teal)
                Text(title).font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                trailing
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct PartError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ServerNotes: View {
    let notes: [String]

    var body: some View {
        ForEach(notes, id: \.self) { note in
            Label(note, systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ServerOverviewCard: View {
    let info: SQLServerInfo
    let error: String?

    var body: some View {
        ServerCard(title: "Server", symbol: "server.rack") {
            EmptyView()
        } content: {
            if let error {
                PartError(message: error)
            } else if let overview = info.overview {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    row("Version", overview.server ?? "unknown", help: overview.versionText)
                    if overview.product == "SQLite" {
                        if let file = overview.database {
                            row("File", (file as NSString).lastPathComponent, help: file)
                        }
                        if let journal = overview.journalMode { row("Journal", journal) }
                    } else {
                        if let database = overview.database { row("Database", database) }
                        if let user = overview.user { row("User", user) }
                        if let uptime = overview.uptimeSeconds { row("Uptime", SQLServerPanel.duration(Double(uptime))) }
                        if let connections = overview.connections { row("Connections", "\(connections)") }
                        if let tls = overview.tlsText {
                            GridRow {
                                Text("TLS").foregroundStyle(.secondary)
                                Label(tls, systemImage: overview.tls == true ? "lock.fill" : "lock.open")
                                    .foregroundStyle(overview.tls == true ? Color.primary : Color.orange)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(tls)
                            }
                        }
                    }
                }
                .font(.caption)
                .accessibilityIdentifier("server-overview")
            } else {
                Text("Not read yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String, help: String? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(help ?? value)
        }
    }
}

private struct ServerSizesCard: View {
    let info: SQLServerInfo
    let error: String?

    var body: some View {
        ServerCard(title: "Sizes", symbol: "chart.bar.xaxis") {
            if let sizes = info.sizes, let total = sizes.databaseBytes {
                Text(SQLServerPanel.bytes(total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } content: {
            if let error {
                PartError(message: error)
            } else if let sizes = info.sizes {
                Text(summary(sizes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !sizes.tables.isEmpty {
                    let largest = max(1, sizes.largestBytes)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sizes.tables) { table in
                            ServerTableSizeRow(table: table, largest: largest)
                        }
                    }
                    .accessibilityIdentifier("server-sizes")
                }
                ServerNotes(notes: sizes.notes ?? [])
            } else {
                Text("Not read yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ sizes: SQLServerInfo.Sizes) -> String {
        var parts: [String] = []
        if let database = sizes.database { parts.append(database) }
        if let tables = sizes.tableCount { parts.append("\(tables) table\(tables == 1 ? "" : "s")") }
        if let views = sizes.viewCount { parts.append("\(views) view\(views == 1 ? "" : "s")") }
        if let data = sizes.dataBytes, let indexes = sizes.indexBytes { parts.append("data \(SQLServerPanel.bytes(data)), indexes \(SQLServerPanel.bytes(indexes))") }
        if let free = sizes.freeBytes { parts.append("\(SQLServerPanel.bytes(free)) free") }
        let largest = sizes.tables.isEmpty ? "" : (sizes.tables.count < (sizes.tableCount ?? 0) ? " · the \(sizes.tables.count) largest:" : " · largest first:")
        return parts.joined(separator: " · ") + largest
    }
}

private struct ServerTableSizeRow: View {
    let table: SQLServerInfo.TableSize
    let largest: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(table.qualifiedName)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(table.totalBytes.map(SQLServerPanel.bytes) ?? "–")
                    .font(.caption.monospacedDigit())
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                let data = CGFloat(table.dataBytes ?? 0) / CGFloat(largest) * width
                let index = CGFloat(table.indexBytes ?? 0) / CGFloat(largest) * width
                HStack(spacing: 0) {
                    Rectangle().fill(Color.teal.opacity(0.75)).frame(width: max(0, min(width, data)))
                    Rectangle().fill(Color.purple.opacity(0.6)).frame(width: max(0, min(width - data, index)))
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .frame(height: 4)
            Text(details)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help("\(table.qualifiedName)\n\(details)")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("server-table-size")
    }

    private var details: String {
        [
            table.dataBytes.map { "data \(SQLServerPanel.bytes($0))" },
            table.indexBytes.map { "indexes \(SQLServerPanel.bytes($0))" },
            table.rows.map { "≈\(SQLServerPanel.count($0)) rows" },
            table.kind,
            table.engine,
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct ServerSessionsCard: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let state: DatabaseServerState
    let info: SQLServerInfo

    var body: some View {
        @Bindable var store = model.databaseServer
        let all = info.sessions?.list ?? []
        let shown = all.filter { $0.matches(store.sessionFilter) && (!store.hideIdle || !$0.isIdle || $0.isOwn) }
        ServerCard(title: info.sessions.map { "Sessions (\($0.list.count)\($0.truncated == true ? "+" : ""))" } ?? "Sessions", symbol: "person.2") {
            if state.loading.contains(.sessions) {
                ProgressView().controlSize(.mini)
            }
            refreshMenu
            Button {
                model.readDatabaseServer(for: tab, parts: [.sessions])
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(state.isLoading)
            .help("Read the sessions again\(model.serverIsProduction(for: tab) ? " (production asks first)" : "")")
            .accessibilityIdentifier("server-sessions-reload")
        } content: {
            if let error = info.error(for: .sessions) {
                PartError(message: error)
            } else if let sessions = info.sessions {
                if !sessions.list.isEmpty {
                    HStack(spacing: 6) {
                        TextField("Filter sessions", text: $store.sessionFilter)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .accessibilityIdentifier("server-session-filter")
                        Toggle("Hide idle", isOn: $store.hideIdle)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .fixedSize()
                    }
                }
                ServerNotes(notes: sessions.notes ?? [])
                if shown.isEmpty, !sessions.list.isEmpty {
                    Text("No session matches.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { session in
                        ServerSessionRow(tab: tab, session: session, info: info, ended: state.ended[session.id], acting: state.acting == session.id)
                        if session.id != shown.last?.id { Divider() }
                    }
                }
                .accessibilityIdentifier("server-sessions")
            } else {
                Text("Not read yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var refreshMenu: some View {
        let production = model.serverIsProduction(for: tab)
        let intervals = SQLServerPanel.refreshIntervals(isProduction: production)
        return Menu {
            Button {
                model.setServerRefresh(nil, for: tab)
            } label: {
                if state.refreshInterval == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            ForEach(intervals, id: \.self) { seconds in
                Button {
                    model.setServerRefresh(seconds, for: tab)
                } label: {
                    if state.refreshInterval == seconds { Label("Every \(seconds) s", systemImage: "checkmark") } else { Text("Every \(seconds) s") }
                }
            }
        } label: {
            Label(state.refreshInterval.map { "\($0) s" } ?? "Off", systemImage: "timer")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(production)
        .help(production
            ? "Refresh is never available on production connections: Runlet asks before every read there."
            : "Read the sessions again every few seconds (off by default). It stops when the pane hides, the tab changes, or Runlet goes to the background.")
        .accessibilityIdentifier("server-refresh")
    }
}

private struct ServerSessionRow: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let session: SQLServerInfo.Session
    let info: SQLServerInfo
    let ended: SQLServerActionReport?
    let acting: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("#\(String(session.id))")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                    Text(session.userAndHost)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if session.isOwn { badge("THIS PANEL", .teal) }
                    if let ended { badge(ended.action == .kill ? "KILLED" : "CANCELLED", .red) }
                    Spacer(minLength: 2)
                    if let seconds = session.seconds {
                        Text(SQLServerPanel.duration(seconds))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(stateLine)
                    .font(.caption2)
                    .foregroundStyle(session.blockedBy == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
                if let query = session.query {
                    Text(SQLServerPanel.oneLine(query) + (session.queryTruncated ? "…" : ""))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(session.isActive ? Color.primary : Color.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .strikethrough(ended?.action == .kill, color: .secondary)
            .opacity(ended?.action == .kill ? 0.6 : 1)
            if acting {
                ProgressView().controlSize(.mini).padding(.top, 2)
            } else {
                Menu { actions } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(session.isOwn ? "The panel's own session: never cancelled or killed" : "Copy, Cancel Query…, Kill Session…")
                    .accessibilityIdentifier("server-session-actions")
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu { actions }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("server-session-row")
    }

    @ViewBuilder private var actions: some View {
        if session.isOwn {
            Text("Session \(String(session.id)) is this panel's own: never cancelled or killed")
        }
        Button("Copy Statement") { Pasteboard.copy(session.query ?? "") }
            .disabled(session.query == nil)
        Button("Copy Session ID") { Pasteboard.copy(String(session.id)) }
        Divider()
        Button("Cancel Query…") { model.requestServerAction(.cancel, session: session, for: tab) }
            .disabled(session.isOwn || ended != nil)
        Button("Kill Session…") { model.requestServerAction(.kill, session: session, for: tab) }
            .disabled(session.isOwn || ended?.action == .kill)
    }

    private var dotColor: Color {
        if ended?.action == .kill { return .red }
        if session.blockedBy != nil || session.waiting?.hasPrefix("Lock") == true { return .orange }
        return session.isActive ? .green : Color.secondary.opacity(0.5)
    }

    private var stateLine: String {
        var parts = [session.stateText]
        if let database = session.database { parts.append(database) }
        if let application = session.application { parts.append(application) }
        if let transaction = session.transactionSeconds, transaction > 0 { parts.append("transaction \(SQLServerPanel.duration(transaction))") }
        if let waiting = session.waiting, session.blockedBy == nil { parts.append("waits on \(waiting)") }
        if let blockers = session.blockedBy { parts.append("waits for " + blockers.map { "#\($0)" }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private var helpText: String {
        var lines = ["Session \(session.id): \(session.userAndHost)", stateLine]
        if let query = session.query {
            lines.append("")
            lines.append(query + (session.queryTruncated ? "\n… (\(session.queryBytes ?? 0) bytes in all; the first 4 KB are shown)" : ""))
        }
        if let ended { lines.append("\n" + ended.message) }
        return lines.joined(separator: "\n")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(.white)
            .background(Capsule().fill(color.opacity(0.85)))
            .fixedSize()
    }
}

/// What the last Cancel Query or Kill Session did, as the server reported it.
private struct ServerActionBanner: View {
    let report: SQLServerActionReport
    let at: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(report.succeeded ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let at {
                    Text("\(SQLServerPanel.clock(at)) · in the tab's Run Log")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill((report.succeeded ? Color.green : Color.orange).opacity(0.1)))
        .accessibilityIdentifier("server-action-result")
    }
}

// MARK: - The confirmation

/// Cancel Query and Kill Session ask on the window whose pane asked, every time (#150).
struct ServerActionConfirmationModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let windowId: UUID

    func body(content: Content) -> some View {
        content.sheet(item: presented) { confirmation in
            ServerActionConfirmationView(confirmation: confirmation)
        }
    }

    private var presented: Binding<ServerActionConfirmation?> {
        Binding(
            get: {
                guard let pending = model.databaseServer.confirmation, pending.windowId == nil || pending.windowId == windowId else { return nil }
                return pending
            },
            set: { value in
                if value == nil, let pending = model.databaseServer.confirmation, pending.windowId == nil || pending.windowId == windowId {
                    model.cancelServerAction()
                }
            }
        )
    }
}

struct ServerActionConfirmationView: View {
    @Environment(AppModel.self) private var model
    let confirmation: ServerActionConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: confirmation.plan.action == .kill ? "xmark.octagon.fill" : "stop.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(confirmation.plan.action == .kill ? Color.red : Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(confirmation.title).font(.headline)
                        if confirmation.isProduction {
                            Text("PRODUCTION")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .foregroundStyle(.white)
                                .background(Capsule().fill(Color.red))
                        }
                    }
                    Text(confirmation.sessionLine)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("server-confirmation-session")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(confirmation.session.query == nil ? "Statement" : "Its statement")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(preview)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(confirmation.session.query == nil ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            Text(confirmation.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Sends \(confirmation.plan.statement)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Don't Send", role: .cancel) { model.cancelServerAction() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("server-confirmation-cancel")
                Button(confirmation.plan.action.title, role: .destructive) { model.confirmServerAction() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                    .help("⌘↩")
                    .accessibilityIdentifier("server-confirmation-confirm")
            }
        }
        .padding(20)
        .frame(width: 540)
        .onExitCommand { model.cancelServerAction() }
        .accessibilityIdentifier("server-action-confirmation")
    }

    private var preview: String {
        guard let query = confirmation.session.query else { return "(the server shows no statement for this session)" }
        let lines = query.components(separatedBy: "\n")
        let shown = lines.prefix(ProductionGrace.previewLines).joined(separator: "\n")
        return shown + (lines.count > ProductionGrace.previewLines || confirmation.session.queryTruncated ? "\n…" : "")
    }
}
