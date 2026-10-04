import AppKit
import RunletCore
import SwiftUI

/// The Library's Database pane for a Redis tab (#190): the key browser and the server panel of
/// the tab's target and Redis connection. Nothing loads by itself: Scan, Memory Usage, Open
/// Value, and Read Server Details read when pressed, and production asks first.
struct RedisDatabasePane: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        let choice = model.sqlConnectionChoice(for: tab)
        VStack(alignment: .leading, spacing: 0) {
            header(choice)
            sectionPicker
            Divider()
            if case .missing(let name) = choice {
                ContentUnavailableView("Missing connection", systemImage: "exclamationmark.triangle", description: Text(SQLConnectionChoice.missingMessage(name)))
            } else if let key = model.redisPaneKey(for: tab) {
                if model.databaseServer.section == .server {
                    RedisServerPanel(tab: tab, state: model.redisUI.server(key))
                } else {
                    RedisKeyBrowser(tab: tab, state: model.redisUI.browser(key))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: valueBinding) { sheet in
            RedisValueSheetView(sheet: sheet, tabTitle: tab.title)
        }
        .sheet(item: killBinding) { confirmation in
            RedisKillSheet(confirmation: confirmation)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("redis-database-pane")
    }

    private var valueBinding: Binding<RedisValueSheet?> {
        Binding(get: { model.redisUI.value?.tabId == tab.id ? model.redisUI.value : nil }, set: { if $0 == nil { model.redisUI.value = nil } })
    }

    private var killBinding: Binding<RedisKillConfirmation?> {
        Binding(get: { model.redisUI.kill?.tabId == tab.id ? model.redisUI.kill : nil }, set: { if $0 == nil { model.cancelKillRedisClient() } })
    }

    private func header(_ choice: SQLConnectionChoice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.targetLabel(tab.target)).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(choice.label.prefix(1).uppercased() + choice.label.dropFirst() + (choice.savedConnection.map { " · \($0.summary)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let saved = choice.savedConnection { SavedConnectionBadges(connection: saved) }
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var sectionPicker: some View {
        @Bindable var store = model.databaseServer
        return Picker("Show", selection: $store.section) {
            Text("Keys").tag(DatabasePaneSection.tables)
            Text("Server").tag(DatabasePaneSection.server)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .help("Keys: SCAN the database with a pattern. Server: INFO and the connected clients.")
        .accessibilityIdentifier("redis-pane-section")
    }
}

/// The key browser (#190): a database picker, a pattern, and a type; SCAN pages (never KEYS)
/// with each key's type and TTL; Memory Usage, Open Value, Copy Key, and Insert Command.
struct RedisKeyBrowser: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable var state: RedisKeyBrowserState
    @State private var selection: String?

    static let types = ["string", "hash", "list", "set", "zset", "stream"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Database", selection: $state.db) {
                    ForEach(state.databaseNumbers, id: \.self) { db in
                        Text(state.keyCount(db: db).map { "db\(db) · \($0.formatted())" } ?? "db\(db)").tag(db)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .help("The database to scan (SELECT)")
                .accessibilityIdentifier("redis-db")
                TextField("Pattern", text: $state.pattern, prompt: Text("*"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.scanRedisKeys(tab) }
                    .help("SCAN's MATCH pattern: * any characters, ? one, [ab] a set")
                    .accessibilityIdentifier("redis-pattern")
                Picker("Type", selection: $state.type) {
                    Text("Any type").tag(String?.none)
                    ForEach(Self.types, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .frame(width: 92)
                .accessibilityIdentifier("redis-type")
            }
            HStack(spacing: 8) {
                Button {
                    model.scanRedisKeys(tab)
                } label: {
                    Label(state.next == nil ? "Scan" : "Scan Again", systemImage: "magnifyingglass")
                }
                .controlSize(.small)
                .disabled(state.loading)
                .keyboardShortcut(.return, modifiers: .command)
                .help("SCAN the database for keys matching the pattern, 200 at a time, with each key's type and TTL. Never KEYS. Production asks first.")
                .accessibilityIdentifier("redis-scan")
                if state.loading {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.stopRedisScan(tab) }.controlSize(.small)
                } else if let next = state.next, next != "0" {
                    Button {
                        model.scanRedisKeys(tab, more: true)
                    } label: {
                        Label("Load More", systemImage: "arrow.down.to.line")
                    }
                    .controlSize(.small)
                    .help("Continue the scan from cursor \(next)")
                    .accessibilityIdentifier("redis-scan-more")
                }
                Spacer()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("redis-scan-status")
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if state.next == nil, !state.loading {
                Text("Scan reads keys with SCAN and a pattern, never KEYS, so a large database isn't blocked. Each page brings 200 keys' names with their type and TTL; nothing else is read until you ask.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } else if state.keys.isEmpty, !state.loading {
                Text(state.next == "0" ? "No keys match." : "No keys in these pages yet. Load More continues the scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List(state.keys, selection: $selection) { entry in
                row(entry)
                    .tag(entry.raw)
                    .contextMenu { menu(entry) }
            }
            .listStyle(.inset)
            .frame(minHeight: 120)
            .accessibilityIdentifier("redis-keys")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .onChange(of: state.db) { _, _ in
            // Another database: the keys listed belong to the last one.
            state.keys = []
            state.next = nil
            state.details = [:]
        }
    }

    private var status: String {
        guard let scanned = state.scanned else { return "" }
        let count = "\(state.keys.count.formatted()) key\(state.keys.count == 1 ? "" : "s")"
        let complete = state.next == "0" ? "scan complete" : "\(state.pages) page\(state.pages == 1 ? "" : "s"), more to scan"
        return "\(count) · \(complete) · \(scanned)"
    }

    private func row(_ entry: RedisKeyEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                RedisTypeBadge(type: entry.type)
                Text(entry.displayName)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(entry.ttlText)
                    .font(.caption)
                    .foregroundStyle(entry.ttl == -1 ? .secondary : Color.orange)
                    .help(entry.ttl == -1 ? "No expiry" : "Time to live")
            }
            if let details = state.details[entry.raw] {
                Text(details.summary + (details.memoryError.map { " · MEMORY USAGE: \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("redis-key-details")
            } else if state.detailLoading.contains(entry.raw) {
                Text("Reading memory usage…").font(.caption).foregroundStyle(.secondary)
            } else if let error = state.detailErrors[entry.raw] {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.openRedisValue(tab, key: entry) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("redis-key-\(entry.displayName)")
    }

    @ViewBuilder
    private func menu(_ entry: RedisKeyEntry) -> some View {
        Button("Open Value") { model.openRedisValue(tab, key: entry) }
        Button("Memory Usage") { model.loadRedisKeyDetails(tab, key: entry) }
        Divider()
        Button("Copy Key") { Pasteboard.copy(entry.displayName) }
        Button("Insert Command") { model.insertRedisCommand(tab, key: entry) }
            .help("Puts \(entry.readCommand) in the tab, on its own line. Runs nothing.")
    }
}

/// A key's type as a small coloured label.
struct RedisTypeBadge: View {
    let type: String?

    var body: some View {
        Text(type ?? "?")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .frame(minWidth: 40)
            .foregroundStyle(color)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.12)))
    }

    private var color: Color {
        switch type {
        case "string": .blue
        case "hash": .purple
        case "list": .orange
        case "set": .green
        case "zset": .pink
        case "stream": .teal
        default: .gray
        }
    }
}

/// Open Value's sheet (#190): the key's value as a Redis reply card.
struct RedisValueSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sheet: RedisValueSheet
    var tabTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RedisTypeBadge(type: sheet.key.type)
                Text(sheet.key.displayName).font(.system(.headline, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Text("db\(sheet.db) · \(sheet.key.ttlText)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(14)
            Divider()
            ScrollView {
                Group {
                    if let reply = sheet.reply {
                        RedisReplyCard(reply: reply, tabTitle: tabTitle)
                    } else if let error = sheet.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading the value…").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Insert Command") {
                    if let tab = model.allTabs.first(where: { $0.id == sheet.tabId }) { model.insertRedisCommand(tab, key: sheet.key) }
                    dismiss()
                }
                Button("Copy Key") { Pasteboard.copy(sheet.key.displayName) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
        .accessibilityIdentifier("redis-value-sheet")
    }
}

/// The server panel (#190): INFO's summary and sections, and CLIENT LIST with Kill Client.
struct RedisServerPanel: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable var state: RedisServerState
    @State private var expanded: Set<String> = ["Server", "Clients", "Memory", "Keyspace"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    model.loadRedisServer(tab)
                } label: {
                    Label(state.report == nil ? "Read Server Details" : "Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(state.loading)
                .help("Reads INFO and CLIENT LIST on the tab's connection. Nothing changes. Production asks first.")
                .accessibilityIdentifier("redis-server-read")
                if state.loading { ProgressView().controlSize(.small) }
                Spacer()
                if let date = state.readAt {
                    Text("Read \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let kill = state.lastKill {
                Label(kill.detail, systemImage: kill.outcome == .killed ? "checkmark.circle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(kill.outcome == .failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("redis-kill-outcome")
            }
            if let report = state.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(report.summary).font(.callout.weight(.semibold)).textSelection(.enabled).accessibilityIdentifier("redis-server-summary")
                        clients(report)
                        ForEach(report.sections) { section in
                            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(section.name) }, set: { if $0 { expanded.insert(section.name) } else { expanded.remove(section.name) } })) {
                                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                                    ForEach(section.items, id: \.self) { item in
                                        GridRow {
                                            Text(item.key).font(.caption).foregroundStyle(.secondary)
                                            Text(item.value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        }
                                    }
                                }
                                .padding(.leading, 4)
                            } label: {
                                Text(section.name).font(.callout.weight(.semibold))
                            }
                        }
                        if let error = report.infoError { Text("INFO: \(error)").font(.caption).foregroundStyle(.red) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !state.loading {
                Text("Read Server Details shows the server's version, memory, keyspace, and the connected clients (INFO and CLIENT LIST), read when you press it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .accessibilityIdentifier("redis-server-panel")
    }

    @ViewBuilder
    private func clients(_ report: RedisServerReport) -> some View {
        let clients = report.clientList
        VStack(alignment: .leading, spacing: 4) {
            Text("Clients (\(clients.count))").font(.callout.weight(.semibold))
            if let error = report.clientsError {
                Text("CLIENT LIST: \(error)").font(.caption).foregroundStyle(.red)
            }
            ForEach(clients) { client in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text("#\(client.id)").font(.system(.caption, design: .monospaced).weight(.semibold))
                            Text(client.address).font(.system(.caption, design: .monospaced))
                            if !client.name.isEmpty { Text(client.name).font(.caption).foregroundStyle(.secondary) }
                            if client.id == report.ownId { Text("(this panel)").font(.caption).foregroundStyle(.secondary) }
                            if client.isBlocked { Text("blocked").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                        }
                        Text([client.user.isEmpty ? nil : "user \(client.user)", client.db.map { "db\($0)" }, client.command.isEmpty ? nil : "last \(client.command)", client.ageSeconds.map { "age \($0) s" }, client.idleSeconds.map { "idle \($0) s" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if state.killing == client.id {
                        ProgressView().controlSize(.small)
                    } else if client.id != report.ownId {
                        Button("Kill…") { model.askKillRedisClient(tab, client: client) }
                            .controlSize(.small)
                            .help("CLIENT KILL ID \(client.id): closes this client's connection. Runlet asks first, on every connection.")
                            .accessibilityIdentifier("redis-kill-\(client.id)")
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.06)))
            }
        }
    }
}

/// Kill Client's confirmation (#190): always, on every connection.
struct RedisKillSheet: View {
    @Environment(AppModel.self) private var model
    let confirmation: RedisKillConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "xmark.octagon.fill").font(.system(size: 28)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kill client \(confirmation.client.id)?").font(.headline)
                    Text("CLIENT KILL ID \(confirmation.client.id) closes its connection to Redis\(confirmation.isProduction ? ", on a production connection" : ""). A command it's running, or waiting on (BLPOP, …), ends with it. Runlet checks first that it reaches the same server and that the client is still the one listed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow { Text("Address").foregroundStyle(.secondary); Text(confirmation.client.address).font(.system(.callout, design: .monospaced)) }
                if !confirmation.client.name.isEmpty { GridRow { Text("Name").foregroundStyle(.secondary); Text(confirmation.client.name) } }
                if !confirmation.client.user.isEmpty { GridRow { Text("User").foregroundStyle(.secondary); Text(confirmation.client.user) } }
                if !confirmation.client.command.isEmpty { GridRow { Text("Last command").foregroundStyle(.secondary); Text(confirmation.client.command) } }
                GridRow { Text("Through").foregroundStyle(.secondary); Text(confirmation.connectionLabel).lineLimit(2) }
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelKillRedisClient() }
                    .keyboardShortcut(.cancelAction)
                Button("Kill Client", role: .destructive) { model.confirmKillRedisClient() }
                    .tint(.red)
                    .accessibilityIdentifier("redis-kill-confirm")
            }
        }
        .padding(20)
        .frame(width: 500)
        .accessibilityIdentifier("redis-kill-sheet")
    }
}
