import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Which errors the engine marks as interrupted by Stop (#144): only the database's cancellation
/// error, only after Stop sent a cancel the server took. Held while the cancel runs.
struct SQLCancelControlTests {
    static let postgres = RunErrorInfo(stage: .execute, className: "PDOException", message: "SQLSTATE[57014]: Query canceled: 7 ERROR:  canceling statement due to user request")
    static let other = RunErrorInfo(stage: .execute, className: "PDOException", message: "SQLSTATE[42P01]: Undefined table: 7 ERROR:  relation \"nope\" does not exist")

    static func control() -> RunControl {
        let control = RunControl()
        control.setSQLSession(SQLSessionInfo(driver: "pgsql", id: 812))
        return control
    }

    @Test func withoutStopNothingIsHeldOrMarked() {
        let control = Self.control()
        #expect(!control.holdIfCancelling(Self.postgres), "someone else's cancel, or no cancel at all")
        #expect(!control.interruptedByStop(Self.postgres))
    }

    @Test func anAcceptedCancelMarksTheCancellationErrorOnly() {
        let control = Self.control()
        control.beginServerCancel()
        #expect(control.holdIfCancelling(Self.postgres))
        #expect(!control.holdIfCancelling(Self.other), "other errors pass at once")
        let held = control.settleServerCancel(accepted: true)
        #expect(held.count == 1 && held[0].interruptedByStop == true)
        // An error that arrives after the report is marked at once.
        #expect(control.interruptedByStop(Self.postgres))
        #expect(!control.interruptedByStop(Self.other))
    }

    @Test func aFailedCancelKeepsTheCard() {
        let control = Self.control()
        control.beginServerCancel()
        #expect(control.holdIfCancelling(Self.postgres))
        let held = control.settleServerCancel(accepted: false)
        #expect(held.count == 1 && held[0].interruptedByStop == nil)
        #expect(!control.interruptedByStop(Self.postgres))
    }

    @Test func otherDialectsErrorsDontCount() {
        let control = RunControl()
        control.setSQLSession(SQLSessionInfo(driver: "mysql", id: 5))
        control.beginServerCancel()
        #expect(!control.holdIfCancelling(Self.postgres))
    }
}
