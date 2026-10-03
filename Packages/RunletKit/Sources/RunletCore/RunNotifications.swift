import Foundation

// Notifications for long runs (#26): when a run that took a while ends while Runlet is in the
// background, macOS shows a notification with the run's status, its duration, the tab, and the
// target. The notification never carries code, output, error messages, SQL, or values: its
// content is built here from those four facts only, and the app posts it through
// `RunNotificationPosting`, so tests (and Debug step runs) use a fake that posts nothing.

/// How a run ended, as a notification says it. Built from the run's `FinishedInfo` status and
/// reason code (never from its text), or `.couldNotStart` when the target couldn't be prepared.
public enum RunNotificationOutcome: String, Sendable, Equatable, CaseIterable {
    case completed
    case failed
    /// The PHP process ended without reporting completion (`transport-closed`).
    case endedUnexpectedly
    /// The process didn't start (`launch-failed`), or the target couldn't be prepared (an SSH
    /// connection that timed out, a stopped container, …).
    case couldNotStart
    /// Stopped by the user (or a closed tab or window): never notified.
    case cancelled

    public init(_ finished: FinishedInfo) {
        switch finished.status {
        case .completed: self = .completed
        case .cancelled: self = .cancelled
        case .failed:
            switch finished.reason {
            case "launch-failed": self = .couldNotStart
            case "transport-closed": self = .endedUnexpectedly
            default: self = .failed
            }
        }
    }
}

/// Which kind of run ended; only changes the notification's first word.
public enum RunNotificationKind: String, Sendable, Equatable, CaseIterable {
    /// Run, Run Selection, and runs an AI client asked for (MCP).
    case run
    /// Profile Run.
    case profile
    /// An SQL tab's Run or Run All Statements.
    case sql

    var title: String {
        switch self {
        case .run: "Run"
        case .profile: "Profile Run"
        case .sql: "SQL run"
        }
    }
}

/// Whether a run that just ended gets a notification.
public enum RunNotificationPolicy {
    /// Settings ▸ General ▸ Notifications: the choices for "Notify after", in seconds.
    public static let thresholdOptions = [10, 30, 60, 300]
    public static let defaultThreshold = 10

    public struct Situation: Sendable, Equatable {
        /// Settings ▸ General ▸ Notifications ▸ Notify when a long run finishes in the background.
        public var enabled: Bool
        public var thresholdSeconds: Int
        /// From Run (after any production confirmation) until the run ended.
        public var elapsedMs: Int
        public var outcome: RunNotificationOutcome
        /// A sandbox auto-run (started by typing, not by Run).
        public var automatic: Bool
        /// Runlet is the active app (`NSApp.isActive`).
        public var appIsActive: Bool
        /// The tab's window is on screen: visible and not minimized.
        public var windowIsOnScreen: Bool

        public init(enabled: Bool, thresholdSeconds: Int, elapsedMs: Int, outcome: RunNotificationOutcome, automatic: Bool = false, appIsActive: Bool, windowIsOnScreen: Bool) {
            self.enabled = enabled
            self.thresholdSeconds = thresholdSeconds
            self.elapsedMs = elapsedMs
            self.outcome = outcome
            self.automatic = automatic
            self.appIsActive = appIsActive
            self.windowIsOnScreen = windowIsOnScreen
        }
    }

    /// True when the setting is on, the run took at least the threshold, it wasn't stopped or
    /// started by auto-run, and the user can't see it end: Runlet isn't the active app, or the
    /// tab's window is minimized.
    public static func shouldNotify(_ situation: Situation) -> Bool {
        guard situation.enabled, !situation.automatic, situation.outcome != .cancelled else { return false }
        guard situation.elapsedMs >= max(1, situation.thresholdSeconds) * 1000 else { return false }
        return !situation.appIsActive || !situation.windowIsOnScreen
    }

    /// A stored threshold, or the default when it isn't one of the choices.
    public static func normalizedThreshold(_ seconds: Int?) -> Int {
        guard let seconds, thresholdOptions.contains(seconds) else { return defaultThreshold }
        return seconds
    }
}

/// Where clicking a notification goes: the tab, in the window it ran in.
public struct RunNotificationDestination: Sendable, Equatable {
    public var windowId: UUID?
    public var tabId: UUID

    public init(windowId: UUID?, tabId: UUID) {
        self.windowId = windowId
        self.tabId = tabId
    }

    static let windowKey = "runlet.windowId"
    static let tabKey = "runlet.tabId"

    /// The notification's `userInfo`: identifiers only.
    public var userInfo: [String: String] {
        var info = [Self.tabKey: tabId.uuidString]
        if let windowId { info[Self.windowKey] = windowId.uuidString }
        return info
    }

    /// Reads a clicked notification's `userInfo`; nil when it isn't one of Runlet's run notifications.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let tab = (userInfo[Self.tabKey] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        tabId = tab
        windowId = (userInfo[Self.windowKey] as? String).flatMap(UUID.init(uuidString:))
    }
}

/// A notification's text and destination. Made by `make(…)` from the status, the duration, the
/// tab's title, and the target's label only.
public struct RunNotificationContent: Sendable, Equatable {
    /// One per tab: a newer run's notification replaces the tab's previous one.
    public var identifier: String
    public var title: String
    public var body: String
    public var destination: RunNotificationDestination

    /// Longest tab title or target label shown; longer ones end in "…".
    static let maxLabelLength = 60

    public static func make(kind: RunNotificationKind, outcome: RunNotificationOutcome, elapsedMs: Int, tabTitle: String, targetLabel: String, destination: RunNotificationDestination) -> RunNotificationContent {
        let duration = formatDuration(milliseconds: elapsedMs)
        let title: String
        switch outcome {
        case .completed: title = "\(kind.title) completed in \(duration)"
        case .failed: title = "\(kind.title) failed after \(duration)"
        case .endedUnexpectedly: title = "\(kind.title) ended unexpectedly after \(duration)"
        case .couldNotStart: title = "\(kind.title) couldn’t start after \(duration)"
        case .cancelled: title = "\(kind.title) stopped after \(duration)"
        }
        let tab = label(tabTitle, fallback: "Untitled tab")
        let target = label(targetLabel, fallback: "Unknown target")
        return RunNotificationContent(identifier: "runlet.run.\(destination.tabId.uuidString)", title: title, body: "\(tab) · \(target)", destination: destination)
    }

    /// "12 s", "1 min 5 s", "2 h 3 min"; whole seconds, rounded down.
    public static func formatDuration(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1000
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 {
            let rest = seconds % 60
            return rest == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(rest) s"
        }
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(seconds / 3600) h" : "\(seconds / 3600) h \(minutes) min"
    }

    /// One line, without control characters, at most `maxLabelLength` characters.
    static func label(_ text: String, fallback: String) -> String {
        let words = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return fallback }
        return words.count > maxLabelLength ? String(words.prefix(maxLabelLength - 1)) + "…" : words
    }
}

/// Whether macOS lets Runlet show notifications.
public enum RunNotificationAuthorization: Sendable, Equatable {
    /// macOS hasn't asked yet; it asks the first time Runlet has a notification to show.
    case notDetermined
    case allowed
    /// Turned off for Runlet in System Settings ▸ Notifications.
    case denied
    /// macOS refused to deal with this build at all (for example an unsigned copy).
    case unavailable(String)
}

/// Posts notifications: `UNUserNotificationCenter` in the app, a fake in tests and Debug step runs.
public protocol RunNotificationPosting: AnyObject, Sendable {
    /// The current permission; never asks.
    func authorization() async -> RunNotificationAuthorization
    /// Asks macOS for permission (shows its prompt the first time only).
    func requestAuthorization() async -> RunNotificationAuthorization
    func post(_ content: RunNotificationContent) async throws
}

/// What `RunNotificationDelivery.deliver` did.
public enum RunNotificationDeliveryResult: Sendable, Equatable {
    case posted
    /// Not allowed: nothing was posted.
    case notAllowed(RunNotificationAuthorization)
    case failed(String)
}

public enum RunNotificationDelivery {
    /// Posts `content`, asking for permission first when macOS hasn't asked yet (lazily, the
    /// first time there is something to show). Once denied, it never asks again.
    public static func deliver(_ content: RunNotificationContent, via poster: some RunNotificationPosting) async -> (result: RunNotificationDeliveryResult, authorization: RunNotificationAuthorization) {
        var authorization = await poster.authorization()
        if authorization == .notDetermined {
            authorization = await poster.requestAuthorization()
        }
        guard authorization == .allowed else { return (.notAllowed(authorization), authorization) }
        do {
            try await poster.post(content)
            return (.posted, authorization)
        } catch {
            return (.failed("\(error)"), authorization)
        }
    }
}
