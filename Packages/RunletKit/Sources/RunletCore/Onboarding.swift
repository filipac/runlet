import Foundation

// When the first-launch tour and What's New appear (#232). The app gathers the facts (the
// launch, what is going on, the saved state) and asks these rules; it never decides on its own.

/// What Runlet remembers about the tour and What's New, in `State/onboarding.json`.
public struct OnboardingState: Sendable, Codable, Equatable {
    public enum TourStatus: String, Sendable, Codable {
        /// Shown, and not finished or skipped yet (Runlet quit meanwhile): it doesn't come back
        /// by itself.
        case started
        case finished
        case skipped
    }

    /// Decided once, when this file is first written: no data from an earlier Runlet was there.
    /// Only a new user gets the tour by itself; someone who updates gets What's New instead.
    public var isNewUser: Bool
    /// The first-launch tour; nil until it is shown.
    public var tour: TourStatus?
    /// The newest version and build What's New was shown for, or skipped for (its setting off,
    /// nothing to show, a new user). Nil for someone who used a Runlet from before What's New.
    public var whatsNewSeen: AppVersion?

    public init(isNewUser: Bool, tour: TourStatus? = nil, whatsNewSeen: AppVersion? = nil) {
        self.isNewUser = isNewUser
        self.tour = tour
        self.whatsNewSeen = whatsNewSeen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isNewUser = (try? c.decode(Bool.self, forKey: .isNewUser)) ?? false
        tour = try? c.decodeIfPresent(TourStatus.self, forKey: .tour)
        whatsNewSeen = try? c.decodeIfPresent(AppVersion.self, forKey: .whatsNewSeen)
    }

    /// The state for a data folder without `onboarding.json`: a new user unless an earlier
    /// Runlet left its files (`existingFiles`: which of `OnboardingState.earlierDataFiles` exist).
    public static func initial(existingFiles: [String]) -> OnboardingState {
        OnboardingState(isNewUser: existingFiles.isEmpty)
    }

    /// Files in `State/` that only a Runlet that ran before leaves behind.
    public static let earlierDataFiles = ["settings.json", "session.json", "history.json", "snippets.json", "targets.json", "facts.json"]
}

extension AppPaths {
    /// The tour's and What's New's state (#232).
    public var onboarding: URL { state.appendingPathComponent("onboarding.json") }
}

/// How this launch of Runlet started, from its arguments and environment.
public struct OnboardingLaunch: Sendable, Equatable {
    /// The argument `runlet mcp` starts Runlet with (in the background, for an AI client): the
    /// updater's (#233), which holds its update offers back in such a session too.
    public static let mcpArgument = UpdateCheckPolicy.launchedByMCPArgument

    public var arguments: [String]
    public var environment: [String: String]
    public var isDebugBuild: Bool

    public init(arguments: [String], environment: [String: String], isDebugBuild: Bool) {
        self.arguments = arguments
        self.environment = environment
        self.isDebugBuild = isDebugBuild
    }

    /// Why nothing may appear by itself in this launch; nil when it may.
    public enum Blocker: String, Sendable, Equatable {
        /// `--self-test`, which is also what packaging runs.
        case selfTest
        /// `runlet mcp` started Runlet for an AI client.
        case mcpLaunch
        /// UI tests (`RUNLET_UI_TESTS`, or the XCTest variables in the app's environment).
        case uiTest
        /// A scratch `RUNLET_DATA_DIR`: snapshots, screenshots, scripted checks, and UI tests.
        case scratchData
    }

    public var isSelfTest: Bool { arguments.contains("--self-test") }
    public var isMCPLaunch: Bool { arguments.contains(Self.mcpArgument) }
    public var isUITest: Bool {
        environment["RUNLET_UI_TESTS"] != nil || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil || environment["XCTestSessionIdentifier"] != nil
    }
    public var hasScratchData: Bool { !(environment["RUNLET_DATA_DIR"] ?? "").isEmpty }

    /// The DEBUG steps of a Debug build ask for the tour or What's New (`tour:…`,
    /// `whats-new:…`, `onboarding:…`), so they can be snapshotted.
    public var debugStepsAskForIt: Bool {
        guard isDebugBuild, let steps = environment["RUNLET_DEBUG_STEPS"] else { return false }
        return steps.split(separator: ",").contains { step in
            let name = step.trimmingCharacters(in: .whitespaces).split(separator: ":").first.map(String.init) ?? ""
            return ["tour", "whats-new", "onboarding"].contains(name)
        }
    }

    /// Why the tour and What's New mustn't appear by themselves. A scratch data folder blocks
    /// them in every build, so UI tests and scripted runs never see them; DEBUG steps show them
    /// explicitly instead (`tour:start`, `whats-new:show`), and `onboarding:auto` lifts only
    /// that rule, in Debug builds.
    public func blocker(debugAllowsAutomatic: Bool = false) -> Blocker? {
        if isSelfTest { return .selfTest }
        if isMCPLaunch { return .mcpLaunch }
        if isUITest { return .uiTest }
        if hasScratchData, !(isDebugBuild && debugAllowsAutomatic) { return .scratchData }
        return nil
    }
}

/// What is going on in the app right now, when something wants to appear.
public struct OnboardingActivity: Sendable, Equatable {
    /// A run (PHP, SQL, Redis, MongoDB, a project command, an AI client's) is preparing,
    /// running, queued, or stopping.
    public var runInProgress: Bool
    /// A sheet, alert, or modal window is up (an AI client's approval, a production
    /// confirmation, …), the palette, or the Software Update window.
    public var sheetOpen: Bool
    /// A key was typed in Runlet in the last few seconds.
    public var typedRecently: Bool
    /// Runlet is the active app.
    public var isActive: Bool
    /// A main window is on screen to show it over.
    public var hasMainWindow: Bool

    public init(runInProgress: Bool = false, sheetOpen: Bool = false, typedRecently: Bool = false, isActive: Bool = true, hasMainWindow: Bool = true) {
        self.runInProgress = runInProgress
        self.sheetOpen = sheetOpen
        self.typedRecently = typedRecently
        self.isActive = isActive
        self.hasMainWindow = hasMainWindow
    }

    /// Why it has to wait; nil when it can appear now.
    public var waitReason: String? {
        if runInProgress { return "a run is in progress" }
        if sheetOpen { return "a sheet or alert is open" }
        if typedRecently { return "the user is typing" }
        if !isActive { return "Runlet isn't the active app" }
        if !hasMainWindow { return "no main window is on screen" }
        return nil
    }
}

/// The launch's decision.
public enum OnboardingPresentation: Sendable, Equatable {
    case nothing
    /// The first-launch tour.
    case tour
    /// What's New, for what is newer than `since` (nil: everything in this version).
    case whatsNew(since: AppVersion?)
}

public enum OnboardingPolicy {
    /// What this launch shows by itself, and the state to save once it has (or once it was
    /// decided that nothing shows). It doesn't look at blockers or activity: the app checks
    /// those first and asks again later.
    ///
    /// - A new user gets the tour once (unless tips are off) and no What's New for the version
    ///   they started with.
    /// - Anyone else gets What's New the first time a newer version or build starts, for the
    ///   releases since the one they saw (all of this version's when that isn't known), if the
    ///   manifest has any and the setting is on. Either way that version counts as seen.
    public static func decide(state: OnboardingState, current: AppVersion, manifest: WhatsNewManifest,
                              showTips: Bool, showWhatsNew: Bool) -> (presentation: OnboardingPresentation, state: OnboardingState) {
        var next = state
        if state.isNewUser, state.whatsNewSeen == nil {
            next.whatsNewSeen = current
            if state.tour == nil, showTips {
                next.tour = .started
                return (.tour, next)
            }
            return (.nothing, next)
        }
        if let seen = state.whatsNewSeen, current <= seen { return (.nothing, state) }
        next.whatsNewSeen = current
        let sections = manifest.sections(after: state.whatsNewSeen, through: current)
        guard showWhatsNew, !sections.isEmpty else { return (.nothing, next) }
        return (.whatsNew(since: state.whatsNewSeen), next)
    }
}
