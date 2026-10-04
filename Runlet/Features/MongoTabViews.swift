import AppKit
import RunletCore
import SwiftUI

extension Color {
    /// MongoDB tabs' colour (#191): a leaf green, darker in light mode so the badge's white
    /// text stays readable, lighter in dark mode.
    static let mongoDB = Color(nsColor: NSColor(name: "RunletMongoDB") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.0, green: 0.64, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.0, green: 0.52, blue: 0.29, alpha: 1)
    })
}

/// "MONGODB" capsule on a MongoDB tab's tab (#191), like `SQLBadge` and `RedisBadge`.
struct MongoDBBadge: View {
    var body: some View {
        Text("MONGODB")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.mongoDB))
            .help("MongoDB tab: JSON queries run on the application's MongoDB connection, or a MongoDB connection you saved for the target or for all targets")
            .accessibilityLabel("MongoDB tab")
            .accessibilityIdentifier("mongo-badge")
    }
}

/// The bar above a MongoDB tab's editor (#191), like the SQL and Redis bars: which connection
/// the query uses, and what ⌘R runs. Choosing a connection never connects or runs anything.
/// Destructive operations confirm in the shared `DatabaseDangerSheet`.
struct MongoTabBar: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window: WindowModel?
    let tab: TabModel
    @Bindable private var mongoUI = MongoUI.shared

    var body: some View {
        let choice = model.sqlConnectionChoice(for: tab)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill").foregroundStyle(Color.mongoDB)
                Text("MongoDB").fontWeight(.semibold)
                DatabaseConnectionButton(
                    tab: tab,
                    help: "The MongoDB connection the query runs on: one the application configures (Laravel MongoDB's DB::connection(), or the project driver's mongoConnection(); no credentials from Runlet), or one you saved (its password stays in the macOS Keychain).",
                    identifier: "mongo-connection-picker",
                    newConnection: newConnection,
                    editConnections: editConnections)
                Divider().frame(height: 14)
                Text(hint(choice))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if tab.isRunning { ProgressView().controlSize(.small).accessibilityIdentifier("mongo-bar-running") }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            DatabaseConnectionNotices(tab: tab, choice: choice, prefix: "mongo", family: "MongoDB", newConnection: { newConnection(named: $0) })
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .background(Color.mongoDB.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mongo-tab-bar")
        .sheet(item: dangerBinding) { confirmation in
            DatabaseDangerSheet(confirmation: confirmation, confirm: { model.confirmMongoDanger() }, cancel: { model.cancelMongoDanger() })
        }
    }

    /// The destructive-operation confirmation of this tab.
    private var dangerBinding: Binding<DatabaseDangerConfirmation?> {
        Binding(get: { mongoUI.danger?.tabId == tab.id && model.selectedTab === tab ? mongoUI.danger : nil },
                set: { if $0 == nil, mongoUI.danger?.tabId == tab.id { model.cancelMongoDanger() } })
    }

    private func hint(_ choice: SQLConnectionChoice) -> String {
        let what = "⌘R runs the tab's JSON query, or the selected one,"
        return switch choice {
        case .app: "\(what) through \(model.targetLabel(tab.target))'s own MongoDB connection."
        case .saved(let connection) where connection.readOnly: "\(what) on \(connection.summary), opened from \(model.openedFromLabel(connection, tabTarget: tab.target)). Read-only: writes are refused."
        case .saved(let connection): "\(what) on \(connection.summary), opened from \(model.openedFromLabel(connection, tabTarget: tab.target))."
        case .missing: "Choose a connection to run queries."
        }
    }

    private func newConnection() {
        newConnection(named: nil)
    }

    private func newConnection(named name: String?) {
        let draft = model.newConnectionDraft(for: tab.target, useInTab: tab.id, family: .mongodb)
        draft.connection.mongo = MongoConnectionOptions()
        if let name { draft.connection.name = name }
        model.databaseUI.windowId = window?.id
        model.databaseUI.editor = draft
    }

    private func editConnections() {
        model.databaseUI.windowId = window?.id
        model.databaseUI.listTarget = tab.target
    }
}

/// Next Page under a MongoDB result (#191), where SQL's Load Next is: which documents the page
/// shows, and the next page of the same query on the same connection. A page replaces the
/// output (its table and Extended JSON tree); production asks again.
struct MongoPagerControls: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        if let page = MongoUI.shared.pages[tab.id], page.more || page.offset > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if page.more {
                        Button {
                            model.loadMoreMongo(tab)
                        } label: {
                            Label("Next Page", systemImage: "arrow.right.to.line")
                        }
                        .controlSize(.small)
                        .disabled(!model.canLoadMoreMongo(tab))
                        .help("Runs the query again for the next \(page.rows.formatted()) documents, on the same connection, and shows them instead of these")
                        .accessibilityIdentifier("mongo-next-page")
                    }
                    Text(status(page))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mongo-page-status")
                }
                if page.more, !model.canLoadMoreMongo(tab), !tab.isRunning {
                    Label("The query or the connection changed; run it again to page.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Pages are separate reads, not a snapshot: sort on a unique field so documents don't repeat or go missing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mongo-pager")
        }
    }

    private func status(_ page: MongoUI.Page) -> String {
        let range = page.rows == 0 ? "No documents after \(page.offset.formatted())" : "Documents \((page.offset + 1).formatted())–\(page.nextOffset.formatted())"
        return range + (page.more ? "; more may follow." : ": the end.")
    }
}

struct MongoConnectionFields: View {
    @Binding var connection: DatabaseConnection

    private func field<Value>(_ path: WritableKeyPath<MongoConnectionOptions, Value>) -> Binding<Value> {
        Binding(get: { (connection.mongo ?? MongoConnectionOptions())[keyPath: path] }, set: { value in
            var options = connection.mongo ?? MongoConnectionOptions()
            options[keyPath: path] = value
            connection.mongo = options
        })
    }

    var body: some View {
        Section("MongoDB") {
            Toggle("DNS SRV (mongodb+srv)", isOn: field(\.srv))
            TextField("Authentication database", text: field(\.authDatabase))
            Picker("Authentication mechanism", selection: field(\.authMechanism)) {
                Text("Default").tag("")
                Text("SCRAM-SHA-256").tag("SCRAM-SHA-256")
                Text("SCRAM-SHA-1").tag("SCRAM-SHA-1")
            }
            TextField("Replica set", text: field(\.replicaSet))
            Picker("Read preference", selection: field(\.readPreference)) {
                ForEach(["primary", "primaryPreferred", "secondary", "secondaryPreferred", "nearest"], id: \.self) { Text($0).tag($0) }
            }
            Text("Enter a host, not a URI. Passwords stay in the Keychain. SSH tunnels use a direct connection and cannot use SRV.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
