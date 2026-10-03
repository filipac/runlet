import AppKit
import RunletCore
import UserNotifications

/// Posts run notifications (#26) through `UNUserNotificationCenter`. Reading the permission never
/// asks; `requestAuthorization()` shows macOS's prompt the first time only.
final class SystemRunNotifier: RunNotificationPosting {
    private var center: UNUserNotificationCenter { .current() }

    func authorization() async -> RunNotificationAuthorization {
        Self.authorization(await center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async -> RunNotificationAuthorization {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            // For example UNErrorCodeNotificationsNotAllowed, for a build macOS won't let post.
            return .unavailable(error.localizedDescription)
        }
        return await authorization()
    }

    func post(_ content: RunNotificationContent) async throws {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.sound = .default
        notification.threadIdentifier = "runlet.runs"
        notification.userInfo = content.destination.userInfo
        try await center.add(UNNotificationRequest(identifier: content.identifier, content: notification, trigger: nil))
    }

    static func authorization(_ status: UNAuthorizationStatus) -> RunNotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional: .allowed
        @unknown default: .allowed
        }
    }
}

/// `UNUserNotificationCenter`'s delegate: shows run notifications even while Runlet is active
/// (one is only posted when the tab's window is minimized or Runlet is in the background), and
/// a click brings back the tab that ran.
final class RunNotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let destination = RunNotificationDestination(userInfo: response.notification.request.content.userInfo)
        if clicked {
            Task { @MainActor in AppDelegate.model?.openRunNotification(destination) }
        }
        completionHandler()
    }
}

#if DEBUG
/// Debug builds: logs the notification that would be posted (`RUNLET_DEBUG_NOTIFICATION: …` on
/// stderr) instead of posting it, and never asks macOS for permission. Used when
/// `RUNLET_DEBUG_NOTIFICATIONS=log[:allowed|denied|notDetermined|unavailable]` is set, and by
/// default for scripted runs (`RUNLET_DEBUG_STEPS`, `RUNLET_DEBUG_INSPECTOR`,
/// `RUNLET_SNAPSHOT_DIR`); `RUNLET_DEBUG_NOTIFICATIONS=system` uses macOS notifications anyway.
final class LoggingRunNotifier: RunNotificationPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var status: RunNotificationAuthorization
    private var lastPosted: RunNotificationContent?

    init(status: RunNotificationAuthorization) {
        self.status = status
    }

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LoggingRunNotifier? {
        let setting = environment["RUNLET_DEBUG_NOTIFICATIONS"]
        if setting == "system" { return nil }
        let scripted = ["RUNLET_DEBUG_STEPS", "RUNLET_DEBUG_INSPECTOR", "RUNLET_SNAPSHOT_DIR"].contains { environment[$0] != nil }
        guard setting?.hasPrefix("log") == true || scripted else { return nil }
        let state = setting?.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? "notDetermined"
        return LoggingRunNotifier(status: authorization(named: state))
    }

    static func authorization(named name: String) -> RunNotificationAuthorization {
        switch name {
        case "allowed": .allowed
        case "denied": .denied
        case "unavailable": .unavailable("Debug: notifications are unavailable for this build.")
        default: .notDetermined
        }
    }

    var last: RunNotificationContent? { lock.withLock { lastPosted } }

    func setAuthorization(_ authorization: RunNotificationAuthorization) {
        lock.withLock { status = authorization }
    }

    func authorization() async -> RunNotificationAuthorization { lock.withLock { status } }

    func requestAuthorization() async -> RunNotificationAuthorization {
        let answer = lock.withLock {
            if status == .notDetermined { status = .allowed }
            return status
        }
        Self.log("RUNLET_DEBUG_NOTIFICATION: would ask macOS for permission (answer: \(answer))")
        return answer
    }

    func post(_ content: RunNotificationContent) async throws {
        lock.withLock { lastPosted = content }
        Self.log("RUNLET_DEBUG_NOTIFICATION: id=\(content.identifier) title=\"\(content.title)\" body=\"\(content.body)\" window=\(content.destination.windowId?.uuidString ?? "none") tab=\(content.destination.tabId.uuidString)")
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
#endif
