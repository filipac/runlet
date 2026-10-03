import AppKit
import RunletCore

/// Notifications for long runs (#26). Every run a user or AI client starts ends in `startRun`,
/// which calls `runEnded`: Run, Run Selection, Profile Run, an SQL tab's Run and Run All
/// Statements, and MCP runs. App Info, schema loads, command listings, and terminal commands
/// aren't runs and never notify; neither do sandbox auto-runs or stopped runs.
extension AppModel {
    static func makeRunNotifier() -> any RunNotificationPosting {
        #if DEBUG
        if let logging = LoggingRunNotifier.fromEnvironment() { return logging }
        #endif
        return SystemRunNotifier()
    }

    /// A run that `startRun` began at `startedAt` ended: posts a notification when
    /// `RunNotificationPolicy` says so. Only the status, the duration, the tab's title, and the
    /// target's label go into it.
    func runEnded(_ tab: TabModel, target: TargetRef, kind: RunNotificationKind, outcome: RunNotificationOutcome, startedAt: ContinuousClock.Instant, runnerElapsedMs: Int = 0, automatic: Bool) {
        // Closing a tab or window stops its run, so a run whose tab is gone has nowhere to go.
        guard let window = window(containing: tab.id) else { return }
        let elapsedMs = max(runnerElapsedMs, Int((ContinuousClock.now - startedAt) / .milliseconds(1)))
        let onScreen = window.nsWindow.map { $0.isVisible && !$0.isMiniaturized } ?? false
        let situation = RunNotificationPolicy.Situation(enabled: settings.notifyLongRuns, thresholdSeconds: settings.longRunNotificationSeconds, elapsedMs: elapsedMs,
                                                        outcome: outcome, automatic: automatic, appIsActive: NSApp.isActive, windowIsOnScreen: onScreen)
        guard RunNotificationPolicy.shouldNotify(situation) else { return }
        let content = RunNotificationContent.make(kind: kind, outcome: outcome, elapsedMs: elapsedMs, tabTitle: tab.title, targetLabel: targetLabel(target),
                                                  destination: RunNotificationDestination(windowId: window.id, tabId: tab.id))
        let notifier = runNotifier
        Task {
            // Asks macOS for permission the first time there is something to show.
            let delivery = await RunNotificationDelivery.deliver(content, via: notifier)
            notificationAuthorization = delivery.authorization
        }
    }

    /// A click on a run notification: brings Runlet forward, and the tab that ran in its window.
    /// When the tab was closed meanwhile, only Runlet comes forward.
    func openRunNotification(_ destination: RunNotificationDestination?) {
        var bringForward = true
        #if DEBUG
        // Screenshot runs keep Runlet invisible and the user's keyboard where it is.
        bringForward = !DebugSteps.isGhosted
        #endif
        if bringForward { NSApp.activate() }
        guard let destination, let window = window(containing: destination.tabId) else { return }
        window.selectedTabId = destination.tabId
        windowBecameActive(window.id)
        guard bringForward, let nsWindow = window.nsWindow else { return }
        if nsWindow.isMiniaturized { nsWindow.deminiaturize(nil) }
        nsWindow.makeKeyAndOrderFront(nil)
    }

    /// Settings ▸ General ▸ Notifications: reads macOS's permission (never asks).
    func refreshNotificationAuthorization() {
        let notifier = runNotifier
        Task {
            let current = await notifier.authorization()
            // macOS refused this build when asked; it still reads as "not asked yet".
            if current == .notDetermined, case .unavailable = notificationAuthorization { return }
            notificationAuthorization = current
        }
    }

    /// The Settings switch. Turning it on asks macOS for permission now, if it hasn't asked yet.
    func setNotifyLongRuns(_ on: Bool) {
        settings.notifyLongRuns = on
        guard on else { return }
        let notifier = runNotifier
        Task {
            var authorization = await notifier.authorization()
            if authorization == .notDetermined { authorization = await notifier.requestAuthorization() }
            notificationAuthorization = authorization
        }
    }

    /// System Settings ▸ Notifications, on Runlet's page where macOS supports it. Only opens it.
    func openNotificationSettings() {
        var link = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let id = Bundle.main.bundleIdentifier { link += "?id=" + id }
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}
