import Foundation
import Testing
@testable import RunletCore

/// Notifications for long runs (#26): when to notify, what the notification says, and how it is
/// posted (through a fake: these tests never touch macOS notifications).
struct RunNotificationTests {
    typealias Policy = RunNotificationPolicy

    static func situation(enabled: Bool = true, threshold: Int = 10, elapsedMs: Int = 12_000, outcome: RunNotificationOutcome = .completed,
                          automatic: Bool = false, appIsActive: Bool = false, windowIsOnScreen: Bool = true) -> Policy.Situation {
        Policy.Situation(enabled: enabled, thresholdSeconds: threshold, elapsedMs: elapsedMs, outcome: outcome, automatic: automatic, appIsActive: appIsActive, windowIsOnScreen: windowIsOnScreen)
    }

    // MARK: Policy

    @Test func notifiesALongRunThatEndsInTheBackground() {
        #expect(Policy.shouldNotify(Self.situation()))
        for outcome in [RunNotificationOutcome.completed, .failed, .endedUnexpectedly, .couldNotStart] {
            #expect(Policy.shouldNotify(Self.situation(outcome: outcome)), "\(outcome)")
        }
    }

    @Test func theThresholdIsInclusive() {
        #expect(Policy.shouldNotify(Self.situation(elapsedMs: 10_000)))
        #expect(!Policy.shouldNotify(Self.situation(elapsedMs: 9_999)))
        #expect(!Policy.shouldNotify(Self.situation(threshold: 30, elapsedMs: 29_999)))
        #expect(Policy.shouldNotify(Self.situation(threshold: 30, elapsedMs: 30_000)))
        #expect(!Policy.shouldNotify(Self.situation(threshold: 0, elapsedMs: 500)), "a zero threshold still means at least a second")
    }

    @Test func neverNotifiesWhenTurnedOffStoppedOrAutomatic() {
        #expect(!Policy.shouldNotify(Self.situation(enabled: false)))
        #expect(!Policy.shouldNotify(Self.situation(elapsedMs: 600_000, outcome: .cancelled)), "Stop never notifies")
        #expect(!Policy.shouldNotify(Self.situation(elapsedMs: 600_000, automatic: true)), "sandbox auto-runs never notify")
    }

    @Test func onlyWhenTheUserCannotSeeTheRunEnd() {
        #expect(!Policy.shouldNotify(Self.situation(appIsActive: true, windowIsOnScreen: true)), "Runlet in front: the tab shows it")
        #expect(Policy.shouldNotify(Self.situation(appIsActive: true, windowIsOnScreen: false)), "the tab's window is minimized")
        #expect(Policy.shouldNotify(Self.situation(appIsActive: false, windowIsOnScreen: true)))
        #expect(Policy.shouldNotify(Self.situation(appIsActive: false, windowIsOnScreen: false)))
    }

    @Test func outcomesComeFromTheStatusAndReasonCode() {
        #expect(RunNotificationOutcome(FinishedInfo(status: .completed, reason: "completed", elapsedMs: 1)) == .completed)
        #expect(RunNotificationOutcome(FinishedInfo(status: .completed, reason: "dd", elapsedMs: 1)) == .completed)
        #expect(RunNotificationOutcome(FinishedInfo(status: .failed, reason: "error", elapsedMs: 1)) == .failed)
        #expect(RunNotificationOutcome(FinishedInfo(status: .failed, reason: "exit", exitCode: 3, elapsedMs: 1)) == .failed)
        #expect(RunNotificationOutcome(FinishedInfo(status: .failed, reason: "launch-failed", elapsedMs: 1)) == .couldNotStart)
        #expect(RunNotificationOutcome(FinishedInfo(status: .failed, reason: "transport-closed", elapsedMs: 1)) == .endedUnexpectedly)
        #expect(RunNotificationOutcome(FinishedInfo(status: .cancelled, reason: "cancelled: the container went away", elapsedMs: 1)) == .cancelled)
    }

    // MARK: Settings

    @Test func settingsDefaultOnAndOldFilesStillLoad() throws {
        #expect(AppSettings().notifyLongRuns)
        #expect(AppSettings().longRunNotificationSeconds == 10)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 14, "mcpServerEnabled": true}"#.utf8))
        #expect(old.notifyLongRuns)
        #expect(old.longRunNotificationSeconds == 10)
        #expect(old.fontSize == 14)

        var changed = AppSettings()
        changed.notifyLongRuns = false
        changed.longRunNotificationSeconds = 60
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
        #expect(!decoded.notifyLongRuns)
        #expect(decoded.longRunNotificationSeconds == 60)

        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"notifyLongRuns": "yes", "longRunNotificationSeconds": 7}"#.utf8))
        #expect(odd.notifyLongRuns, "an unreadable value falls back to the default")
        #expect(odd.longRunNotificationSeconds == 10, "a threshold that isn't a choice falls back to 10 s")
        #expect(Policy.thresholdOptions.allSatisfy { Policy.normalizedThreshold($0) == $0 })
    }

    // MARK: Content

    static let window = UUID()
    static let tab = UUID()
    static var destination: RunNotificationDestination { RunNotificationDestination(windowId: window, tabId: tab) }

    @Test func titleHasTheStatusAndDurationAndBodyTheTabAndTarget() {
        let content = RunNotificationContent.make(kind: .run, outcome: .completed, elapsedMs: 65_400, tabTitle: "Import users", targetLabel: "Shop (Docker)", destination: Self.destination)
        #expect(content.title == "Run completed in 1 min 5 s")
        #expect(content.body == "Import users · Shop (Docker)")
        #expect(content.identifier == "runlet.run.\(Self.tab.uuidString)", "one notification per tab")
        #expect(RunNotificationContent.make(kind: .sql, outcome: .failed, elapsedMs: 12_000, tabTitle: "Tab 2", targetLabel: "Laravel Sandbox 12", destination: Self.destination).title == "SQL run failed after 12 s")
        #expect(RunNotificationContent.make(kind: .profile, outcome: .endedUnexpectedly, elapsedMs: 3_600_000, tabTitle: "T", targetLabel: "L", destination: Self.destination).title == "Profile Run ended unexpectedly after 1 h")
        #expect(RunNotificationContent.make(kind: .run, outcome: .couldNotStart, elapsedMs: 31_000, tabTitle: "T", targetLabel: "prod (SSH)", destination: Self.destination).title == "Run couldn’t start after 31 s")
    }

    @Test func durations() {
        #expect(RunNotificationContent.formatDuration(milliseconds: 10_999) == "10 s")
        #expect(RunNotificationContent.formatDuration(milliseconds: 60_000) == "1 min")
        #expect(RunNotificationContent.formatDuration(milliseconds: 125_000) == "2 min 5 s")
        #expect(RunNotificationContent.formatDuration(milliseconds: 7_380_000) == "2 h 3 min")
        #expect(RunNotificationContent.formatDuration(milliseconds: -5) == "0 s")
    }

    @Test func labelsAreOneShortLine() {
        let long = String(repeating: "x", count: 200)
        let content = RunNotificationContent.make(kind: .run, outcome: .completed, elapsedMs: 10_000, tabTitle: "a\nb\tc\u{0}d", targetLabel: long, destination: Self.destination)
        #expect(content.body.hasPrefix("a b c d · "))
        #expect(content.body.count <= 2 * RunNotificationContent.maxLabelLength + 3)
        #expect(content.body.hasSuffix("…"))
        let blank = RunNotificationContent.make(kind: .run, outcome: .completed, elapsedMs: 10_000, tabTitle: "  \n ", targetLabel: "", destination: Self.destination)
        #expect(blank.body == "Untitled tab · Unknown target")
    }

    /// The builder takes no code, output, errors, SQL, or values, and a run's `FinishedInfo`
    /// (whose reason and truncation are text) only picks one of the fixed phrases.
    @Test func contentNeverCarriesCodeOutputOrErrors() {
        let secrets = ["SELECT password FROM users", "<?php echo $secret;", "PDOException: access denied for user", "s3cr3t-token", "Output exceeded 64 MiB"]
        let finished = [
            FinishedInfo(status: .failed, reason: "error: \(secrets[2])", exitCode: 255, elapsedMs: 20_000, truncation: secrets[4]),
            FinishedInfo(status: .completed, reason: "completed", elapsedMs: 20_000, truncation: secrets[4]),
            FinishedInfo(status: .failed, reason: "fatal", elapsedMs: 20_000),
        ]
        for info in finished {
            for kind in RunNotificationKind.allCases {
                let content = RunNotificationContent.make(kind: kind, outcome: RunNotificationOutcome(info), elapsedMs: info.elapsedMs, tabTitle: "Tab 1", targetLabel: "Laravel Sandbox", destination: Self.destination)
                let text = [content.title, content.body, content.identifier] + content.destination.userInfo.keys + content.destination.userInfo.values
                for secret in secrets {
                    #expect(!text.contains { $0.contains(secret) || $0.contains("s3cr3t") || $0.contains("password") || $0.contains("PDOException") }, "\(secret) in \(text)")
                }
                #expect(Set(content.destination.userInfo.values) == [Self.tab.uuidString, Self.window.uuidString], "userInfo holds identifiers only")
            }
        }
    }

    @Test func destinationRoundTripsThroughUserInfo() {
        let info: [AnyHashable: Any] = Self.destination.userInfo.reduce(into: [:]) { $0[$1.key] = $1.value }
        #expect(RunNotificationDestination(userInfo: info) == Self.destination)
        let noWindow = RunNotificationDestination(windowId: nil, tabId: Self.tab)
        #expect(RunNotificationDestination(userInfo: noWindow.userInfo.reduce(into: [AnyHashable: Any]()) { $0[$1.key] = $1.value }) == noWindow)
        #expect(RunNotificationDestination(userInfo: [:]) == nil)
        #expect(RunNotificationDestination(userInfo: ["runlet.tabId": "not a uuid"]) == nil)
        #expect(RunNotificationDestination(userInfo: ["runlet.tabId": 42]) == nil)
    }

    // MARK: Delivery (fake poster)

    actor FakePoster: RunNotificationPosting {
        var status: RunNotificationAuthorization
        let answer: RunNotificationAuthorization
        let failure: String?
        var requests = 0
        var posted: [RunNotificationContent] = []

        init(status: RunNotificationAuthorization, answer: RunNotificationAuthorization = .allowed, failure: String? = nil) {
            self.status = status
            self.answer = answer
            self.failure = failure
        }

        struct Failure: Error, CustomStringConvertible { var description: String }

        func authorization() async -> RunNotificationAuthorization { status }
        func requestAuthorization() async -> RunNotificationAuthorization {
            requests += 1
            status = answer
            return answer
        }
        func post(_ content: RunNotificationContent) async throws {
            if let failure { throw Failure(description: failure) }
            posted.append(content)
        }
    }

    static let content = RunNotificationContent.make(kind: .run, outcome: .completed, elapsedMs: 15_000, tabTitle: "Tab 1", targetLabel: "Laravel Sandbox", destination: destination)

    @Test func asksForPermissionTheFirstTimeThenPosts() async {
        let poster = FakePoster(status: .notDetermined, answer: .allowed)
        let first = await RunNotificationDelivery.deliver(Self.content, via: poster)
        #expect(first.result == .posted)
        #expect(first.authorization == .allowed)
        let second = await RunNotificationDelivery.deliver(Self.content, via: poster)
        #expect(second.result == .posted)
        #expect(await poster.requests == 1, "asked once")
        #expect(await poster.posted == [Self.content, Self.content])
    }

    @Test func aDeclinedPromptPostsNothing() async {
        let poster = FakePoster(status: .notDetermined, answer: .denied)
        let result = await RunNotificationDelivery.deliver(Self.content, via: poster)
        #expect(result.result == .notAllowed(.denied))
        #expect(await poster.posted.isEmpty)
        _ = await RunNotificationDelivery.deliver(Self.content, via: poster)
        #expect(await poster.requests == 1, "never asks again once denied")
    }

    @Test func deniedOrUnavailableNeverAsksOrPosts() async {
        for status in [RunNotificationAuthorization.denied, .unavailable("not signed")] {
            let poster = FakePoster(status: status)
            let result = await RunNotificationDelivery.deliver(Self.content, via: poster)
            #expect(result.result == .notAllowed(status))
            #expect(await poster.requests == 0)
            #expect(await poster.posted.isEmpty)
        }
    }

    @Test func aFailedPostIsReported() async {
        let poster = FakePoster(status: .allowed, failure: "boom")
        let result = await RunNotificationDelivery.deliver(Self.content, via: poster)
        #expect(result.result == .failed("boom"))
    }
}
