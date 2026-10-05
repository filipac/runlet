import AppKit
import RunletCore
import RunletExecution
import SwiftUI

/// The sheet that creates or edits a saved database connection (#138). The password goes to
/// the Keychain on Save and is never shown again (Replace / Remove only); Cancel keeps
/// nothing. Test Connection opens the connection in the target's PHP, or from this Mac (#142),
/// and reports the server. Advanced (#140): Unix socket, charset, TLS, init statements, and
/// extra DSN options. #142: which targets it is for (one, or all), and where it is opened.
struct DatabaseConnectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: DatabaseConnectionDraft

    var body: some View {
        let errors = draft.connection.validate(others: model.library.databaseConnections)
        // #143: a tunnel whose SSH profile was removed can't be saved until another is chosen.
        let tunnelMissing = draft.connection.usesSSHTunnel && draft.connection.sshProfile != nil && model.library.tunnelProfile(of: draft.connection) == nil
        let driver = draft.connection.driver
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    TextField("Name", text: $draft.connection.name, prompt: Text("Reporting replica"))
                        .accessibilityIdentifier("db-name")
                    Picker("Driver", selection: driverBinding) {
                        ForEach(DatabaseDriverKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("db-driver")
                } footer: {
                    if let note = driverNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                placeSection // #142
                switch driver {
                case .sqlite:
                    Section {
                        HStack {
                            TextField("SQLite file", text: $draft.connection.database, prompt: Text(onThisMac ? "~/data/app.sqlite" : "database/database.sqlite"))
                                .accessibilityIdentifier("db-database")
                            if onThisMac { chooseButton(for: $draft.connection.database, files: ["sqlite", "sqlite3", "db"]) }
                        }
                    } footer: {
                        caption((onThisMac ? "The file on this Mac, as an absolute path (or ~/…). " : "The file on the target: absolute, or relative to the project directory. ") + "Runlet opens existing files only. " + whereItConnects)
                    }
                case .custom:
                    Section {
                        TextField("DSN", text: dsn, prompt: Text("oci:dbname=//db.internal:1521/XE"), axis: .vertical)
                            .lineLimit(1...4)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("db-dsn")
                    } footer: {
                        caption("Any PDO DSN, passed to new PDO() as you type it. Runlet doesn't parse it, so the schema explorer reads only what the driver reports. Never put the password in the DSN: it's saved in Runlet's settings file; the Password field below keeps it in the Keychain. " + whereItConnects)
                    }
                default:
                    Section {
                        if draft.connection.socket != nil, driver.supportsSocket {
                            HStack {
                                TextField("Socket", text: socket, prompt: Text(driver == .pgsql ? (onThisMac ? "/tmp" : "/var/run/postgresql") : driver == .redis ? (onThisMac ? "/tmp/redis.sock" : "/var/run/redis/redis.sock") : (onThisMac ? "/tmp/mysql.sock" : "/var/run/mysqld/mysqld.sock")))
                                    .accessibilityIdentifier("db-socket")
                                if onThisMac { chooseButton(for: socket, directory: driver == .pgsql) }
                            }
                        } else {
                            TextField("Host", text: $draft.connection.host, prompt: Text(draft.connection.usesSSHTunnel ? "db.internal" : "127.0.0.1"))
                                .accessibilityIdentifier("db-host")
                        }
                        if draft.connection.socket == nil || driver == .pgsql {
                            TextField(draft.connection.socket != nil ? "Port (names the socket file)" : "Port", text: port, prompt: Text(driver.defaultPort.map(String.init) ?? ""))
                                .accessibilityIdentifier("db-port")
                        }
                        // #190: a Redis database is a number (SELECT).
                        TextField(driver == .redis ? "Database number" : "Database", text: $draft.connection.database, prompt: Text(driver == .redis ? "0" : "optional"))
                            .accessibilityIdentifier("db-database")
                    } footer: {
                        caption(draft.connection.socket != nil
                                ? (driver == .pgsql ? "The directory that holds PostgreSQL's socket, on \(placeName). " : driver == .redis ? "Redis's socket file (unixsocket), on \(placeName). " : "MySQL's socket file, on \(placeName). ") + whereItConnects
                                : whereItConnects)
                    }
                }
                if driver.usesCredentials {
                    if driver == .mongodb {
                        MongoConnectionFields(connection: $draft.connection)
                    }
                    Section {
                        TextField(driver == .redis ? "User (ACL)" : "User", text: $draft.connection.user, prompt: driver == .redis ? Text("default") : nil)
                            .accessibilityIdentifier("db-user")
                        passwordRow
                    } footer: {
                        caption("The password is stored only in the macOS Keychain, on this Mac (never in iCloud). Runlet reads it when a \(driver.family == .redis ? "command" : "statement") runs and sends it only to the PHP process that opens the connection, on its standard input.")
                    }
                }
                Section {
                    Stepper(value: $draft.connection.connectTimeout, in: DatabaseConnection.connectTimeoutRange) {
                        LabeledContent("Connect timeout", value: "\(draft.connection.connectTimeout) s")
                    }
                    .accessibilityIdentifier("db-timeout")
                }
                // #139: read-only, enforced by the database.
                Section {
                    Toggle("Read-only", isOn: readOnly)
                        .disabled(!driver.supportsReadOnly && !draft.connection.readOnly)
                        .accessibilityIdentifier("db-read-only")
                } footer: {
                    caption(!driver.supportsReadOnly || driver == .redis
                            ? driver.readOnlyGuard
                            : draft.connection.readOnly
                            ? driver.readOnlyGuard + " Runlet also refuses, before sending them, statements that could write or make the session writable again. For a guarantee, connect as a database user that can only read."
                            : "Read-only makes the database refuse writes in this connection's session, and Runlet refuse statements that could write before sending them. Use it to look at production data safely.")
                }
                // #139: the connection's own environment and colour; runs use the stricter of
                // this and the target's.
                Section {
                    TargetEnvironmentFields(environment: $draft.connection.environment.orDevelopment, color: $draft.connection.color, caption: environmentCaption)
                }
                advancedSections
                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.description) { error in
                            Label(error.description, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Section {
                    testResult
                }
            }
            .formStyle(.grouped)
            Divider()
            footer(canSave: errors.isEmpty && !tunnelMissing)
        }
        .frame(width: 580, height: driver == .sqlite ? 720 : 820)
        .onAppear { DatabaseConnectionDraft.current = draft }
        .onDisappear {
            draft.testTask?.cancel()
            if DatabaseConnectionDraft.current === draft { DatabaseConnectionDraft.current = nil }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 26))
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.isNew ? "New Database Connection" : "Edit Database Connection").font(.headline)
                Text("For \(draft.connection.scope.map(model.targetLabel) ?? "all targets"). Saving or editing runs nothing; Test Connection runs no application code, and " + (draft.connection.driver == .mongodb ? "only a MongoDB ping." : draft.connection.driver.family == .redis ? "only PING, INFO server, and ACL WHOAMI." : "of your SQL only the init statements."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // What a run on this connection is marked as: the stricter of the target's and the
            // connection's environment (#139).
            EnvironmentBadge(environment: model.library.marking(for: draft.connection.scope ?? .sandbox, connection: draft.connection).environment)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// "Herd PHP 8.4.25, the first PHP here with pdo_sqlsrv or pdo_dblib," before a verb: a label
    /// with a reason (#184) gets its closing comma.
    static func appositive(_ label: String) -> String {
        label.contains(", the first PHP here with ") ? label + "," : label
    }

    /// What the target's PHP (or this Mac's, #142) needs for the driver (#140).
    private var driverNote: String? {
        // #184: from this Mac, Runlet picks the first PHP that has the driver.
        let php = onThisMac ? "this Mac's PHP (Runlet's PHP has neither: the first PHP on this Mac that has one opens it)" : "the target's PHP"
        switch draft.connection.driver {
        case .sqlsrv: return "Needs pdo_sqlsrv (with Microsoft's ODBC driver) or pdo_dblib (FreeTDS) in \(php); Runlet uses pdo_sqlsrv when both are there. Not yet tested against a live SQL Server."
        case .custom: return "For PDO drivers Runlet doesn't model, such as oci, odbc, or firebird. \(onThisMac ? "From this Mac, the first PHP that has the DSN's driver opens it." : "The target's PHP needs that driver.")"
        case .redis: return "Redis tabs only (#190). Runlet's own Redis client opens it in plain PHP, so \(onThisMac ? "this Mac's PHP" : "the target's PHP") needs no Redis extension; TLS needs openssl. Password, or ACL user and password; the database is a number."
        default: return nil
        }
    }

    // MARK: Where (#142)

    /// Opened from this Mac: Connect From says so, or it is a connection of all targets.
    private var onThisMac: Bool { draft.connection.opensOnThisMac }

    /// "this Mac" or "the target", for captions.
    private var placeName: String { onThisMac ? "this Mac" : "the target" }

    /// Which targets the connection is for, and where it is opened.
    @ViewBuilder
    private var placeSection: some View {
        Section {
            if let home = draft.homeTarget {
                Picker("Available on", selection: scopeBinding(home: home)) {
                    Text(model.targetLabel(home)).tag(false)
                    Text("All targets").tag(true)
                }
                .accessibilityIdentifier("db-scope")
            } else {
                LabeledContent("Available on", value: "All targets")
            }
            Picker("Connect from", selection: connectFromBinding) {
                if let scope = draft.connection.scope {
                    Text(Self.targetPHPLabel(scope, model: model)).tag(DatabaseConnectFrom.target)
                }
                Text("This Mac").tag(DatabaseConnectFrom.thisMac)
                // #143
                Text("This Mac, through SSH profile").tag(DatabaseConnectFrom.sshTunnel)
            }
            .accessibilityIdentifier("db-connect-from")
            if draft.connection.usesSSHTunnel {
                tunnelProfileRow
            }
        } footer: {
            caption(placeCaption)
        }
    }

    /// #143: the SSH profile whose connection carries the tunnel, its state, and a removed
    /// profile's "missing" state (never replaced by another one silently).
    @ViewBuilder
    private var tunnelProfileRow: some View {
        let profiles = model.library.sshProfiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let chosen = draft.connection.sshProfile
        let missing = chosen != nil && model.library.sshProfile(chosen!) == nil
        Picker("SSH profile", selection: tunnelProfileBinding) {
            if chosen == nil { Text("Choose…").tag(UUID?.none) }
            if missing, let chosen { Text("Missing profile").tag(UUID?.some(chosen)) }
            ForEach(profiles) { profile in
                Text(profile.name == profile.destinationLabel ? profile.name : "\(profile.name) (\(profile.destinationLabel))").tag(UUID?.some(profile.id))
            }
        }
        .accessibilityIdentifier("db-ssh-profile")
        if missing {
            Label("The SSH profile this connection went through was removed. Choose another one; Runlet never picks one by itself.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("db-ssh-profile-missing")
        } else if profiles.isEmpty {
            caption("No SSH profiles yet. Add one (Library ▸ New SSH Profile…), then choose it here.")
        } else if let id = chosen, let profile = model.library.sshProfile(id) {
            // Read from the control socket on this Mac (never contacts the server).
            let status = SSHControlSocket.status(at: SSHControlPaths.socketPath(for: id, in: model.paths.ssh))
            LabeledContent("Its connection") {
                HStack(spacing: 6) {
                    Circle().fill(status.tint).frame(width: 7, height: 7)
                    Text(status == .connected ? "Connected" : "\(status.label): Runlet asks before connecting").foregroundStyle(.secondary)
                    if profile.environment != .development { EnvironmentBadge(environment: profile.environment) }
                }
                .font(.caption)
            }
        }
    }

    private var tunnelProfileBinding: Binding<UUID?> {
        Binding(get: { draft.connection.sshProfile }, set: { id in
            guard id != draft.connection.sshProfile else { return }
            draft.connection.sshProfile = id
            draft.test = .idle
        })
    }

    /// "Shop's PHP", "the container's PHP (Shop)", "the server's PHP (Staging)".
    static func targetPHPLabel(_ target: TargetRef, model: AppModel) -> String {
        switch target {
        case .local: "The project's PHP"
        case .docker: "The container's PHP"
        case .ssh(let id): model.library.sshProfile(id)?.container != nil ? "The container's PHP on the server" : "The server's PHP"
        case .sandbox: "The sandbox's PHP"
        }
    }

    private var placeCaption: String {
        var text = ""
        if draft.connection.isAllTargets {
            text = "Every \(draft.connection.driver.family.displayName) tab's connection picker offers it, the sandbox's too. It always opens from this Mac (directly or through an SSH tunnel), because a target's PHP may not reach it. "
        }
        if draft.connection.usesSSHTunnel {
            let php = Self.appositive(model.localPHPDescription(for: draft.connection))
            let name = model.library.tunnelProfile(of: draft.connection).map { "“\($0.name)”" } ?? "the profile"
            text += "Runlet adds a forward on 127.0.0.1 (a free port) to the SSH connection of \(name), to the host and port below as that server resolves them, and \(php) opens the connection through it, with no project code. The forward exists only while it's used, and \(Int(AppModel.sqlTunnelIdleTimeout.components.seconds / 60)) minutes after. If the profile isn't connected, Runlet asks first. TLS files are paths on this Mac."
            return text
        }
        if onThisMac {
            let php = Self.appositive(model.localPHPDescription(for: draft.connection))
            text += "From this Mac, \(php) opens it in an empty folder of Runlet's, with no project code. Host names are resolved on this Mac, so localhost and 127.0.0.1 mean this Mac, not the server or a container: use a published port. Socket, SQLite, and TLS files are paths on this Mac."
        } else {
            text += "The target's PHP opens it, so a Docker service name or a database only the server can reach works; that PHP needs the driver."
        }
        return text
    }

    private func scopeBinding(home: TargetRef) -> Binding<Bool> {
        Binding(get: { draft.connection.isAllTargets }, set: { allTargets in
            guard allTargets != draft.connection.isAllTargets else { return }
            draft.connection.scope = allTargets ? nil : home
            // All targets open from this Mac: directly, or through the tunnel it has (#143).
            if allTargets, draft.connection.connectFrom == .target { draft.connection.connectFrom = .thisMac }
            draft.test = .idle
        })
    }

    private var connectFromBinding: Binding<DatabaseConnectFrom> {
        Binding(get: { draft.connection.usesSSHTunnel ? .sshTunnel : draft.connection.opensOnThisMac ? .thisMac : .target }, set: { place in
            guard place != draft.connection.connectFrom else { return }
            draft.connection.connectFrom = place
            if place == .sshTunnel {
                // #143: a tunnel forwards a host and port; an SSH target's own profile is the
                // likely bastion, else the user chooses.
                draft.connection.socket = nil
                if draft.connection.sshProfile == nil, case .ssh(let id) = draft.connection.scope { draft.connection.sshProfile = id }
            }
            draft.test = .idle
        })
    }

    /// Choose… for a path on this Mac (#142): an SQLite file, a socket, a TLS file.
    private func chooseButton(for path: Binding<String>, files: [String]? = nil, directory: Bool = false) -> some View {
        Button("Choose…") {
            let panel = NSOpenPanel()
            panel.canChooseFiles = !directory
            panel.canChooseDirectories = directory
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.treatsFilePackagesAsDirectories = true
            let current = (path.wrappedValue as NSString).expandingTildeInPath
            if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: directory ? current : (current as NSString).deletingLastPathComponent) }
            if panel.runModal() == .OK, let url = panel.url {
                path.wrappedValue = url.path
                draft.test = .idle
            }
        }
        .accessibilityIdentifier("db-choose")
    }

    // MARK: Advanced (#140)

    /// A one-line summary of the advanced options in use, next to the disclosure.
    private var advancedSummary: String {
        let connection = draft.connection
        var parts: [String] = []
        if connection.socket != nil, connection.driver.supportsSocket { parts.append("socket") }
        if let charset = connection.charset, !charset.isEmpty, connection.driver.supportsCharset { parts.append(charset) }
        if let tls = connection.tls, !connection.driver.tlsModes.isEmpty { parts.append("TLS \(tls.mode.rawValue)") }
        let statements = connection.initStatements.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if statements > 0 { parts.append(statements == 1 ? "1 init statement" : "\(statements) init statements") }
        let options = connection.options.filter { !$0.key.isEmpty }.count
        if options > 0, connection.driver.supportsOptions { parts.append(options == 1 ? "1 option" : "\(options) options") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var advancedSections: some View {
        let driver = draft.connection.driver
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { draft.showAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(draft.showAdvanced ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("Advanced")
                    Spacer()
                    Text(advancedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("db-advanced")
        }
        if draft.showAdvanced {
            if (driver.supportsSocket && !draft.connection.usesSSHTunnel) || driver.supportsCharset {
                Section("Connection") {
                    if driver.supportsSocket, !draft.connection.usesSSHTunnel {
                        Toggle("Connect through a Unix socket", isOn: usesSocket)
                            .accessibilityIdentifier("db-use-socket")
                    }
                    if driver.supportsCharset {
                        TextField(driver == .mysql ? "Charset" : "Client encoding", text: charset, prompt: Text(driver == .mysql ? "utf8mb4" : "the server's"))
                            .accessibilityIdentifier("db-charset")
                    }
                }
            }
            if !driver.tlsModes.isEmpty {
                tlsSection
            }
            if driver.supportsInitStatements {
                initStatementsSection
            }
            if driver.supportsOptions {
                optionsSection
            }
        }
    }

    private var tlsSection: some View {
        let driver = draft.connection.driver
        let mode = draft.connection.tls?.mode
        return Section {
            Picker("TLS", selection: tlsMode) {
                Text(defaultTLSLabel).tag(DatabaseTLSMode?.none)
                ForEach(driver.tlsModes) { mode in
                    Text(mode.displayName).tag(DatabaseTLSMode?.some(mode))
                }
            }
            .accessibilityIdentifier("db-tls")
            if let mode, mode.usesFiles, driver.supportsTLSFiles {
                HStack {
                    TextField("CA certificate", text: tlsFile(\.caFile), prompt: Text(mode == .require ? "optional" : driver == .mysql ? "PHP's default CAs" : driver == .mongodb ? "system trust store" : "~/.postgresql/root.crt"))
                        .accessibilityIdentifier("db-tls-ca")
                    if onThisMac { chooseButton(for: tlsFile(\.caFile)) }
                }
                HStack {
                    TextField("Client certificate", text: tlsFile(\.certificateFile), prompt: Text("optional"))
                        .accessibilityIdentifier("db-tls-cert")
                    if onThisMac { chooseButton(for: tlsFile(\.certificateFile)) }
                }
                HStack {
                    TextField("Client key", text: tlsFile(\.keyFile), prompt: Text("optional"))
                        .accessibilityIdentifier("db-tls-key")
                    if onThisMac { chooseButton(for: tlsFile(\.keyFile)) }
                }
            }
        } header: {
            Text("TLS")
        } footer: {
            caption(driver.tlsNote + (driver.supportsTLSFiles ? (onThisMac ? " Files are paths on this Mac, where its PHP opens the connection; Runlet never reads them." : " Files are paths on \(model.targetLabel(draft.connection.scope ?? .sandbox)), where its PHP opens the connection; Runlet never reads them.") : "")
                    + (draft.connection.usesSSHTunnel ? " " + driver.tunnelTLSNote : ""))
        }
    }

    /// What "no TLS setting" means for the driver.
    private var defaultTLSLabel: String {
        switch draft.connection.driver {
        case .mysql, .redis: "Driver default (off)"
        case .pgsql: "Driver default (prefer)"
        case .sqlsrv: "Driver default (ODBC driver's)"
        default: "Driver default"
        }
    }

    private var initStatementsSection: some View {
        Section {
            ForEach(draft.connection.initStatements.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline) {
                    TextField("Statement \(index + 1)", text: initStatement(index), prompt: Text(draft.connection.driver == .mysql ? "SET time_zone = '+00:00'" : "SET search_path TO reports"), axis: .vertical)
                        .lineLimit(1...3)
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()
                        .accessibilityIdentifier("db-init-\(index + 1)")
                    Button {
                        guard draft.connection.initStatements.indices.contains(index) else { return }
                        draft.connection.initStatements.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this statement")
                }
            }
            Button("Add Init Statement") { draft.connection.initStatements.append("") }
                .disabled(draft.connection.initStatements.count >= SQLScript.maximumInitStatements)
                .accessibilityIdentifier("db-init-add")
        } header: {
            Text("Init statements")
        } footer: {
            caption(draft.connection.readOnly && draft.connection.driver.supportsReadOnly
                    ? "Run after connecting, before every statement, Run All, Load Schema, and Test Connection. On this read-only connection they run in the read-only session: reads and session settings (SET …) only, nothing that writes, changes server-wide settings, or ends read-only; Runlet checks the session is still read-only afterwards. Production confirmations show them."
                    : "Run after connecting, before every statement, Run All, Load Schema, and Test Connection, one statement each (no BEGIN or COMMIT). Production confirmations show them.")
        }
    }

    private var optionsSection: some View {
        Section {
            ForEach(draft.connection.options.indices, id: \.self) { index in
                HStack {
                    TextField("Key", text: optionKey(index), prompt: Text(draft.connection.driver == .pgsql ? "application_name" : "APP"))
                        .labelsHidden()
                        .frame(maxWidth: 190)
                        .accessibilityIdentifier("db-option-key-\(index + 1)")
                    TextField("Value", text: optionValue(index), prompt: Text("Runlet"))
                        .labelsHidden()
                        .accessibilityIdentifier("db-option-value-\(index + 1)")
                    Button {
                        guard draft.connection.options.indices.contains(index) else { return }
                        draft.connection.options.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this option")
                }
            }
            Button("Add Option") { draft.connection.options.append(DatabaseOption(key: "", value: "")) }
                .disabled(draft.connection.options.count >= DatabaseConnection.maximumOptions)
                .accessibilityIdentifier("db-option-add")
        } header: {
            Text("DSN options")
        } footer: {
            caption(draft.connection.driver == .pgsql
                    ? "libpq keywords appended to the DSN, such as application_name, target_session_attrs, or hostaddr. Never a password: that belongs in the Password field."
                    : "pdo_sqlsrv DSN keywords, such as APP, ApplicationIntent, or MultiSubnetFailover. Never a password: that belongs in the Password field.")
        }
    }

    // MARK: Bindings

    private var readOnly: Binding<Bool> {
        Binding(get: { draft.connection.readOnly }, set: { value in
            draft.connection.readOnly = value
            draft.test = .idle
        })
    }

    private var driverBinding: Binding<DatabaseDriverKind> {
        Binding(get: { draft.connection.driver }, set: { kind in
            guard kind != draft.connection.driver else { return }
            draft.connection.driver = kind
            draft.connection.port = nil
            // A TLS mode the new driver can't express goes back to its default.
            if let mode = draft.connection.tls?.mode, !kind.tlsModes.contains(mode) { draft.connection.tls = nil }
            draft.test = .idle
        })
    }

    private var port: Binding<String> {
        Binding(get: { draft.connection.port.map(String.init) ?? "" }, set: { text in
            let digits = text.filter(\.isNumber)
            draft.connection.port = digits.isEmpty ? nil : Int(digits.prefix(6))
        })
    }

    private var dsn: Binding<String> {
        Binding(get: { draft.connection.dsn ?? "" }, set: { draft.connection.dsn = $0.replacingOccurrences(of: "\n", with: "") })
    }

    private var socket: Binding<String> {
        Binding(get: { draft.connection.socket ?? "" }, set: { draft.connection.socket = $0 })
    }

    private var usesSocket: Binding<Bool> {
        Binding(get: { draft.connection.socket != nil }, set: { on in
            draft.connection.socket = on ? (draft.connection.socket ?? "") : nil
            draft.test = .idle
        })
    }

    private var charset: Binding<String> {
        Binding(get: { draft.connection.charset ?? "" }, set: { draft.connection.charset = $0.isEmpty ? nil : $0 })
    }

    private var tlsMode: Binding<DatabaseTLSMode?> {
        Binding(get: { draft.connection.tls?.mode }, set: { mode in
            if let mode {
                var tls = draft.connection.tls ?? DatabaseTLS(mode: mode)
                tls.mode = mode
                draft.connection.tls = tls
            } else {
                draft.connection.tls = nil
            }
            draft.test = .idle
        })
    }

    private func tlsFile(_ path: WritableKeyPath<DatabaseTLS, String?>) -> Binding<String> {
        Binding(get: { draft.connection.tls?[keyPath: path] ?? "" }, set: { value in
            guard var tls = draft.connection.tls else { return }
            tls[keyPath: path] = value.isEmpty ? nil : value
            draft.connection.tls = tls
        })
    }

    private func initStatement(_ index: Int) -> Binding<String> {
        Binding(get: { draft.connection.initStatements.indices.contains(index) ? draft.connection.initStatements[index] : "" }, set: { value in
            guard draft.connection.initStatements.indices.contains(index) else { return }
            draft.connection.initStatements[index] = value
        })
    }

    private func optionKey(_ index: Int) -> Binding<String> {
        Binding(get: { draft.connection.options.indices.contains(index) ? draft.connection.options[index].key : "" }, set: { value in
            guard draft.connection.options.indices.contains(index) else { return }
            draft.connection.options[index].key = value
        })
    }

    private func optionValue(_ index: Int) -> Binding<String> {
        Binding(get: { draft.connection.options.indices.contains(index) ? draft.connection.options[index].value : "" }, set: { value in
            guard draft.connection.options.indices.contains(index) else { return }
            draft.connection.options[index].value = value
        })
    }

    /// The environment section's caption: what the marking does, next to the target's.
    private var environmentCaption: String {
        let own = draft.connection.environmentMarking
        guard let scope = draft.connection.scope else {
            // #142: one connection, many targets: each SQL tab's target counts too.
            return own == .production
                ? "A production connection asks before every statement, Run All, and Load Schema, on every target. The SQL bar shows its badge, and Run History marks its runs as production."
                : "Runs use the stricter of this and the SQL tab's target's marking, so on a production target every statement asks too. Mark a connection to a live database as production to get a confirmation everywhere. The colour marks the connection in the SQL bar."
        }
        let target = model.library.environment(for: scope)
        let targetName = model.targetLabel(scope)
        if own == .production {
            return target == .production
                ? "\(targetName) is production too. Every statement, Run All, and Load Schema on this connection asks first."
                : "A production connection asks before every statement, Run All, and Load Schema, even though \(targetName) is \(target.displayName.lowercased()). The SQL bar shows its badge, and Run History marks its runs as production."
        }
        if target.strictness > own.strictness {
            return "Runs use the stricter marking: \(targetName) is \(target.displayName.lowercased()), so this connection is treated as \(target.displayName.lowercased()) there. The colour marks the connection in the SQL bar."
        }
        return "Runs use the stricter of this and \(targetName)'s marking. Mark a connection to a live database as production to get a confirmation before every SQL run. The colour marks the connection in the SQL bar."
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
            caption(draft.connection.driver.family == .redis
                    ? "Test Connection opens the connection from \(model.openedFromLabel(draft.connection)), sends PING, and reports the Redis version, the database, the user, and whether the connection is encrypted."
                    : "Test Connection opens the connection from \(model.openedFromLabel(draft.connection)), runs its init statements, and reports the server's version, the database, the user, whether the connection is encrypted, and the PHP's drivers.")
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
                if let details = testDetails(info) {
                    caption(details)
                        .textSelection(.enabled)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("db-test-result")
                // #142: a missing PHP or driver on this Mac: Runlet's PHP has these drivers
                // (#184: not SQL Server's, nor a custom DSN's).
                if onThisMac, !model.hasRunletPHP, [.mysql, .pgsql, .sqlite, .mongodb, .redis].contains(draft.connection.driver) {
                    HStack(spacing: 8) {
                        Button("Download Runlet's PHP…") { model.showPHPSettings() }
                            .accessibilityIdentifier("db-get-runlet-php")
                        caption("It has pdo_mysql, pdo_pgsql, and pdo_sqlite, and Runlet uses it for connections from this Mac.")
                    }
                }
            }
        }
    }

    /// "Opened by PHP 8.4.25 on Shop in 12 ms (PDO drivers: mysql, pgsql, sqlite). Encrypted:
    /// TLSv1.3, TLS_AES_256_GCM_SHA384. 2 init statements ran." From this Mac (#142): "Opened
    /// from this Mac (Runlet's PHP 8.5.8) in 12 ms …".
    private func testDetails(_ info: SQLConnectionTestInfo) -> String? {
        var parts: [String] = []
        let elapsed = info.connectMs.map { String(format: " in %.0f ms", $0) } ?? ""
        let drivers = info.pdoDrivers.map { $0.isEmpty ? " (no PDO drivers)" : " (PDO drivers: \($0.joined(separator: ", ")))" } ?? ""
        if let place = info.openedFrom, place.hasPrefix("this Mac") {
            parts.append("Opened from \(place)\(elapsed)\(drivers).")
            // #184: why not the first PHP: "Runlet's PHP 8.5.8 comes first but has neither …".
            if let reason = model.localConnectionChoice(for: draft.connection)?.reason { parts.append(reason) }
        } else if let php = info.phpVersion {
            parts.append("Opened by PHP \(php) on \(info.openedFrom ?? model.targetLabel(draft.connection.scope ?? .sandbox))\(elapsed)\(drivers).")
        }
        if let tls = info.tlsDetail {
            parts.append("Encrypted: \(tls).")
        } else if info.tls == false {
            parts.append("The connection isn't encrypted.")
        }
        if let count = info.initStatements {
            parts.append(count == 1 ? "1 init statement ran." : "\(count) init statements ran.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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

    /// Where the host name or file is resolved: this Mac, the container, or the server.
    private var whereItConnects: String {
        if draft.connection.usesSSHTunnel {
            let name = model.library.tunnelProfile(of: draft.connection).map { "“\($0.name)”" } ?? "the SSH profile"
            return "Host and port as the server of \(name) sees them: a name only that server resolves (a Docker service, an internal host) works, and localhost means that server."
        }
        if onThisMac { return "Runlet opens the connection from this Mac, so localhost means this Mac." }
        return switch draft.connection.scope ?? .sandbox {
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

/// A target's saved connections (#138), or those of all targets (#142), with New
/// Connection…, Edit…, Duplicate, and Delete: in the project's options, the Docker and SSH
/// profile forms, Edit Connections…, and Settings ▸ Databases.
struct DatabaseConnectionsList: View {
    @Environment(AppModel.self) private var model
    /// The target whose connections it lists; nil for those of all targets (#142).
    let scope: TargetRef?
    /// False for a profile that isn't saved yet: its connections can be added once it is.
    var targetIsSaved = true
    /// A target's list mentions how many connections of all targets its SQL tabs also offer.
    var mentionsAllTargets = true
    @State private var editing: DatabaseConnectionDraft?

    init(target: TargetRef, targetIsSaved: Bool = true, mentionsAllTargets: Bool = true) {
        scope = target
        self.targetIsSaved = targetIsSaved
        self.mentionsAllTargets = mentionsAllTargets
    }

    /// The connections of all targets (#142).
    init(allTargets: Void) {
        scope = nil
    }

    var body: some View {
        let connections = model.library.databaseConnections(scope: scope)
        VStack(alignment: .leading, spacing: 8) {
            if let scope, !TargetLibrary.supportsDatabaseConnections(scope) {
                Text("The Laravel sandbox has no connections of its own: its SQL tabs offer the connections of all targets (Settings ▸ Databases).").foregroundStyle(.secondary)
            } else if !targetIsSaved {
                Text("Save the profile first, then add its database connections.").foregroundStyle(.secondary)
            } else {
                if connections.isEmpty {
                    Text(scope == nil
                         ? "No connections for all targets. Save one to query a database from every SQL tab, the sandbox's too: it opens from this Mac, with Runlet's PHP."
                         : "No saved connections. SQL tabs use the application's own connections, which need no credentials. Save one to query a database the application doesn't configure.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(connections) { connection in
                    row(connection)
                }
                HStack {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("New Connection…") { editing = model.newConnectionDraft(for: scope) }
                        .accessibilityIdentifier(scope == nil ? "db-new-all-targets-connection" : "db-new-connection")
                }
            }
        }
        .sheet(item: $editing) { draft in
            DatabaseConnectionEditor(draft: draft)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(scope == nil ? "db-all-targets-connections" : "db-connections")
    }

    /// "Passwords stay in the macOS Keychain.", plus the connections of all targets a target's
    /// SQL tabs also offer (#142).
    private var footnote: String {
        let shared = model.allTargetsDatabaseConnections.count
        guard scope != nil, mentionsAllTargets, shared > 0 else { return "Passwords stay in the macOS Keychain." }
        return "Passwords stay in the macOS Keychain. SQL tabs also offer \(shared == 1 ? "1 connection" : "\(shared) connections") for all targets (Settings ▸ Databases)."
    }

    private func row(_ connection: DatabaseConnection) -> some View {
        HStack(spacing: 10) {
            DatabaseDriverIcon(driver: connection.driver)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(connection.name)
                    SavedConnectionBadges(connection: connection)
                }
                Text(connection.summary + (connection.user.isEmpty ? "" : " · user \(connection.user)") + model.savedConnectionPlaceDetail(connection, inList: true))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if connection.driver.usesCredentials {
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

/// Edit Connections… from the SQL bar: the target's saved connections, and those of all
/// targets (#142), in a sheet.
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
                    Text("Saved for \(model.targetLabel(target)), and for all targets. The application's own connections need no entry here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if TargetLibrary.supportsDatabaseConnections(target) {
                        Text(model.targetLabel(target)).font(.headline)
                        DatabaseConnectionsList(target: target, mentionsAllTargets: false)
                        Divider()
                    }
                    Text("All targets").font(.headline)
                    DatabaseConnectionsList(allTargets: ())
                }
                .padding(20)
            }
            Divider()
            HStack {
                TablePlusImportButton() // #188, behind its feature flag (#187)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 480)
    }
}

/// A small symbol per driver.
struct DatabaseDriverIcon: View {
    let driver: DatabaseDriverKind

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .frame(width: 18)
            .help(driver.displayName)
    }

    private var symbol: String {
        switch driver {
        case .sqlite: "doc.text"
        case .custom: "chevron.left.forwardslash.chevron.right"
        case .redis: "square.stack.3d.up.fill" // #190
        case .mongodb: "leaf.fill" // #191
        default: "cylinder.split.1x2"
        }
    }

    private var color: Color {
        switch driver {
        case .pgsql: .blue
        case .mysql: .orange
        case .sqlsrv: .red
        case .custom: .gray
        case .sqlite: .teal
        case .redis: .red // #190
        case .mongodb: .mongoDB // #191
        }
    }
}
