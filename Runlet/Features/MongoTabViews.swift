import RunletCore
import SwiftUI

struct MongoTabBar: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable private var mongoUI = MongoUI.shared

    var body: some View {
        HStack {
            Label("MongoDB", systemImage: "leaf.fill").foregroundStyle(.green)
            Menu(model.sqlConnectionChoice(for: tab).savedConnection?.name ?? tab.sqlConnection ?? "Application: mongodb") {
                Button("Application: mongodb") { model.setSQLConnection("mongodb", for: tab) }
                ForEach(model.library.databaseConnections.filter { $0.driver == .mongodb && $0.isAvailable(on: tab.target) }) { connection in
                    Button(connection.name) { model.setSQLSavedConnection(connection, for: tab) }
                }
                Divider()
                Button("New MongoDB Connection…") {
                    let draft = model.newConnectionDraft(for: tab.target, useInTab: tab.id, family: .mongodb)
                    draft.connection.mongo = MongoConnectionOptions()
                    model.databaseUI.windowId = model.window(containing: tab.id)?.id
                    model.databaseUI.editor = draft
                }
                if let connection = model.sqlConnectionChoice(for: tab).savedConnection {
                    Button("Edit Connection…") { model.databaseUI.editor = model.editConnectionDraft(connection, from: tab.target) }
                }
            }.fixedSize()
            if case .app = model.sqlConnectionChoice(for: tab) {
                TextField("Application connection", text: Binding(get: { tab.sqlConnection ?? "mongodb" }, set: { model.setSQLConnection($0, for: tab) }))
                    .textFieldStyle(.roundedBorder).frame(width: 150)
            }
            if let saved = model.sqlConnectionChoice(for: tab).savedConnection { SavedConnectionBadges(connection: saved) }
            Text("One JSON query · ⌘R to run").foregroundStyle(.secondary)
            Spacer()
            Button("First Page") { model.runMongo(tab) }
            Button("Load More") { model.loadMoreMongo(tab) }
                .disabled(!model.canLoadMoreMongo(tab))
        }
        .font(.callout)
        .disabled(tab.isRunning)
        .sheet(item: $mongoUI.confirmation) { confirmation in
            VStack(alignment: .leading, spacing: 16) {
                Text("Confirm MongoDB \(confirmation.operation)").font(.title2.bold())
                Text("\(confirmation.operation) will change or remove data in “\(confirmation.collection)”. This operation cannot be undone by Runlet.")
                HStack {
                    Button("Cancel") { mongoUI.confirmation = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Confirm \(confirmation.operation)", role: .destructive) {
                        mongoUI.confirmation = nil
                        confirmation.perform()
                    }.accessibilityIdentifier("mongo-confirm")
                }
            }.padding(24).frame(width: 460)
        }
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
