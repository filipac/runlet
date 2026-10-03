import AppKit
import Observation
import RunletCore
import RunletExecution

/// Loading state of one target's App Info (#19).
enum AppInfoState: Equatable {
    /// Never loaded. Nothing runs until the user opens App Info.
    case idle
    /// The runner is booting the project; `previous` stays visible meanwhile.
    case loading(since: Date, previous: AppInfoReport?)
    /// The runner finished. The report may still carry errors (the app could not boot).
    case loaded(AppInfoReport)
    /// The target could not be resolved or the runner could not start.
    case failed(message: String, at: Date, previous: AppInfoReport?)

    var report: AppInfoReport? {
        switch self {
        case .idle: nil
        case .loading(_, let previous), .failed(_, _, let previous): previous
        case .loaded(let report): report
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// Something to show without running anything: a report, or the error of the last load.
    var hasResult: Bool {
        switch self {
        case .loaded, .failed: true
        case .idle, .loading: false
        }
    }
}

/// Per-target App Info caches (keyed by `TargetRef.stableKey`), kept until Refresh, an edit of
/// the target's settings, or quitting. Loading is explicit: it boots the user's application.
@MainActor
@Observable
final class AppInfoStore {
    var states: [String: AppInfoState] = [:]
    @ObservationIgnored var tasks: [String: Task<Void, Never>] = [:]
    /// Bumped by each load and by `forgetAppInfo`: a load whose number is no longer current
    /// leaves the state alone.
    @ObservationIgnored var generations: [String: Int] = [:]

    private static var stores: [ObjectIdentifier: AppInfoStore] = [:]

    static func shared(for model: AppModel) -> AppInfoStore {
        let key = ObjectIdentifier(model)
        if let store = stores[key] { return store }
        let store = AppInfoStore()
        stores[key] = store
        return store
    }
}

extension Notification.Name {
    /// Show App Info (menu, palette): the active window's status bar opens the popover for the
    /// tab whose id is the notification's object. `userInfo["anchor"]` "card" opens it from
    /// the tab card's framework chip instead (DEBUG steps).
    static let appInfoRequested = Notification.Name("RunletAppInfoRequested")
}

extension AppModel {
    var appInfo: AppInfoStore { AppInfoStore.shared(for: self) }

    /// Cached App Info state for a target (never triggers loading).
    func appInfoState(for target: TargetRef) -> AppInfoState {
        appInfo.states[target.stableKey] ?? .idle
    }

    /// Opening App Info (the framework chip, Show App Info) or its Refresh. Shows what is
    /// cached without running anything; loads only when nothing is cached or on Refresh,
    /// which boots the application in a fresh runner (an SSH host is reached only now, under
    /// the usual connection rules). Production targets ask before every load. `present`
    /// shows the popover: at once, or after the confirmation.
    func openAppInfo(for tab: TabModel, refresh: Bool = false, present: @escaping () -> Void) {
        let target = tab.target
        let state = appInfoState(for: target)
        switch AppInfoPolicy.onOpen(hasResult: state.hasResult, isLoading: state.isLoading, refresh: refresh, environment: library.environment(for: target)) {
        case .show:
            present()
        case .load, .confirmThenLoad:
            guardProduction(.appInfo, target: target, text: "Read the App Info of \(targetLabel(target)) (boots the application, runs no snippet)", in: window(containing: tab.id)) { [weak self, weak tab] in
                guard let self, let tab, tab.target == target else { return }
                present()
                self.startLoadingAppInfo(for: tab)
            }
        }
    }

    private func startLoadingAppInfo(for tab: TabModel) {
        let target = tab.target
        let key = target.stableKey
        let store = appInfo
        let current = appInfoState(for: target)
        guard !current.isLoading else { return }
        let previous = current.report
        let generation = (store.generations[key] ?? 0) + 1
        store.generations[key] = generation
        store.states[key] = .loading(since: Date(), previous: previous)
        store.tasks[key] = Task {
            var result: AppInfoState
            do {
                let snapshot = try await self.snapshot(for: tab)
                result = .loaded(try await self.engine.loadAppInfo(target: snapshot))
            } catch is CancellationError {
                result = previous.map { .loaded($0) } ?? .idle
            } catch {
                result = .failed(message: "\(error)", at: Date(), previous: previous)
            }
            guard store.generations[key] == generation else { return }
            store.tasks[key] = nil
            store.states[key] = result
        }
    }

    /// Stops a load in progress (the runner process is stopped too).
    func cancelAppInfo(for target: TargetRef) {
        appInfo.tasks[target.stableKey]?.cancel()
    }

    /// Drops a target's cached App Info (its settings changed); a load in progress stops.
    func forgetAppInfo(for target: TargetRef) {
        let key = target.stableKey
        appInfo.generations[key, default: 0] += 1
        appInfo.tasks[key]?.cancel()
        appInfo.tasks[key] = nil
        appInfo.states[key] = nil
    }

    /// The framework chip's text for a tab: from its last run, else from what Runlet knows of
    /// the target; nil for plain PHP or before anything is known.
    func frameworkChipText(for tab: TabModel) -> String? {
        let framework: String?, driverName: String?, version: String?
        if let run = tab.lastRun {
            (framework, driverName, version) = (run.framework, run.driverName, run.frameworkVersion)
        } else if let facts = targetFacts[tab.target.stableKey] {
            (framework, driverName, version) = (facts.framework, facts.driverName, facts.frameworkVersion)
        } else {
            return nil
        }
        guard let framework, framework != "plain" else { return nil }
        let custom = framework.hasPrefix("custom:")
        let name = driverName ?? (custom ? String(framework.dropFirst(7)) : framework.capitalized)
        return TabCardText.frameworkChip(name: name, version: version)
    }
}
