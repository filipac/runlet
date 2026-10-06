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
    /// The Tests group's Filter… and (Docker, SSH) File… prompts, and what was typed last.
    @State private var testsPrompt: TestsPrompt.Kind?
    @State private var testFilter = ""
    @State private var testFile = ""
    /// What the list's rows and context menu do (#320): through this box, so rows hold no closures.
    @State private var rowActions = InspectorActions<RowAction>()

    enum RowAction {
        case run(ProjectCommand)
        case setExpanded(group: String, Bool)
    }

    init(tab: TabModel? = nil, onClose: (() -> Void)? = nil) {
        self.tab = tab
        self.onClose = onClose
    }

    private var activeTab: TabModel? { tab ?? window?.selectedTab }

    var body: some View {
        let _ = inspectorRenderTick("commands")
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
        // A Tests prompt belongs to the target it was opened for.
        .onChange(of: activeTab.map { "\($0.id)|\($0.target.stableKey)" }) { testsPrompt = nil }
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
            testsGroup(tab)
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

    /// Tests group (N37, #40): run all tests, one file, or a `--filter` in a terminal tab. Like
    /// Open REPL it works in every state (it doesn't need the list, which boots the
    /// application), and nothing runs until a button is clicked. Hidden for a local project or
    /// the sandbox without a test runner and tests; Docker and SSH targets choose on the target.
    /// Disabled on production targets, with the reason.
    @ViewBuilder
    private func testsGroup(_ tab: TabModel) -> some View {
        let target = tab.target
        if model.offersTests(for: target) {
            let detection = model.testDetection(for: target)
            let production = model.isProduction(target)
            let launching = model.projectCommands.launching.contains(AppModel.testsLaunchKey(target))
            let needsLogin = loginNeeded(tab) != nil
            let local = model.testsLocalDirectory(for: target) != nil
            let place = target.isSSH ? "on the server" : "in the container"
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Tests")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(detection?.summary ?? "php artisan test, Pest, or PHPUnit, chosen \(place)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("commands-tests-runner")
                    Spacer(minLength: 0)
                    if launching {
                        ProgressView().controlSize(.mini)
                    }
                }
                HStack(spacing: 6) {
                    Button {
                        model.runTests(.all, in: tab, window: window)
                    } label: {
                        Label("Run All", systemImage: "play.fill")
                    }
                    .help(testsHelp(tab, detection: detection, needsLogin: needsLogin, action: "Run every test suite in phpunit.xml in a terminal tab"))
                    .accessibilityLabel("Run all tests")
                    .accessibilityIdentifier("commands-tests-all")
                    Button {
                        if local { model.chooseTestFile(in: tab, window: window) } else { testsPrompt = testsPrompt == .file ? nil : .file }
                    } label: {
                        Label("File…", systemImage: "doc.text")
                    }
                    .help(testsHelp(tab, detection: detection, needsLogin: needsLogin, action: local ? "Choose a test file in the project's folder and run it in a terminal tab" : "Type the path of a test file \(place) and run it in a terminal tab"))
                    .accessibilityLabel("Run a test file")
                    .accessibilityIdentifier("commands-tests-file")
                    Button {
                        testsPrompt = testsPrompt == .filter ? nil : .filter
                    } label: {
                        Label("Filter…", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .help(testsHelp(tab, detection: detection, needsLogin: needsLogin, action: "Run the tests whose name matches a filter (--filter) in a terminal tab"))
                    .accessibilityLabel("Run tests matching a filter")
                    .accessibilityIdentifier("commands-tests-filter")
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .disabled(production || launching || needsLogin)
                if let kind = testsPrompt, !production {
                    TestsPrompt(kind: kind, runner: detection?.runner, directory: model.testsWorkingDirectory(for: target), place: place, text: kind == .filter ? $testFilter : $testFile) { value in
                        testsPrompt = nil
                        model.runTests(kind == .filter ? .filter(value) : .file(value), in: tab, window: window)
                    } cancel: {
                        testsPrompt = nil
                    }
                    .disabled(launching || needsLogin)
                }
                if production {
                    Label(ProjectTests.productionReason, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("commands-tests-production")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("commands-tests")
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .debugTestsPrompt)) { note in
                // `tests-prompt:filter|file[:<text>]` (screenshots): opens a prompt with that text.
                let kind = (note.userInfo?["kind"] as? String) == "file" ? TestsPrompt.Kind.file : .filter
                let text = note.userInfo?["text"] as? String ?? ""
                if kind == .file { testFile = text } else { testFilter = text }
                testsPrompt = kind
            }
            #endif
        }
    }

    private func testsHelp(_ tab: TabModel, detection: ProjectTests.Detection?, needsLogin: Bool, action: String) -> String {
        if model.isProduction(tab.target) { return ProjectTests.productionReason }
        var text = action
        if let detection {
            text += ": \(detection.runner.commandLine) in the project's folder, with this target's PHP."
        } else {
            text += tab.target.isSSH ? " on the server" : " in the container"
            text += ": php artisan test when Laravel's Collision is installed, else vendor/bin/pest, else vendor/bin/phpunit, with a phpunit.xml."
        }
        if needsLogin { text += " Log in first with Connect…: this host uses a password or a one-time code." }
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

    /// The list, which SwiftUI updates only when its rows change (#320): the header, the search
    /// field's focus, runs, and other tabs on the same target don't reach it.
    private func list(_ catalog: ProjectCommandCatalog, tab: TabModel) -> some View {
        let rows = ProjectCommandList(catalog: catalog, search: search, collapsed: collapsed, launching: model.projectCommands.launching)
        let actions = rowActions.handle { action in
            switch action {
            case .run(let command):
                model.runProjectCommand(command, in: tab)
            case .setExpanded(let group, let expanded):
                if expanded { collapsed.remove(group) } else { collapsed.insert(group) }
            }
        }
        return StableInspectorList(CommandListValue(rows: rows, remoteHost: remoteHost(tab))) { value in
            CommandList(value: value, selection: $selection, actions: actions)
        }
        .overlay {
            if catalog.commands.isEmpty, catalog.errors.isEmpty {
                ContentUnavailableView {
                    Label("No Commands", systemImage: "terminal")
                } description: {
                    Text(emptyDescription(catalog))
                }
            } else if rows.sections.isEmpty, !catalog.commands.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private func emptyDescription(_ catalog: ProjectCommandCatalog) -> String {
        let driver = catalog.driverName ?? "This project's driver"
        return "\(driver) lists no commands and composer.json has no scripts. A project driver in .runlet/ can add commands with commands() and hostCommands(); see docs/drivers.md."
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

/// What the Commands list shows (#320); the list is evaluated again only when it changes.
private nonisolated struct CommandListValue: Equatable, Sendable {
    var rows: ProjectCommandList
    /// The SSH host the commands run on (rows show a server icon).
    var remoteHost: String?
}

/// The commands, grouped, with a context menu; double-click or ↩ runs one.
private struct CommandList: View {
    let value: CommandListValue
    @Binding var selection: ProjectCommand.ID?
    let actions: InspectorActions<ProjectCommandsView.RowAction>

    var body: some View {
        let _ = inspectorRenderTick("commands-list")
        List(selection: $selection) {
            ForEach(value.rows.sections) { section in
                Section(isExpanded: Binding(get: { section.isExpanded }, set: { actions(.setExpanded(group: section.id, $0)) })) {
                    ForEach(section.rows) { row in
                        CommandRow(command: row.command, isLaunching: row.isLaunching, remoteHost: value.remoteHost, actions: actions)
                            .equatable()
                            .tag(row.id)
                    }
                } header: {
                    HStack {
                        Text(section.title)
                        Text("\(section.count)")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("commands-list")
        .contextMenu(forSelectionType: ProjectCommand.ID.self) { ids in
            if let command = value.rows.command(ids.first) {
                Button("Run in Terminal") { actions(.run(command)) }
                Divider()
                Button("Copy Command") { Pasteboard.copy(command.commandLine) }
                Button("Copy Name") { Pasteboard.copy(command.name) }
            }
        } primaryAction: { ids in
            if let command = value.rows.command(ids.first) { actions(.run(command)) }
        }
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

/// One command: name, description, and a Run button. Values only (#320), so SwiftUI draws it
/// again only when its command or launch state changes.
private struct CommandRow: View, Equatable {
    let command: ProjectCommand
    let isLaunching: Bool
    /// The SSH host the command runs on (nil for local, sandbox, and Docker targets).
    var remoteHost: String?
    let actions: InspectorActions<ProjectCommandsView.RowAction>

    nonisolated static func == (lhs: CommandRow, rhs: CommandRow) -> Bool {
        lhs.command == rhs.command && lhs.isLaunching == rhs.isLaunching && lhs.remoteHost == rhs.remoteHost && lhs.actions === rhs.actions
    }

    var body: some View {
        let _ = inspectorRenderTick("command-row")
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
                Button {
                    actions(.run(command))
                } label: {
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

/// The Tests group's Filter… prompt, and File… for Docker and SSH targets (local projects use
/// an open panel), shown inline under its buttons: one line, passed to the runner as one
/// argument. Return runs, Escape cancels.
struct TestsPrompt: View {
    enum Kind {
        case filter
        case file
    }

    let kind: Kind
    /// The runner, when known on this Mac (nil: the target chooses).
    let runner: ProjectTests.Runner?
    /// The project's directory on the target, for File….
    let directory: String?
    /// "on the server" or "in the container".
    let place: String
    @Binding var text: String
    let run: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    private var value: String? { ProjectTests.cleanedInput(text) }

    private var action: ProjectTests.Action? {
        value.map { kind == .filter ? .filter($0) : .file($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind == .filter ? "Run the tests matching" : "Run the test file")
                .font(.caption.weight(.medium))
            TextField(kind == .filter ? "Test or class name, or a pattern" : "tests/Feature/ExampleTest.php", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand(perform: cancel)
                .accessibilityIdentifier(kind == .filter ? "tests-filter-field" : "tests-file-field")
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Text(preview(action))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tests-prompt-preview")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Run", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(value == nil)
                    .accessibilityIdentifier("tests-prompt-run")
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.08)))
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tests-prompt")
    }

    private var explanation: String {
        switch kind {
        case .filter:
            "Passed as --filter: a test method or class name (test_checkout_total, OrderTest), or a regular expression. Pest also matches its test descriptions."
        case .file:
            "Relative to \(directory ?? "the project's folder"), or an absolute path \(place)."
        }
    }

    /// `php artisan test '--filter=…'`, or the arguments alone when the target chooses the runner.
    private func preview(_ action: ProjectTests.Action) -> String {
        if let runner { return ProjectTests.commandLine(runner, action: action) }
        return "… " + action.arguments.map(RemoteShell.quote).joined(separator: " ")
    }

    private func submit() {
        guard let value else { return }
        run(value)
    }
}

#if DEBUG
extension Notification.Name {
    /// DEBUG step `tests-prompt:filter|file[:<text>]`: the Commands pane opens that Tests prompt.
    static let debugTestsPrompt = Notification.Name("RunletDebugTestsPrompt")
}
#endif
