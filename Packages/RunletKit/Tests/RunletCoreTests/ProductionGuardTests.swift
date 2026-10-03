import Foundation
import Testing
@testable import RunletCore

/// N14: when production targets ask before running code.
struct ProductionGuardTests {
    let production = TargetRef.ssh(UUID())
    let other = TargetRef.docker(UUID())

    /// `needsConfirmation` mutates (it forgets expired graces), so `#expect` gets its result.
    func asks(_ grace: inout ProductionGrace, _ action: GuardedAction, _ target: TargetRef, _ environment: TargetEnvironment = .production, at now: Date = Date()) -> Bool {
        grace.needsConfirmation(action, on: target, environment: environment, now: now)
    }

    @Test func onlyProductionTargetsAsk() {
        var grace = ProductionGrace()
        for action in [GuardedAction.run, .listCommands, .command, .shell, .repl, .appInfo] {
            let development = asks(&grace, action, other, .development)
            let staging = asks(&grace, action, other, .staging)
            let live = asks(&grace, action, production)
            #expect(!development && !staging && live, "\(action)")
        }
    }

    @Test func graceCoversSnippetRunsForTenMinutesOnly() {
        var grace = ProductionGrace()
        let start = Date(timeIntervalSince1970: 1_000_000)
        grace.grant(production, now: start)
        let afterOneMinute = asks(&grace, .run, production, at: start.addingTimeInterval(60))
        let justBeforeTheEnd = asks(&grace, .run, production, at: start.addingTimeInterval(599))
        #expect(!afterOneMinute && !justBeforeTheEnd)
        // Project commands and listings always ask, grace or not.
        let command = asks(&grace, .command, production, at: start.addingTimeInterval(60))
        let listing = asks(&grace, .listCommands, production, at: start.addingTimeInterval(60))
        let shell = asks(&grace, .shell, production, at: start.addingTimeInterval(60))
        // A REPL runs every line typed into it without asking again, so it always asks.
        let repl = asks(&grace, .repl, production, at: start.addingTimeInterval(60))
        // App Info boots the application: it asks every time too (#19).
        let appInfo = asks(&grace, .appInfo, production, at: start.addingTimeInterval(60))
        #expect(command && listing && shell && repl && appInfo)
        // The grace is per target…
        let otherTarget = asks(&grace, .run, other, at: start.addingTimeInterval(60))
        #expect(otherTarget)
        // …and ends after 10 minutes, and is then forgotten.
        let expired = asks(&grace, .run, production, at: start.addingTimeInterval(601))
        #expect(expired)
        #expect(grace.until[production.stableKey] == nil)
    }

    @Test func editingTheTargetRevokesTheGrace() {
        var grace = ProductionGrace()
        grace.grant(production)
        let granted = asks(&grace, .run, production)
        #expect(!granted)
        grace.revoke(production)
        let revoked = asks(&grace, .run, production)
        #expect(revoked)
        // A fresh value (a relaunch) has no grace at all.
        #expect(ProductionGrace().until.isEmpty)
    }

    @Test func previewShowsTheFirstTwelveLines() {
        let code = (1...20).map { "line \($0);" }.joined(separator: "\n")
        let preview = ProductionGrace.preview(of: "\n\n" + code + "\n")
        #expect(preview.lineCount == 20)
        #expect(preview.text.components(separatedBy: "\n").count == 12)
        #expect(preview.text.hasPrefix("line 1;") && preview.text.hasSuffix("line 12;"))
        #expect(ProductionGrace.preview(of: "php artisan migrate").lineCount == 1)
    }
}
