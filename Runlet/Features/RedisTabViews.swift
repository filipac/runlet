import RunletCore
import SwiftUI

/// "REDIS" capsule on a Redis tab's tab (#190).
struct RedisBadge: View {
    var body: some View {
        Text("REDIS")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.red.opacity(0.85)))
            .help("Redis tab: commands run on the application's Redis connection, or a Redis connection you saved for the target or for all targets")
            .accessibilityLabel("Redis tab")
            .accessibilityIdentifier("redis-badge")
    }
}

/// The bar above a Redis tab's editor (#190): which connection commands use, Run All, and
/// MULTI/EXEC. Choosing a connection never connects or runs anything.
struct RedisTabBar: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window: WindowModel?
    let tab: TabModel

    var body: some View {
        let choice = model.sqlConnectionChoice(for: tab)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.red)
                Text("Redis").fontWeight(.semibold)
                DatabaseConnectionButton(
                    tab: tab,
                    help: "The Redis connection the commands run on: one the application configures (Laravel's Redis::connection(), no credentials from Runlet), or one you saved (its password stays in the macOS Keychain).",
                    identifier: "redis-connection-picker",
                    newConnection: newConnection,
                    editConnections: editConnections)
                Divider().frame(height: 14)
                // #345: Run All Statements runs a Redis tab's commands.
                Button {
                    model.perform("run.sqlRunAll", source: .button, for: tab)
                } label: {
                    Label("Run All", systemImage: "play.square.stack")
                }
                .buttonStyle(.borderless)
                .disabled(tab.isRunning)
                .help(model.commandHelp("Run All", "run.sqlRunAll", detail: "every command of the selection, or of the tab, in order on one connection. Runlet stops at the first error."))
                .accessibilityIdentifier("redis-run-all")
                Toggle("In a Transaction", isOn: Binding(get: { tab.redisTransaction }, set: { model.setRedisTransaction($0, for: tab) }))
                    .toggleStyle(.checkbox)
                    .help("Run All wraps the commands in MULTI/EXEC: Redis queues them, then runs them all at once. A command Redis can't queue discards them all; Redis has no rollback for a command that fails while running.")
                    .accessibilityIdentifier("redis-transaction")
                // #218: the command builder beside the editor; it writes commands, never runs them.
                Button {
                    model.perform("view.builder", source: .button, for: tab) // #345
                } label: {
                    Label("Builder", systemImage: model.redisBuilder(for: tab).isOpen ? "hammer.fill" : "hammer")
                }
                .buttonStyle(.borderless)
                .help(model.commandHelp("Command Builder", "view.builder", detail: "pick a command, fill in a form made from its syntax, and insert the exact line into the tab. Nothing runs from it."))
                .accessibilityIdentifier("redis-builder-toggle")
                .tourAnchor(.builderButton) // #232
                Divider().frame(height: 14)
                Text(hint(choice))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if tab.isRunning { ProgressView().controlSize(.small).accessibilityIdentifier("redis-bar-running") }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            DatabaseConnectionNotices(tab: tab, choice: choice, prefix: "redis", family: "Redis", newConnection: { newConnection(named: $0) })
        }
        .font(.callout)
        .padding(.horizontal, 10)
        // A faint tint, so the bar stays recognisable without echoing the output's red error cards.
        .background(Color.red.opacity(0.035))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("redis-tab-bar")
        .tourAnchor(.databaseTabBar) // #232
        .sheet(item: dangerBinding) { confirmation in
            DatabaseDangerSheet(confirmation: confirmation, confirm: { model.confirmRedisDanger() }, cancel: { model.cancelRedisDanger() })
        }
    }

    /// The dangerous-command confirmation of this tab.
    private var dangerBinding: Binding<DatabaseDangerConfirmation?> {
        Binding(get: { model.redisUI.danger?.tabId == tab.id && model.selectedTab === tab ? model.redisUI.danger : nil },
                set: { if $0 == nil, model.redisUI.danger?.tabId == tab.id { model.cancelRedisDanger() } })
    }

    private func hint(_ choice: SQLConnectionChoice) -> String {
        switch choice {
        case .app: "⌘R runs the command on the caret's line through \(model.targetLabel(tab.target))'s own Redis connection."
        case .saved(let connection) where connection.readOnly: "⌘R runs the command on the caret's line on \(connection.summary), opened from \(model.openedFromLabel(connection, tabTarget: tab.target)). Read-only: writes are refused."
        case .saved(let connection): "⌘R runs the command on the caret's line on \(connection.summary), opened from \(model.openedFromLabel(connection, tabTarget: tab.target))."
        case .missing: "Choose a connection to run commands."
        }
    }

    private func newConnection() {
        newConnection(named: nil)
    }

    private func newConnection(named name: String?) {
        let draft = model.newConnectionDraft(for: tab.target, useInTab: tab.id, family: .redis)
        if let name { draft.connection.name = name }
        model.databaseUI.windowId = window?.id
        model.databaseUI.editor = draft
    }

    private func editConnections() {
        model.databaseUI.windowId = window?.id
        model.databaseUI.listTarget = tab.target
    }
}

/// A Redis tab's reply (#190): hashes, sorted sets, sets, lists, streams, and SCAN pages as
/// tables (with filter, CSV, and Open in Window); strings with the string viewers (JSON, …);
/// integers, nil, status, and nested replies as values; errors in red. A SCAN page or a cut
/// range has Load More.
struct RedisReplyCard: View {
    @Environment(AppModel.self) private var model
    let reply: RedisReplyInfo
    var tabTitle = "Redis"
    var pager: RedisReplyPager?

    var body: some View {
        let view = reply.view
        // The SQL result card's neutral style (#190); red only for an error reply.
        Card(title: title, subtitle: subtitle, tint: view.kind == .error ? .red : .teal, copyTextProvider: { reply.plainText }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reply.commandText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("redis-command-text")
                content(view)
                if let pager {
                    RedisPagerControls(pager: pager, reply: reply)
                } else if view.omitted > 0 {
                    Label(cutNote, systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("redis-truncated")
                }
                Text(reply.originText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("output-redis")
    }

    @ViewBuilder
    private func content(_ view: RedisReplyView) -> some View {
        switch view.kind {
        case .error:
            Label(reply.reply.stringValue ?? reply.reply.text.replacingOccurrences(of: "(error) ", with: ""), systemImage: "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("redis-error")
        case .value:
            scalar
        default:
            if view.table.rows.isEmpty {
                Text(view.kind == .keys ? "No keys in this page." : "Empty.").foregroundStyle(.secondary)
            } else {
                ValueTableView(table: view.table, title: "\(tabTitle) · \(reply.name)", subtitle: reply.commandText)
            }
            if let cursor = view.cursor {
                Text(cursor == "0" ? "Cursor 0: the scan is complete." : "Next cursor: \(cursor)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("redis-cursor")
            }
        }
    }

    @ViewBuilder
    private var scalar: some View {
        switch reply.reply {
        case .integer(let value):
            Text("(integer) \(value)").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        case .null:
            Text("(nil)").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
        case .status(let text):
            Label(text, systemImage: "checkmark.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(.green)
        case .bool(let value):
            Text(value ? "(true)" : "(false)").font(.system(.callout, design: .monospaced))
        case .double(let text):
            Text("(double) \(text)").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        case .array(let items, let omitted) where items.isEmpty && omitted == 0:
            Text("(empty array)").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
        default:
            let node = valueNode
            ValueContentView(node: node, label: nil, expansion: model.settings.valueExpansion, preview: nil)
        }
    }

    private var valueNode: ValueNode {
        var id = 0
        return reply.reply.valueNode(nextId: &id)
    }

    private var title: String {
        reply.statement.map { "Command \($0.index) of \($0.count)" } ?? "Redis"
    }

    private var subtitle: String {
        [reply.statement.map { "line \($0.line)" }, reply.name, reply.summary, reply.elapsedText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var cutNote: String {
        let kept = (reply.maxElements ?? reply.view.table.rows.count).formatted()
        return "Runlet keeps at most \(kept) elements per reply; \(reply.view.omitted.formatted()) more weren't kept. Read them in pages: SCAN, HSCAN, SSCAN, or ZSCAN with a cursor, or LRANGE / ZRANGE with a smaller range."
    }
}

/// Load More under a Redis reply (#190).
struct RedisPagerControls: View {
    @Environment(AppModel.self) private var model
    let pager: RedisReplyPager
    let reply: RedisReplyInfo

    var body: some View {
        let next = pager.nextArguments(for: reply)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if pager.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Loading the next page…").font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { if let tab = pager.tab { model.stopRedisPage(tab, item: pager.itemId) } }
                        .controlSize(.small)
                } else if next != nil {
                    Button {
                        if let tab = pager.tab { model.loadMoreRedis(tab, item: pager.itemId) }
                    } label: {
                        Label("Load More", systemImage: "arrow.down.to.line")
                    }
                    .controlSize(.small)
                    .disabled(pager.isDetached || pager.tab?.isRunning == true)
                    .help(reply.view.cursor != nil ? "Runs the scan again from the next cursor, on the same connection, and adds its rows here" : "Reads the elements after these, on the same connection, and adds them here")
                    .accessibilityIdentifier("redis-load-more")
                    Text(pager.pages == 1 ? "\(reply.view.table.rows.count.formatted()) rows so far" : "\(reply.view.table.rows.count.formatted()) rows in \(pager.pages) pages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("End: all \(reply.view.table.rows.count.formatted()) rows, in \(pager.pages) page\(pager.pages == 1 ? "" : "s").", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("redis-page-end")
                }
            }
            if case .failed(let message) = pager.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if reply.view.cursor != nil, next != nil {
                Text("A SCAN may return a key twice, and keys added meanwhile may be missed: Redis's cursors promise only that keys present the whole time show up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("redis-pager")
    }
}
