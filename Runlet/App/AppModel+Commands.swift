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

    /// Lists the commands of `tab`'s target: resolves it like a run (Docker container
    /// resolution included; ambiguity or recreation asks the user and fails this load), then
    /// boots the project in a fresh runner. Executes project code, so call only on an explicit
    /// user action (opening the Commands panel, Refresh). Ignored while already loading.
    func loadCommands(for tab: TabModel) {
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
                let catalog = try await self.engine.listCommands(target: snapshot)
                store.states[key] = .loaded(catalog)
            } catch is CancellationError {
                store.states[key] = previous.map { .loaded($0) } ?? .idle
            } catch {
                store.states[key] = .failed(message: "\(error)", previous: previous)
            }
        }
    }

    /// Stops a load in progress (the runner process is stopped too).
    func cancelLoadingCommands(for target: TargetRef) {
        projectCommands.tasks[target.stableKey]?.cancel()
    }

    /// Opens `command` in a terminal for `tab`'s target, resolved now: the project directory
    /// for local and sandbox targets, `docker exec -it` into the profile's current container
    /// for Docker targets (never a different container; resolution problems are reported).
    /// Without a terminal panel, the command is copied to the pasteboard instead.
    func runProjectCommand(_ command: ProjectCommand, in tab: TabModel) {
        let store = projectCommands
        guard !store.launching.contains(command.id) else { return }
        store.launching.insert(command.id)
        Task {
            defer { store.launching.remove(command.id) }
            do {
                let snapshot = try await self.snapshot(for: tab)
                let request = try ProjectCommandLauncher.terminalRequest(for: command, target: snapshot, dockerExecutable: self.docker?.executable)
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
