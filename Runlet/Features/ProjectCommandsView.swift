import AppKit
import RunletCore
import RunletExecution
import SwiftUI

/// The Commands panel: every command the active tab's target offers (Artisan or
/// `bin/console` commands, a `.runlet` project driver's own commands and host commands,
/// Composer scripts), searchable and grouped, each with a Run button that opens it in a
/// terminal.
///
/// Listing commands boots the user's application, so it happens only while this panel is
/// visible: once per target that was never loaded (when the panel appears, or when the
/// active tab or its target changes to one not listed yet), and when the user presses Load
/// or Refresh. SSH hosts never list by themselves (`AppModel.listsCommandsAutomatically`).
/// A target whose listing failed is not retried by itself. Keep the view mounted across tab
/// switches (do not `.id()` it per tab).
struct ProjectCommandsView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window: WindowModel?
    /// The tab whose target is listed; nil uses the window's selected tab.
    var tab: TabModel?
    /// Shows a close button (and handles Escape) when set, e.g. in a sheet.
    var onClose: (() -> Void)?

    @State private var search = ""
    @State private var selection: ProjectCommand.ID?
    @State private var collapsed: Set<String> = []
    @FocusState private var searchFocused: Bool

    init(tab: TabModel? = nil, onClose: (() -> Void)? = nil) {
        self.tab = tab
        self.onClose = onClose
    }

    private var activeTab: TabModel? { tab ?? window?.selectedTab }

    var body: some View {
        Group {
            if let tab = activeTab {
                content(for: tab)
            } else {
                ContentUnavailableView("No Tab", systemImage: "terminal", description: Text("Open a tab to list its project's commands."))
            }
        }
        // Fill the panel and pin to the top (a taller inspector must not center the content).
        // No minimum width: the inspector column can be narrower (260 pt), and a minimum
        // above its own sends the split view into a constraint-update loop (AppKit throws).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { searchFocused = true }
        // Runs when the panel appears and whenever the listed target changes (new tab,
        // another project): a target never listed loads once; failures are not retried.
        .task(id: activeTab.map { "\($0.id)|\($0.target.stableKey)" }) {
            if let tab = activeTab, case .idle = model.commandsState(for: tab.target), model.listsCommandsAutomatically(for: tab.target) {
                model.loadCommands(for: tab)
            }
        }
        .onExitCommand { onClose?() }
    }

    @ViewBuilder
    private func content(for tab: TabModel) -> some View {
        let state = model.commandsState(for: tab.target)
        VStack(spacing: 0) {
            header(tab: tab, state: state)
            Divider()
            mainContent(tab: tab, state: state)
            if let notice = model.projectCommands.notice {
                Divider()
                noticeBar(notice)
            }
        }
    }

    // MARK: Header

    private func header(tab: TabModel, state: ProjectCommandsState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.targetSymbol(tab.target))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Commands").font(.headline)
                    Text(model.targetLabel(tab.target))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let catalog = state.catalog {
                        Text("\(summary(catalog)) · \(Text(catalog.loadedAt, style: .relative)) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(catalog.driverFile.map { "Driver: \($0)" } ?? "")
                    }
                }
                Spacer(minLength: 4)
                if state.isLoading {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelLoadingCommands(for: tab.target) }
                        .controlSize(.small)
                        .accessibilityIdentifier("commands-cancel")
                } else {
                    Button {
                        model.loadCommands(for: tab)
                    } label: {
                        Label(state.catalog == nil ? "Load" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Boot \(model.targetLabel(tab.target)) and list its commands again (runs the application's bootstrap code)")
                    .accessibilityIdentifier("commands-refresh")
                }
                if case .ssh(let id) = tab.target, let profile = model.library.sshProfile(id) {
                    Button {
                        model.openSSHShell(for: tab, in: window)
                    } label: {
                        Image(systemName: "apple.terminal")
                    }
                    .controlSize(.small)
                    .help("\(model.sshShellTitle(profile)): a login shell in \(profile.remoteDirectory)")
                    .accessibilityLabel(model.sshShellTitle(profile))
                    .accessibilityIdentifier("commands-ssh-shell")
                }
                if let onClose {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .accessibilityLabel("Close")
                }
            }
            replRow(tab)
            if let variables = model.driverVariables[tab.target.stableKey], !variables.isEmpty {
                DriverVariablesStrip(variables: variables) { name in
                    tab.editor.insertAtSelection("$" + name)
                }
            }
            CommandSearchField(text: $search, focused: $searchFocused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Open REPL (N19, #32): the target's own Tinker, PsySH, or `php -a` in a terminal tab.
    /// Offered in every state: it doesn't need the list (listing boots the application), and
    /// nothing starts until it is clicked.
    private func replRow(_ tab: TabModel) -> some View {
        let kind = model.replKind(for: tab.target)
        let launching = model.projectCommands.launching.contains(AppModel.replLaunchKey(tab.target))
        let needsLogin = loginNeeded(tab) != nil
        let chooser = tab.target.isSSH ? "on the server" : "in the container"
        return HStack(spacing: 8) {
            Button {
                model.openREPL(for: tab, in: window)
            } label: {
                Label("Open REPL", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .controlSize(.small)
            .disabled(launching || needsLogin)
            .help(replHelp(tab, kind: kind, needsLogin: needsLogin))
            .accessibilityIdentifier("commands-repl")
            if launching {
                ProgressView().controlSize(.small)
            }
            Text(kind.map { "\($0.displayName) · \($0.commandLine)" } ?? "Tinker, PsySH, or php -a, chosen \(chooser)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("commands-repl-kind")
            Spacer(minLength: 0)
        }
    }

    private func replHelp(_ tab: TabModel, kind: ProjectREPL.Kind?, needsLogin: Bool) -> String {
        var text: String
        if let kind {
            text = "Open \(kind.displayName) in a terminal tab: \(kind.commandLine) in the project's folder, with this target's PHP."
            if kind == .phpShell { text += " The project has neither Tinker (laravel/tinker) nor PsySH (vendor/bin/psysh)." }
        } else {
            text = "Open the project's REPL in a terminal tab \(tab.target.isSSH ? "on the server" : "in the container"): php artisan tinker when Tinker is installed, else vendor/bin/psysh, else php -a."
        }
        text += " Each line runs in the same session, so variables carry over."
        if needsLogin { text += " Log in first with Connect…: this host uses a password or a one-time code." }
        if model.isProduction(tab.target) { text += " This target is production, so Runlet asks first." }
        return text
    }

    /// "Laravel 13.34.0 · 125 commands"
    private func summary(_ catalog: ProjectCommandCatalog) -> String {
        var parts: [String] = []
        if let driver = catalog.driverName {
            parts.append([driver, catalog.frameworkVersion].compactMap { $0 }.joined(separator: " "))
        }
        parts.append(catalog.commands.count == 1 ? "1 command" : "\(catalog.commands.count) commands")
        return parts.joined(separator: " · ")
    }

    // MARK: Body

    @ViewBuilder
    private func mainContent(tab: TabModel, state: ProjectCommandsState) -> some View {
        switch state {
        case .idle:
            ContentUnavailableView {
                Label("Commands Not Loaded", systemImage: "terminal")
            } description: {
                Text(idleDescription(tab))
            } actions: {
                if let profileId = loginNeeded(tab) {
                    Button("Connect…") { model.connectSSH(profileId, in: window) }
                        .accessibilityIdentifier("commands-connect")
                } else {
                    Button(loadTitle(tab)) { model.loadCommands(for: tab) }
                        .accessibilityIdentifier("commands-load")
                }
            }
        case .loading(_, nil):
            VStack(spacing: 10) {
                ProgressView()
                Text("Booting \(model.targetLabel(tab.target)) to list its commands…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .failed(let message, nil):
            ContentUnavailableView {
                Label("Could Not List Commands", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { model.loadCommands(for: tab) }
            }
        case .loading(_, let catalog?), .loaded(let catalog), .failed(_, let catalog?):
            VStack(spacing: 0) {
                if case .failed(let message, _) = state {
                    ProblemBanner(text: catalog.driverListed ? "Refresh failed: \(message)" : "Could not list the project's commands (host commands are still available): \(message)")
                }
                if let error = catalog.errors.first {
                    ProblemBanner(text: problemText(error, catalog: catalog))
                }
                ForEach(catalog.hostErrors, id: \.self) { error in
                    ProblemBanner(text: error)
                }
                list(catalog, tab: tab)
            }
        }
    }

    private func idleDescription(_ tab: TabModel) -> String {
        if case .ssh(let id) = tab.target, let profile = model.library.sshProfile(id) {
            var text = "Runlet boots \(profile.name) on \(profile.destinationLabel) in a fresh PHP process (its bootstrap code runs on the server, as for a snippet) to list its commands. Each command then runs on the server in a terminal tab; host commands run on this Mac in the local folder."
            if loginNeeded(tab) != nil { text += "\n\nLog in first: this host uses a password or a one-time code." }
            if profile.environment == .production { text += "\n\nThis host is marked as production, so listing and every command ask first." }
            return text
        }
        return "Runlet boots \(model.targetLabel(tab.target)) in a fresh PHP process (its bootstrap code runs, as for a snippet) to list Artisan or console commands, project driver commands, and Composer scripts."
    }

    /// The SSH profile to Connect… first: a password or 2FA host that isn't logged in.
    private func loginNeeded(_ tab: TabModel) -> UUID? {
        guard case .ssh(let id) = tab.target, let profile = model.library.sshProfile(id), profile.authentication == .interactive,
              model.sshStatus(id) != .connected else { return nil }
        return id
    }

    /// "app-prod" when the tab's commands run on an SSH host (rows show a server icon).
    private func remoteHost(_ tab: TabModel) -> String? {
        guard case .ssh(let id) = tab.target, let profile = model.library.sshProfile(id) else { return nil }
        return profile.destinationLabel
    }

    private func loadTitle(_ tab: TabModel) -> String {
        if case .ssh(let id) = tab.target, let profile = model.library.sshProfile(id) {
            return "List Commands on \(profile.host)"
        }
        return "Load Commands"
    }

    private func problemText(_ error: RunErrorInfo, catalog: ProjectCommandCatalog) -> String {
        let onlyComposer = catalog.commands.allSatisfy { $0.origin == .composer }
        let prefix = catalog.driverListed ? "" : (catalog.commands.isEmpty ? "The application could not list its commands. " : (onlyComposer ? "The application could not list its commands; only Composer scripts are shown. " : "The application could not list its commands; host commands and Composer scripts are shown. "))
        return prefix + error.message
    }

    private func list(_ catalog: ProjectCommandCatalog, tab: TabModel) -> some View {
        let groups = catalog.groups(matching: search)
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        return List(selection: $selection) {
            ForEach(groups) { group in
                Section(isExpanded: Binding(
                    get: { searching || !collapsed.contains(group.id) },
                    set: { expanded in
                        if expanded { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                    }
                )) {
                    ForEach(group.commands) { command in
                        CommandRow(command: command, isLaunching: model.projectCommands.launching.contains(command.id), remoteHost: remoteHost(tab)) {
                            model.runProjectCommand(command, in: tab)
                        }
                        .tag(command.id)
                    }
                } header: {
                    HStack {
                        Text(group.title)
                        Text("\(group.commands.count)")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("commands-list")
        .contextMenu(forSelectionType: ProjectCommand.ID.self) { ids in
            if let command = command(ids.first, in: catalog) {
                Button("Run in Terminal") { model.runProjectCommand(command, in: tab) }
                Divider()
                Button("Copy Command") { copy(command.commandLine) }
                Button("Copy Name") { copy(command.name) }
            }
        } primaryAction: { ids in
            if let command = command(ids.first, in: catalog) { model.runProjectCommand(command, in: tab) }
        }
        .overlay {
            if catalog.commands.isEmpty, catalog.errors.isEmpty {
                ContentUnavailableView {
                    Label("No Commands", systemImage: "terminal")
                } description: {
                    Text(emptyDescription(catalog))
                }
            } else if groups.isEmpty, !catalog.commands.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private func emptyDescription(_ catalog: ProjectCommandCatalog) -> String {
        let driver = catalog.driverName ?? "This project's driver"
        return "\(driver) lists no commands and composer.json has no scripts. A project driver in .runlet/ can add commands with commands() and hostCommands(); see docs/drivers.md."
    }

    private func command(_ id: ProjectCommand.ID?, in catalog: ProjectCommandCatalog) -> ProjectCommand? {
        guard let id else { return nil }
        return catalog.commands.first { $0.id == id }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Notices

    private func noticeBar(_ notice: ProjectCommandNotice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch notice.kind {
            case .copied(let text):
                Image(systemName: "doc.on.clipboard").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("The terminal is not available, so “\(notice.commandName)” was copied. Paste it into a terminal:")
                        .font(.caption)
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Could not run “\(notice.commandName)”: \(message)")
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            Spacer(minLength: 0)
            Button {
                model.projectCommands.notice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }
}

/// The driver's snippet variables (from `variables()`), learned from the last run or command
/// listing on this target. Clicking one inserts it at the editor's cursor.
private struct DriverVariablesStrip: View {
    let variables: [String: String]
    let insert: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Variables")
                .font(.caption)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(variables.keys.sorted(), id: \.self) { name in
                    let type = variables[name] ?? ""
                    Button {
                        insert(name)
                    } label: {
                        HStack(spacing: 3) {
                            Text("$" + name).font(.system(.caption, design: .monospaced).weight(.medium))
                            if !type.isEmpty {
                                Text(Self.shortType(type)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("$\(name)\(type.isEmpty ? "" : ": \(type)"). Available in every snippet on this target; click to insert at the cursor.")
                    .accessibilityLabel("Insert $\(name)")
                    .accessibilityIdentifier("driver-variable-\(name)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("driver-variables")
    }

    /// "Slim\App" → "App"; scalar types unchanged.
    static func shortType(_ type: String) -> String {
        type.split(separator: "\\").last.map(String.init) ?? type
    }
}

/// A warning above the list; long messages (paths, stack details) stay readable.
private struct ProblemBanner: View {
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .help(text)
    }
}

/// One command: name, description, and a Run button.
private struct CommandRow: View {
    let command: ProjectCommand
    let isLaunching: Bool
    /// The SSH host the command runs on (nil for local, sandbox, and Docker targets).
    var remoteHost: String?
    let run: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let description = command.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if command.origin == .host {
                Image(systemName: "laptopcomputer")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Runs on this Mac, in the project's folder")
                    .accessibilityLabel("Runs on this Mac")
            } else if let remoteHost {
                Image(systemName: "server.rack")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Runs on \(remoteHost) over SSH, in a terminal tab")
                    .accessibilityLabel("Runs on \(remoteHost)")
            }
            if isLaunching {
                ProgressView().controlSize(.small)
            } else {
                Button(action: run) {
                    Image(systemName: command.needsInput ? "text.cursor" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(command.needsInput ? "Type “\(command.commandLine)” in a terminal to add its arguments" : "Run “\(command.commandLine)” in a terminal")
                .accessibilityLabel("Run \(command.name)")
                .accessibilityIdentifier("command-run-\(command.name)")
            }
        }
        .padding(.vertical, 2)
        .help(command.commandLine)
        .accessibilityElement(children: .contain)
    }
}

private struct CommandSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter commands", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .accessibilityIdentifier("commands-search")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.1)))
    }
}
