import Foundation
import Testing
@testable import RunletCore

/// #12 (N14): the environment applications report, the Mark as Production notice, and the
/// production snapshot in history.
struct AppEnvironmentTests {
    let project = TargetRef.local(UUID())

    // MARK: Protocol

    @Test func bootstrappedDecodesTheReportedEnvironment() throws {
        let json = #"{"framework":"laravel","frameworkVersion":"13.34.0","driverName":"Laravel","variables":{"app":"Illuminate\\Foundation\\Application"},"bootstrapMs":42,"environment":"production"}"#
        let info = try JSONDecoder().decode(BootstrappedInfo.self, from: Data(json.utf8))
        #expect(info.environment == "production")
        #expect(info.framework == "laravel")
        #expect(info.bootstrapMs == 42)
    }

    @Test func bootstrappedFromOlderRunnersHasNoEnvironment() throws {
        let json = #"{"framework":"composer","driverName":"Composer","variables":{},"bootstrapMs":3}"#
        let info = try JSONDecoder().decode(BootstrappedInfo.self, from: Data(json.utf8))
        #expect(info.environment == nil)
        #expect(info.driverName == "Composer")
        // Encoding leaves the key out rather than writing null.
        let encoded = try #require(String(data: JSONEncoder().encode(info), encoding: .utf8))
        #expect(!encoded.contains("environment"))
    }

    // MARK: Production names

    @Test func productionNamesAreWholeNamesIgnoringCaseAndSpaces() {
        for name in ["production", "Production", "PROD", " prod ", "prd", "live", "Live\n"] {
            #expect(AppEnvironment.isProduction(name), "\(name)")
        }
        for name in ["local", "dev", "staging", "preprod", "production-eu", "prod2", "test", "", "  ", nil] as [String?] {
            #expect(!AppEnvironment.isProduction(name), "\(name ?? "nil")")
        }
        #expect(AppEnvironment.productionNames == ["production", "prod", "prd", "live"])
    }

    @Test func localNames() {
        for name in ["local", "Local", "development", "dev", " DEV "] {
            #expect(AppEnvironment.isLocal(name), "\(name)")
        }
        for name in ["testing", "test", "staging", "production", "devel", nil] as [String?] {
            #expect(!AppEnvironment.isLocal(name), "\(name ?? "nil")")
        }
    }

    @Test func reportedNamesAreCleanedAndCapped() {
        #expect(AppEnvironment.normalized("  production\n") == "production")
        #expect(AppEnvironment.normalized("pro\u{0}duc\u{1B}tion") == "production")
        #expect(AppEnvironment.normalized(" \t ") == nil)
        #expect(AppEnvironment.normalized(nil) == nil)
        #expect(AppEnvironment.normalized(String(repeating: "x", count: 200))?.count == AppEnvironment.maximumLength)
        // Keeps the case the app used, for display.
        #expect(AppEnvironment.normalized("Staging-EU") == "Staging-EU")
    }

    // MARK: The notice

    @Test func offersMarkAsProductionWhenTheAppSaysProductionAndTheTargetIsNotMarked() throws {
        let development = try #require(AppEnvironmentNotice.decide(target: project, marking: .development, reported: "production"))
        #expect(development.kind == .reportsProduction)
        #expect(development.reported == "production")
        #expect(development.message.contains("“production”"))
        #expect(development.message.contains("that run didn't ask first"), "honest about the run that already happened")

        let staging = try #require(AppEnvironmentNotice.decide(target: .ssh(UUID()), marking: .staging, reported: "PROD"))
        #expect(staging.kind == .reportsProduction)
        #expect(staging.reported == "PROD")
        #expect(staging.message.contains("marked as staging"))
    }

    @Test func nothingWhenTheMarkingAgreesOrThereIsNothingToCompare() {
        // Already marked production: confirmations apply, nothing to offer.
        #expect(AppEnvironmentNotice.decide(target: project, marking: .production, reported: "production") == nil)
        // Not production, or not reported (plain Composer projects, older runners).
        #expect(AppEnvironmentNotice.decide(target: project, marking: .development, reported: "local") == nil)
        #expect(AppEnvironmentNotice.decide(target: project, marking: .development, reported: "staging") == nil)
        #expect(AppEnvironmentNotice.decide(target: project, marking: .staging, reported: "staging") == nil)
        #expect(AppEnvironmentNotice.decide(target: project, marking: .development, reported: nil) == nil)
        #expect(AppEnvironmentNotice.decide(target: project, marking: .development, reported: "   ") == nil)
        // The sandbox can't be marked.
        #expect(AppEnvironmentNotice.decide(target: .sandbox, marking: .development, reported: "production") == nil)
    }

    @Test func reverseNoteIsInformationOnly() throws {
        let note = try #require(AppEnvironmentNotice.decide(target: .docker(UUID()), marking: .production, reported: "local"))
        #expect(note.kind == .reportsLocal)
        #expect(note.message.contains("keeps asking"))
        // Only clearly local names: "testing" or "staging" on a production target say nothing.
        #expect(AppEnvironmentNotice.decide(target: project, marking: .production, reported: "testing") == nil)
        #expect(AppEnvironmentNotice.decide(target: project, marking: .production, reported: "staging") == nil)
    }

    @Test func dismissingHidesOnlyThatKind() {
        let dismissedOffer: Set<AppEnvironmentNotice.Kind> = [.reportsProduction]
        #expect(AppEnvironmentNotice.decide(target: project, marking: .development, reported: "production", dismissed: dismissedOffer) == nil)
        #expect(AppEnvironmentNotice.decide(target: project, marking: .production, reported: "local", dismissed: dismissedOffer)?.kind == .reportsLocal)
        let dismissedNote: Set<AppEnvironmentNotice.Kind> = [.reportsLocal]
        #expect(AppEnvironmentNotice.decide(target: project, marking: .development, reported: "prod", dismissed: dismissedNote)?.kind == .reportsProduction)
        #expect(AppEnvironmentNotice.decide(target: project, marking: .production, reported: "local", dismissed: dismissedNote) == nil)
    }

    @Test func everyCombination() {
        // marking × reported × dismissed → expected kind.
        let reports: [String?] = [nil, "local", "staging", "production"]
        for marking in TargetEnvironment.allCases {
            for reported in reports {
                for dismissed in [false, true] {
                    let expected: AppEnvironmentNotice.Kind?
                    switch (marking, reported) {
                    case (.development, "production"), (.staging, "production"): expected = .reportsProduction
                    case (.production, "local"): expected = .reportsLocal
                    default: expected = nil
                    }
                    let set: Set<AppEnvironmentNotice.Kind> = dismissed ? Set(AppEnvironmentNotice.Kind.allCases) : []
                    let decided = AppEnvironmentNotice.decide(target: project, marking: marking, reported: reported, dismissed: set)?.kind
                    #expect(decided == (dismissed ? nil : expected), "\(marking) \(reported ?? "nil") dismissed=\(dismissed)")
                }
            }
        }
    }

    // MARK: History snapshot

    @Test func historySnapshotRoundTrips() throws {
        let entry = HistoryEntry(runId: UUID(), code: "User::count()", target: project, targetLabel: "shop", status: .completed, reason: "completed", elapsedMs: 12, targetEnvironment: .production, targetColor: .red, appEnvironment: "production")
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
        #expect(decoded.ranOnProduction)
        #expect(decoded.targetColor == .red)
        #expect(decoded.appEnvironment == "production")
    }

    @Test func historySavedBeforeSnapshotsDecodesWithout() throws {
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","runId":"\(UUID().uuidString)","timestamp":0,"code":"app()","target":{"sandbox":{}},"targetLabel":"Sandbox","status":"completed","reason":"completed","elapsedMs":5}]
        """
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        let entry = try #require(entries.first)
        #expect(entry.id == id)
        #expect(entry.targetEnvironment == nil && entry.targetColor == nil && entry.appEnvironment == nil)
        #expect(!entry.ranOnProduction)
    }

    @Test func snapshotsWithoutAMarkingLeaveTheKeysOut() throws {
        let entry = HistoryEntry(runId: UUID(), code: "1", target: .sandbox, targetLabel: "Sandbox", status: .completed, reason: "completed", elapsedMs: 1)
        let json = try #require(String(data: JSONEncoder().encode(entry), encoding: .utf8))
        #expect(!json.contains("targetEnvironment") && !json.contains("appEnvironment") && !json.contains("targetColor"))
    }

    @Test func unknownMarkingsFromANewerRunletReadAsDevelopment() throws {
        let json = """
        {"id":"\(UUID().uuidString)","runId":"\(UUID().uuidString)","timestamp":0,"code":"1","target":{"sandbox":{}},"targetLabel":"x","status":"completed","reason":"completed","elapsedMs":1,"targetEnvironment":"preview","targetColor":"ultraviolet"}
        """
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        #expect(entry.targetEnvironment == .development)
        #expect(entry.targetColor == .gray)
    }

    /// Re-running code moves its entry up with the new run's snapshot: the entry describes its
    /// latest run, and the earlier marking isn't kept on it.
    @Test func rerunTakesTheLatestRunsSnapshot() {
        let first = HistoryEntry(runId: UUID(), timestamp: Date(timeIntervalSince1970: 1), code: "Order::count()", target: project, targetLabel: "shop", status: .completed, reason: "completed", elapsedMs: 3, targetEnvironment: .development, appEnvironment: "production")
        let rerun = HistoryEntry(runId: UUID(), timestamp: Date(timeIntervalSince1970: 2), code: "Order::count()", target: project, targetLabel: "shop", status: .completed, reason: "completed", elapsedMs: 3, targetEnvironment: .production, targetColor: .red, appEnvironment: "production")
        let history = HistoryLog.recording(rerun, into: [first], limit: 10)
        #expect(history.count == 1)
        #expect(history[0].id == first.id)
        #expect(history[0].targetEnvironment == .production && history[0].targetColor == .red)
    }
}
