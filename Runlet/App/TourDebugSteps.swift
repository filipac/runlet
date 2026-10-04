#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for the guided tour and What's New (#232; see `DebugSteps`). Scratch data
/// never shows them by themselves, so these ask for them, for snapshots and checks:
/// `tour:start` (the guided tour, as Help ▸ Show Tour does) · `tour:next|back|skip|done` ·
/// `tour:step:<n>` (goes to step n, 1-based) · `tour:show-me:<feature id>` (a What's New
/// feature's mini-tour, as its Show Me does, without the window) · `tour-state` (prints the step,
/// where its card is, and the anchors on screen) · `whats-new:show` (Help ▸ What's New) ·
/// `whats-new:show:since=<version>+<build>` (as after an update from that build; `since=none`
/// for someone whose last version isn't known) — both up to this build, or the manifest's newest
/// when this development build is older · `whats-new:show-me:<feature id>` (presses that card's
/// Show Me) · `whats-new:close` · `whats-new-state` (prints the window's sections and features)
/// · `onboarding:auto` (runs the launch's decision, `WhatsNew.presentIfNeeded`, as if the data
/// weren't scratch) · `onboarding:new-user|updater[:<version>+<build>]` (rewrites the scratch
/// state: a first launch, or someone who last saw that build) · `onboarding-state`.
@MainActor
enum TourDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "tour":
            tour(argument, model: model)
        case "tour-state":
            log(TourController.shared.debugDescription + " · on screen: " + TourAnchors.onScreen.map(\.rawValue).joined(separator: ", "))
            if argument == "frames" { log("anchors: " + TourAnchors.frames) }
        case "whats-new":
            whatsNew(argument, model: model)
        case "whats-new-state":
            let window = WhatsNewWindow.shared
            let sections = window.content?.sections.map { section in
                "\(section.label) [\(section.releases.map { "\($0.build)" }.joined(separator: ","))]: \(section.features.map { ($0.important ? "*" : "") + $0.id }.joined(separator: ", ")) + \(section.also.count) also"
            } ?? []
            log("whats-new visible=\(window.isVisible) subtitle=\"\(window.content?.subtitle ?? "")\" sections=\(sections)")
        case "onboarding":
            onboarding(argument, model: model)
        case "onboarding-state":
            let state = model.onboarding.state
            let current = WhatsNew.currentVersion
            let decision = current.map {
                OnboardingPolicy.decide(state: state, current: $0, manifest: WhatsNew.manifest, showTips: model.settings.showTipsOnFirstLaunch, showWhatsNew: model.settings.showWhatsNewAfterUpdates).presentation
            }
            log("onboarding newUser=\(state.isNewUser) tour=\(state.tour?.rawValue ?? "nil") seen=\(state.whatsNewSeen?.description ?? "nil") current=\(current?.description ?? "nil") blocker=\(WhatsNew.launch.blocker()?.rawValue ?? "none") decision=\(decision.map { "\($0)" } ?? "-") activity=\(WhatsNew.activity(model).waitReason ?? "quiet")")
        default:
            return false
        }
        return true
    }

    private static func tour(_ argument: String, model: AppModel) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        let controller = TourController.shared
        switch parts.first ?? "" {
        case "start": WhatsNew.startTour(model: model)
        case "next": controller.next()
        case "back": controller.back()
        case "skip": controller.skip()
        case "done": controller.end(.finished)
        case "step": if parts.count > 1, let number = Int(parts[1]) { controller.go(to: number - 1) }
        case "show-me":
            guard parts.count > 1, let feature = WhatsNew.manifest.feature(parts[1])?.feature else { return log("tour: no feature \(argument)") }
            controller.start(feature.tour, kind: .feature(feature.title), model: model)
        default: log("tour: \(argument)?")
        }
    }

    private static func whatsNew(_ argument: String, model: AppModel) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "show":
            guard parts.count > 1, parts[1].hasPrefix("since=") else { return WhatsNew.showWindow(model: model) }
            let current = [WhatsNew.currentVersion, WhatsNew.manifest.newest].compactMap { $0 }.max() ?? AppVersion(version: "0", build: 1)
            let since = version(String(parts[1].dropFirst(6)))
            WhatsNew.showWindow(sections: WhatsNew.manifest.sections(after: since, through: current), subtitle: WhatsNew.subtitle(since: since, current: current), model: model)
        case "show-me":
            guard parts.count > 1, let feature = WhatsNew.manifest.feature(parts[1])?.feature else { return log("whats-new: no feature \(argument)") }
            WhatsNew.showMe(feature, model: model)
        case "close": WhatsNewWindow.shared.close()
        default: log("whats-new: \(argument)?")
        }
    }

    private static func onboarding(_ argument: String, model: AppModel) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "auto":
            WhatsNew.presentIfNeeded(model: model, debugAllowsAutomatic: true)
        case "new-user", "updater":
            guard WhatsNew.launch.hasScratchData else { return log("onboarding: only with a scratch RUNLET_DATA_DIR") }
            let seen = parts.count > 1 ? version(parts[1]) : nil
            model.onboarding.update { $0 = OnboardingState(isNewUser: parts[0] == "new-user", whatsNewSeen: seen) }
        default: log("onboarding: \(argument)?")
        }
    }

    /// `0.3.0+6`; nil for `none`.
    private static func version(_ text: String) -> AppVersion? {
        let parts = text.split(separator: "+").map(String.init)
        guard parts.count == 2 else { return nil }
        return AppVersion(version: parts[0], build: parts[1])
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
