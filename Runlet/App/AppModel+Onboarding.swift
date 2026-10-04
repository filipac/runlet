import AppKit
import RunletCore

// The guided tour and What's New (#232): the saved state, the bundled manifest, and the one
// launch entry point, `WhatsNew.presentIfNeeded(model:)`.

/// `State/onboarding.json`: whether the tour was shown and the last version What's New was
/// shown for. Read once, before anything else in the data folder is written, so a first launch
/// is told apart from a Runlet that ran before.
@MainActor
final class OnboardingStore {
    private let store: JSONDocumentStore<OnboardingState>
    private(set) var state: OnboardingState

    init(paths: AppPaths) {
        store = JSONDocumentStore(url: paths.onboarding)
        let manager = FileManager.default
        let lastGood = paths.onboarding.deletingPathExtension().appendingPathExtension("last-good.json")
        if manager.fileExists(atPath: paths.onboarding.path) || manager.fileExists(atPath: lastGood.path) {
            // A file that can't be read counts as someone who has used Runlet: no tour.
            state = store.load(default: OnboardingState(isNewUser: false)).value
        } else {
            let existing = OnboardingState.earlierDataFiles.filter { manager.fileExists(atPath: paths.state.appendingPathComponent($0).path) }
            state = .initial(existingFiles: existing)
            save()
        }
    }

    func update(_ change: (inout OnboardingState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        save()
    }

    private func save() {
        do {
            try store.save(state)
        } catch {
            FileHandle.standardError.write(Data("Runlet: couldn't save onboarding.json: \(error)\n".utf8))
        }
    }
}

@MainActor
enum WhatsNew {
    /// The bundled manifest (`Runlet/WhatsNew.json`); empty when it's missing or doesn't parse.
    static let manifest: WhatsNewManifest = {
        guard let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "json") else { return WhatsNewManifest() }
        do {
            return try WhatsNewManifest.decode(Data(contentsOf: url))
        } catch {
            FileHandle.standardError.write(Data("Runlet: WhatsNew.json doesn't parse: \(error)\n".utf8))
            return WhatsNewManifest()
        }
    }()

    /// This app's version and build, from Info.plist.
    static var currentVersion: AppVersion? { AppVersion(infoDictionary: Bundle.main.infoDictionary) }

    static var launch: OnboardingLaunch {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return OnboardingLaunch(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment, isDebugBuild: debug)
    }

    /// How long a launch waits for a quiet moment (no run, sheet, or typing) before giving up
    /// until the next launch.
    static let patience: TimeInterval = 15 * 60

    /// Called once at launch. On a first launch, the guided tour; on the first launch of a newer
    /// version or build, whatever caused it (an update, the updater's relaunch, a reinstall),
    /// What's New for the releases since the one last seen. Never for `--self-test`, `runlet
    /// mcp`, UI tests, or a scratch `RUNLET_DATA_DIR` (`OnboardingLaunch.blocker`), and it
    /// waits while a run, a sheet, or typing is going on (`OnboardingActivity`).
    static func presentIfNeeded(model: AppModel?, debugAllowsAutomatic: Bool = false) {
        guard let model else { return }
        if let blocker = launch.blocker(debugAllowsAutomatic: debugAllowsAutomatic) {
            log("not shown by itself: \(blocker.rawValue)")
            return
        }
        TypingMonitor.start()
        Task { @MainActor in
            // Let restored windows come up first.
            try? await Task.sleep(for: .seconds(1.5))
            let start = Date()
            while let reason = activity(model, ignoreInactive: debugAllowsAutomatic).waitReason {
                guard Date().timeIntervalSince(start) < patience else {
                    log("not shown: still waiting after \(Int(patience / 60)) minutes (\(reason))")
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            presentNow(model)
        }
    }

    /// Decides and shows, recording what was decided.
    private static func presentNow(_ model: AppModel) {
        guard let current = currentVersion else { return log("no version in Info.plist") }
        let decision = OnboardingPolicy.decide(state: model.onboarding.state, current: current, manifest: manifest,
                                               showTips: model.settings.showTipsOnFirstLaunch, showWhatsNew: model.settings.showWhatsNewAfterUpdates)
        model.onboarding.update { $0 = decision.state }
        log("launch: \(decision.presentation)")
        switch decision.presentation {
        case .nothing:
            break
        case .tour:
            startTour(model: model)
        case .whatsNew(let since):
            showWindow(sections: manifest.sections(after: since, through: current), subtitle: subtitle(since: since, current: current), model: model)
        }
    }

    /// What is going on now.
    static func activity(_ model: AppModel, ignoreInactive: Bool = false) -> OnboardingActivity {
        let sheets = NSApp.modalWindow != nil || NSApp.windows.contains { $0.isVisible && $0.attachedSheet != nil }
            || NSApp.windows.contains { $0 is PalettePanel && $0.isVisible }
        return OnboardingActivity(
            runInProgress: model.allTabs.contains(where: \.isRunning),
            sheetOpen: sheets || model.mcp.presented != nil || model.productionGuard.pending != nil,
            typedRecently: TypingMonitor.typedRecently,
            isActive: ignoreInactive || NSApp.isActive,
            hasMainWindow: TourController.mainWindow(model) != nil
        )
    }

    // MARK: Tour

    /// The guided tour (first launch, Help ▸ Show Tour, Open Anything).
    static func startTour(model: AppModel) {
        WhatsNewWindow.shared.close()
        TourController.shared.start(manifest.tour, kind: .guided, model: model) { ending in
            // Finished or skipped, the first-launch tour doesn't come back by itself.
            model.onboarding.update { $0.tour = ending == .finished ? .finished : .skipped }
        }
    }

    /// Show Me: a feature's mini-tour over the main window, then What's New again.
    static func showMe(_ feature: WhatsNewFeature, model: AppModel) {
        guard !feature.tour.isEmpty else { return }
        let window = WhatsNewWindow.shared
        let wasOpen = window.isVisible
        window.stepAside()
        TourController.shared.start(feature.tour, kind: .feature(feature.title), model: model) { _ in
            if wasOpen { window.comeBack() }
        }
    }

    // MARK: Window

    /// Help ▸ What's New and Open Anything: this version's entries.
    static func showWindow(model: AppModel) {
        let current = currentVersion ?? AppVersion(version: "0", build: 1)
        let sections = manifest.currentSections(for: current)
        showWindow(sections: sections, subtitle: sections.first.map { "Highlights of \($0.label)" } ?? "", model: model)
    }

    static func showWindow(sections: [WhatsNewSection], subtitle: String, model: AppModel) {
        WhatsNewWindow.shared.show(WhatsNewContent(sections: sections, subtitle: subtitle, changelog: manifest.changelog.flatMap(URL.init(string:))), model: model)
    }

    /// "Since 0.4.0 beta 6", "Since 0.3.0", or everything in the version.
    static func subtitle(since: AppVersion?, current: AppVersion) -> String {
        guard let since else { return "Everything new in \(current.version)" }
        if let release = manifest.releases.first(where: { $0.appVersion == since }) { return "Since \(release.label)" }
        return since.sameVersion(as: current) ? "Since build \(since.build)" : "Since \(since.version)"
    }

    /// The label of this version in the manifest ("0.4.0 beta 7"), else its version.
    static var currentLabel: String {
        guard let current = currentVersion else { return "this version" }
        return manifest.releases.first { $0.appVersion == current }?.label ?? manifest.currentSections(for: current).first?.label ?? current.version
    }

    // MARK: Open Anything

    /// What's New and Show Tour for Open Anything's plain results.
    static func paletteItems(model: AppModel) -> [PaletteItem] {
        [
            PaletteItem(id: "help.whatsNew", kind: .command, title: "What's New in Runlet", subtitle: "Help · highlights of \(currentLabel), with Show Me tours", symbol: "sparkles",
                        badge: "Help", searchText: "what's new whats new release notes changes features update updated highlights changelog") { _ in
                model.perform("help.whatsNew")
            },
            PaletteItem(id: "help.showTour", kind: .command, title: "Show Tour", subtitle: "Help · a guided tour of the main window", symbol: "signpost.right",
                        badge: "Help", searchText: "guided tour tips onboarding introduction walkthrough getting started help coach marks") { _ in
                model.perform("help.showTour")
            },
        ]
    }

    static func log(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("RUNLET_ONBOARDING: \(message)\n".utf8))
        #endif
    }
}
