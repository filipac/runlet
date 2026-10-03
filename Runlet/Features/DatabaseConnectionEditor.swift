import RunletCore
import SwiftUI

/// The sheet that creates or edits a saved database connection (#138). The password goes to
/// the Keychain on Save and is never shown again (Replace / Remove only); Cancel keeps
/// nothing. Test Connection opens the connection in the target's PHP and reports the server.
struct DatabaseConnectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: DatabaseConnectionDraft

    var body: some View {
        let others = model.databaseConnections(for: draft.connection.scope)
        let errors = draft.connection.validate(others: others)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    TextField("Name", text: $draft.connection.name, prompt: Text("Reporting replica"))
                        .accessibilityIdentifier("db-name")
                    Picker("Driver", selection: driver) {
                        ForEach(DatabaseDriverKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("db-driver")
                }
                if draft.connection.driver.usesHost {
                    Section {
                        TextField("Host", text: $draft.connection.host, prompt: Text("127.0.0.1"))
                            .accessibilityIdentifier("db-host")
                        TextField("Port", text: port, prompt: Text(draft.connection.driver.defaultPort.map(String.init) ?? ""))
                            .accessibilityIdentifier("db-port")
                        TextField("Database", text: $draft.connection.database, prompt: Text("optional"))
                            .accessibilityIdentifier("db-database")
                    } footer: {
                        Text(whereItConnects)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Section {
                        TextField("User", text: $draft.connection.user)
                            .accessibilityIdentifier("db-user")
                        passwordRow
                    } footer: {
                        Text("The password is stored only in the macOS Keychain, on this Mac (never in iCloud). Runlet reads it when a statement runs and sends it only to the PHP process that opens the connection, on its standard input.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Section {
                        TextField("SQLite file", text: $draft.connection.database, prompt: Text("database/database.sqlite"))
                            .accessibilityIdentifier("db-database")
                    } footer: {
                        Text("The file on the target: absolute, or relative to the project directory. Runlet opens existing files only. " + whereItConnects)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    Stepper(value: $draft.connection.connectTimeout, in: DatabaseConnection.connectTimeoutRange) {
                        LabeledContent("Connect timeout", value: "\(draft.connection.connectTimeout) s")
                    }
                    .accessibilityIdentifier("db-timeout")
                }
                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.description) { error in
                            Label(error.description, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                Section {
                    testResult
                }
            }
            .formStyle(.grouped)
            Divider()
            footer(canSave: errors.isEmpty)
        }
        .frame(width: 540, height: draft.connection.driver.usesHost ? 640 : 480)
        .onAppear { DatabaseConnectionDraft.current = draft }
        .onDisappear {
            draft.testTask?.cancel()
            if DatabaseConnectionDraft.current === draft { DatabaseConnectionDraft.current = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 26))
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.isNew ? "New Database Connection" : "Edit Database Connection").font(.headline)
                Text("For \(model.targetLabel(draft.connection.scope)). Saving or editing runs nothing; Test Connection runs none of your SQL and no application code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            EnvironmentBadge(environment: model.library.environment(for: draft.connection.scope))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var passwordRow: some View {
        switch draft.passwordMode {
        case .keep:
            LabeledContent("Password") {
                HStack(spacing: 8) {
                    if draft.hasStoredPassword {
                        Label("Saved in the Keychain", systemImage: "lock.fill").foregroundStyle(.secondary)
                        Button("Replace…") { draft.passwordMode = .replace }
                            .accessibilityIdentifier("db-password-replace")
                        Button("Remove", role: .destructive) { draft.passwordMode = .remove }
                            .accessibilityIdentifier("db-password-remove")
                    } else {
                        Text("None").foregroundStyle(.secondary)
                        Button("Set…") { draft.passwordMode = .replace }
                    }
                }
            }
        case .replace:
            HStack {
                SecureField("Password", text: $draft.password, prompt: Text(draft.hasStoredPassword ? "new password" : "optional"))
                    .accessibilityIdentifier("db-password")
                if draft.hasStoredPassword {
                    Button("Keep Saved") {
                        draft.password = ""
                        draft.passwordMode = .keep
                    }
                }
            }
        case .remove:
            LabeledContent("Password") {
                HStack(spacing: 8) {
                    Label("Removed from the Keychain when you save", systemImage: "lock.slash").foregroundStyle(.orange)
                    Button("Undo") { draft.passwordMode = .keep }
                }
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch draft.test {
        case .idle:
            Text("Test Connection opens the connection from \(model.targetLabel(draft.connection.scope)) and reports the server's version, the database, and the user.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .testing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .succeeded(let info):
            VStack(alignment: .leading, spacing: 4) {
                Label(info.summary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("db-test-result")
                if let php = info.phpVersion {
                    Text("Opened by PHP \(php) on \(model.targetLabel(draft.connection.scope))" + (info.connectMs.map { String(format: " in %.0f ms", $0) } ?? "") + ".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("db-test-result")
        }
    }

    private func footer(canSave: Bool) -> some View {
        HStack {
            Button("Test Connection") { model.runConnectionTest(draft) }
                .disabled(!canSave || draft.test == .testing)
                .accessibilityIdentifier("db-test")
            Spacer()
            Button("Cancel", role: .cancel) {
                draft.password = ""
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("db-cancel")
            Button("Save") {
                model.commitConnectionDraft(draft)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
            .accessibilityIdentifier("db-save")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var driver: Binding<DatabaseDriverKind> {
        Binding(get: { draft.connection.driver }, set: { kind in
            guard kind != draft.connection.driver else { return }
            draft.connection.driver = kind
            draft.connection.port = nil
            draft.test = .idle
        })
    }

    private var port: Binding<String> {
        Binding(get: { draft.connection.port.map(String.init) ?? "" }, set: { text in
            let digits = text.filter(\.isNumber)
            draft.connection.port = digits.isEmpty ? nil : Int(digits.prefix(6))
        })
    }

    /// Where the host name or file is resolved: this Mac, the container, or the server.
    private var whereItConnects: String {
        switch draft.connection.scope {
        case .local: "Runlet opens the connection in the project's PHP on this Mac."
        case .docker: "Runlet opens the connection in the container's PHP, so a Compose service name (such as mysql) works as the host; the container's PHP needs the driver."
        case .ssh(let id):
            model.library.sshProfile(id)?.container != nil
                ? "Runlet opens the connection in the PHP of the container on the server; its PHP needs the driver."
                : "Runlet opens the connection in the server's PHP, so the host is resolved on the server; its PHP needs the driver."
        case .sandbox: ""
        }
    }
}

/// A target's saved connections (#138), with New Connection…, Edit…, Duplicate, and Delete:
/// in the project's options, the Docker and SSH profile forms, and Edit Connections….
struct DatabaseConnectionsList: View {
    @Environment(AppModel.self) private var model
    let target: TargetRef
    /// False for a profile that isn't saved yet: its connections can be added once it is.
    var targetIsSaved = true
    @State private var editing: DatabaseConnectionDraft?

    var body: some View {
        let connections = model.databaseConnections(for: target)
        VStack(alignment: .leading, spacing: 8) {
            if !TargetLibrary.supportsDatabaseConnections(target) {
                Text("The Laravel sandbox can't have saved connections yet.").foregroundStyle(.secondary)
            } else if !targetIsSaved {
                Text("Save the profile first, then add its database connections.").foregroundStyle(.secondary)
            } else {
                if connections.isEmpty {
                    Text("No saved connections. SQL tabs use the application's own connections, which need no credentials. Save one to query a database the application doesn't configure.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(connections) { connection in
                    row(connection)
                }
                HStack {
                    Text("Passwords stay in the macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("New Connection…") { editing = model.newConnectionDraft(for: target) }
                        .accessibilityIdentifier("db-new-connection")
                }
            }
        }
        .sheet(item: $editing) { draft in
            DatabaseConnectionEditor(draft: draft)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("db-connections")
    }

    private func row(_ connection: DatabaseConnection) -> some View {
        HStack(spacing: 10) {
            DatabaseDriverIcon(driver: connection.driver)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                Text(connection.summary + (connection.user.isEmpty ? "" : " · user \(connection.user)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if connection.driver.usesHost {
                Image(systemName: model.hasSavedPassword(connection.id) ? "lock.fill" : "lock.open")
                    .foregroundStyle(.secondary)
                    .help(model.hasSavedPassword(connection.id) ? "Its password is in the Keychain" : "No password saved")
            }
            Button("Edit…") { editing = model.editConnectionDraft(connection) }
            Menu {
                Button("Duplicate") { model.duplicateDatabaseConnection(connection.id) }
                Divider()
                Button("Delete…", role: .destructive) { model.confirmRemoveDatabaseConnection(connection.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("db-connection-actions-\(connection.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("db-connection-\(connection.name)")
    }
}

/// Edit Connections… from the SQL bar: the target's saved connections in a sheet.
struct DatabaseConnectionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: TargetRef

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cylinder.split.1x2").font(.system(size: 24)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Database Connections").font(.headline)
                    Text("Saved for \(model.targetLabel(target)). The application's own connections need no entry here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                DatabaseConnectionsList(target: target)
                    .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 420)
    }
}

/// A small symbol per driver.
struct DatabaseDriverIcon: View {
    let driver: DatabaseDriverKind

    var body: some View {
        Image(systemName: driver == .sqlite ? "doc.text" : "cylinder.split.1x2")
            .foregroundStyle(driver == .pgsql ? Color.blue : driver == .mysql ? Color.orange : Color.teal)
            .frame(width: 18)
            .help(driver.displayName)
    }
}
