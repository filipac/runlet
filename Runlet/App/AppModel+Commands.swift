import AppKit
import Observation
import RunletCore
import RunletExecution

/// Loading state of one target's project commands.
enum ProjectCommandsState: Equatable {
    /// Never loaded. Nothing runs until the Commands panel opens or Refresh is pressed.
    case idle
    /// The runner is booting the project; `previous` stays visible meanwhile.
    case loading(since: Date, previous: ProjectCommandCatalog?)
    /// The runner finished. The catalog may still carry errors (e.g. the app could not
    /// boot, so only Composer scripts are listed).
    case loaded(ProjectCommandCatalog)
    /// The target could not be resolved or the runner could not start.
    case failed(message: String, previous: ProjectCommandCatalog?)

    var catalog: ProjectCommandCatalog? {
        switch self {
        case .idle: nil
        case .loading(_, let previous), .failed(_, let previous): previous
        case .loaded(let catalog): catalog
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// A message from launching a command, shown in the Commands panel.
struct ProjectCommandNotice: Equatable, Identifiable {
    enum Kind: Equatable {
        /// No terminal panel is available: the command was copied instead.
        case copied(String)
        case failed(String)
    }

    let id = UUID()
    var commandName: String
    var kind: Kind
}

/// Per-target project command caches (keyed by `TargetRef.stableKey`), kept for the app's
/// lifetime. Loading is explicit: listing commands boots the user's application.
@MainActor
@Observable
final class ProjectCommandsStore {
    var states: [String: ProjectCommandsState] = [:]
    /// Commands whose target is being resolved before they open in a terminal.
    var launching: Set<String> = []
    var notice: ProjectCommandNotice?
    @ObservationIgnored var tasks: [String: Task<Void, Never>] = [:]

    private static var stores: [ObjectIdentifier: ProjectCommandsStore] = [:]

    static func shared(for model: AppModel) -> ProjectCommandsStore {
        let key = ObjectIdentifier(model)
        if let store = stores[key] { return store }
        let store = ProjectCommandsStore()
        stores[key] = store
        return store
    }
}

extension AppModel {
    var projectCommands: ProjectCommandsStore { ProjectCommandsStore.shared(for: self) }

    /// Cached commands state for a target (never triggers loading).
    func commandsState(for target: TargetRef) -> ProjectCommandsState {
        projectCommands.states[target.stableKey] ?? .idle
    }

    /// Cached commands for a target, if they were loaded.
    func commands(for target: TargetRef) -> ProjectCommandCatalog? {
        commandsState(for: target).catalog
    }

    /// Whether the Commands panel lists a target's commands as soon as it shows it. Listing
    /// boots the application, so SSH hosts and production targets list only when the user
    /// asks (and production targets confirm first).
    func listsCommandsAutomatically(for target: TargetRef) -> Bool {
        !target.isSSH && !isProduction(target)
    }

    /// Lists the commands of `tab`'s target: resolves it like a run (Docker container
    /// resolution included; ambiguity or recreation asks the user and fails this load), then
    /// boots the project in a fresh runner. Executes project code, so call only on an explicit
    /// user action (opening the Commands panel, Refresh). Ignored while already loading.
    func loadCommands(for tab: TabModel) {
        let target = tab.target
        guard !commandsState(for: target).isLoading else { return }
        // Listing boots the application: production targets ask every time.
        guardProduction(.listCommands, target: target, text: "List the commands of \(targetLabel(target)) (boots the application)", in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target else { return }
            self.startLoadingCommands(for: tab)
        }
    }

    func startLoadingCommands(for tab: TabModel) {
        let target = tab.target
        let key = target.stableKey
        let store = projectCommands
        let current = commandsState(for: target)
        guard !current.isLoading else { return }
        let previous = current.catalog
        store.states[key] = .loading(since: Date(), previous: previous)
        store.tasks[key] = Task {
            defer { store.tasks[key] = nil }
            do {
                let snapshot = try await self.snapshot(for: tab)
                var catalog = try await self.engine.listCommands(target: snapshot)
                // Listing boots the project too: learn its variables for completion.
                if let variables = catalog.variables { self.learnDriverVariables(variables, for: target) }
                try await self.addHostCommands(to: &catalog, target: target)
                store.states[key] = .loaded(catalog)
                // #271: the Logs window finds the driver's log files from now on, also after a relaunch.
                self.rememberDriverLogPaths(catalog, for: target)
                // So does the inspector the driver's own tabs.
                self.rememberDriverInspectorTabs(catalog, for: target)
            } catch is CancellationError {
                store.states[key] = previous.map { .loaded($0) } ?? .idle
            } catch {
                // The target could not start (e.g. a stopped container), but host commands
                // run on this Mac: offer the last declared ones (`biker start`, …).
                var hostOnly = ProjectCommandCatalog()
                try? await self.addHostCommands(to: &hostOnly, target: target)
                let fallback = previous ?? (hostOnly.commands.isEmpty && hostOnly.hostErrors.isEmpty ? nil : hostOnly)
                store.states[key] = .failed(message: "\(error)", previous: fallback)
            }
        }
    }

    /// The folder on this Mac where a target's host commands run: the local project, the
    /// sandbox install, or a Docker or SSH profile's local folder (nil when it has none).
    func hostDirectory(for target: TargetRef) -> String? {
        func existing(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return nil }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
        }
        switch target {
        case .sandbox: return existing(sandbox?.installURL.path)
        case .local(let id): return existing(library.localProject(id)?.path)
        case .docker(let id): return existing(library.dockerProfile(id)?.localSourcePath)
        case .ssh: return existing(library.localFolder(for: target))
        }
    }

    /// Adds the driver's host commands to `catalog`: its static ones, and every command
    /// source listed now on this Mac (in the target's host folder, with the user's shell
    /// environment). Remembers the declaration per target; when this load did not reach the
    /// driver (`hostDeclared` is false), the remembered one is used.
    func addHostCommands(to catalog: inout ProjectCommandCatalog, target: TargetRef) async throws {
        let key = target.stableKey
        let declaration: HostCommandDeclaration
        if catalog.hostDeclared {
            declaration = HostCommandDeclaration(sources: catalog.hostSources, commands: catalog.hostCommands)
            let stored = declaration.isEmpty ? nil : declaration
            if hostCommandDeclarations[key] != stored {
                hostCommandDeclarations[key] = stored
                scheduleFactsSave()
            }
        } else {
            declaration = hostCommandDeclarations[key] ?? HostCommandDeclaration()
            catalog.hostSources = declaration.sources
            catalog.hostCommands = declaration.commands
        }
        guard !declaration.isEmpty else { return }

        let directory = hostDirectory(for: target)
        catalog.hostDirectory = directory
        var listed: [ProjectCommand] = []
        if !declaration.sources.isEmpty {
            if let directory {
                let environment = await HostShellEnvironment.shared.environment()
                let listings = await withTaskGroup(of: (Int, HostCommandLister.Listing).self) { group in
                    for (index, source) in declaration.sources.enumerated() {
                        group.addTask { (index, await HostCommandLister.list(source, directory: directory, environment: environment)) }
                    }
                    var results: [(Int, HostCommandLister.Listing)] = []
                    for await result in group { results.append(result) }
                    return results.sorted { $0.0 < $1.0 }.map(\.1)
                }
                try Task.checkCancellation()
                for (source, listing) in zip(declaration.sources, listings) {
                    listed += listing.commands
                    if let error = listing.error { catalog.hostErrors.append("\(source.name): \(error)") }
                }
            } else {
                let names = declaration.sources.map(\.name).joined(separator: ", ")
                catalog.hostErrors.append("\(names) run\(declaration.sources.count == 1 ? "s" : "") on this Mac in the project's folder, and this target has none. For a Docker or SSH profile, set its local folder in Settings ▸ Targets.")
            }
        }
        let driver = catalog.commands.filter { $0.origin == .driver }
        let composer = catalog.commands.filter { $0.origin == .composer }
        catalog.commands = driver + declaration.commands + listed + composer
    }

    /// Stops a load in progress (the runner process is stopped too).
    func cancelLoadingCommands(for target: TargetRef) {
        projectCommands.tasks[target.stableKey]?.cancel()
    }

    /// Opens `command` in a terminal for `tab`'s target, resolved now: the project directory
    /// for local and sandbox targets, `docker exec -it` into the profile's current container
    /// for Docker targets (never a different container; resolution problems are reported),
    /// and `ssh -t` into the profile's directory (or its container) for SSH hosts.
    /// Host commands open the user's shell in the target's folder on this Mac.
    /// Without a terminal panel, the command is copied to the pasteboard instead.
    func runProjectCommand(_ command: ProjectCommand, in tab: TabModel) {
        // Production targets ask before every command (no grace), host commands included.
        let target = tab.target
        guardProduction(.command, target: target, text: command.commandLine, runsOnThisMac: command.origin == .host, in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target else { return }
            self.launchProjectCommand(command, in: tab)
        }
    }

    private func launchProjectCommand(_ command: ProjectCommand, in tab: TabModel) {
        let store = projectCommands
        guard !store.launching.contains(command.id) else { return }
        store.launching.insert(command.id)
        Task {
            defer { store.launching.remove(command.id) }
            do {
                let request: TerminalRequest
                if command.origin == .host {
                    // Runs on this Mac: no container to resolve (works while it is stopped).
                    request = try ProjectCommandLauncher.hostTerminalRequest(for: command, directory: self.hostDirectory(for: tab.target))
                } else {
                    let snapshot = try await self.snapshot(for: tab)
                    request = try ProjectCommandLauncher.terminalRequest(for: command, target: snapshot, dockerExecutable: self.docker?.executable, ssh: self.sshClient)
                }
                if let openTerminal = self.openTerminal {
                    store.notice = nil
                    openTerminal(request)
                } else {
                    let text = ProjectCommandLauncher.shellText(request)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    store.notice = ProjectCommandNotice(commandName: command.name, kind: .copied(text))
                }
            } catch {
                store.notice = ProjectCommandNotice(commandName: command.name, kind: .failed("\(error)"))
            }
        }
    }
}

// MARK: - Open REPL (N19, #32)

extension AppModel {
    /// The key `ProjectCommandsStore.launching` holds while a target's REPL is being opened.
    static func replLaunchKey(_ target: TargetRef) -> String { "repl:" + target.stableKey }

    /// The REPL a target gets, when Runlet knows it before connecting: local projects and the
    /// sandbox are checked on this Mac (`ProjectREPL.kind(projectDirectory:)`). nil for Docker
    /// profiles and SSH hosts, which choose on the target as the REPL starts.
    func replKind(for target: TargetRef) -> ProjectREPL.Kind? {
        switch target {
        case .sandbox: sandbox.map { ProjectREPL.kind(projectDirectory: $0.installURL.path) }
        case .local(let id): library.localProject(id).map { ProjectREPL.kind(projectDirectory: $0.path) }
        case .docker, .ssh: nil
        }
    }

    /// Names the target in a REPL tab's title: "Sandbox", the project or Docker profile name,
    /// or the SSH host (with its container: "shop/app on app-prod").
    func replPlace(for target: TargetRef) -> String {
        switch target {
        case .sandbox: return "Sandbox"
        case .local(let id): return library.localProject(id)?.name ?? "project"
        case .docker(let id): return library.dockerProfile(id)?.name ?? "Docker"
        case .ssh(let id):
            guard let profile = library.sshProfile(id) else { return "SSH" }
            return profile.container.map { "\($0.identity.displayName) on \(profile.host)" } ?? profile.host
        }
    }

    /// What Open REPL starts, as the production confirmation shows it: the command line, or
    /// for Docker and SSH targets the order the target chooses in.
    func replPreview(for target: TargetRef) -> String {
        if let kind = replKind(for: target) { return kind.commandLine }
        let place = target.isSSH ? "server" : "container"
        return "The \(place) starts the first the project has:\n"
            + "php artisan tinker     Tinker (laravel/tinker)\n"
            + "php vendor/bin/psysh   PsySH\n"
            + "php -a                 PHP's interactive shell"
    }

    /// Open REPL: the target's own REPL (Tinker, else PsySH, else `php -a`) in a terminal tab,
    /// where state carries over from one input to the next. Resolved like a project command
    /// when it opens: the Docker container again (never a different one without asking), and an
    /// SSH host is reached only now, through the shared connection (a password or 2FA host must
    /// be connected with Connect… first). Call only from an explicit user action: opening,
    /// importing, or restoring code never opens a REPL. Production targets ask every time; the
    /// snippet-run grace doesn't apply, and confirming grants none.
    func openREPL(for tab: TabModel, in window: WindowModel? = nil) {
        let target = tab.target
        let window = window ?? self.window(containing: tab.id)
        guardProduction(.repl, target: target, text: replPreview(for: target), in: window) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target else { return }
            self.launchREPL(in: tab, window: window)
        }
    }

    private func launchREPL(in tab: TabModel, window: WindowModel?) {
        let store = projectCommands
        let target = tab.target
        let key = Self.replLaunchKey(target)
        guard !store.launching.contains(key) else { return }
        store.launching.insert(key)
        Task {
            defer { store.launching.remove(key) }
            do {
                let snapshot = try await self.snapshot(for: tab)
                var request = try ProjectREPL.terminalRequest(target: snapshot, kind: self.replKind(for: target), place: self.replPlace(for: target), dockerExecutable: self.docker?.executable, ssh: self.sshClient)
                // `ssh` itself starts in the profile's local folder, like Shell on Host.
                if target.isSSH { request.workingDirectory = self.library.localFolder(for: target) }
                if self.openTerminal != nil {
                    store.notice = nil
                    self.openTerminal(request, in: window)
                } else {
                    let text = ProjectCommandLauncher.shellText(request)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    store.notice = ProjectCommandNotice(commandName: "Open REPL", kind: .copied(text))
                }
            } catch {
                // An ambiguous or recreated container already opened the choice sheet.
                guard self.containerChoice == nil else { return }
                self.alert = AppAlert(title: "Could not open a REPL on \(self.targetLabel(target))", message: "\(error)")
            }
        }
    }
}
