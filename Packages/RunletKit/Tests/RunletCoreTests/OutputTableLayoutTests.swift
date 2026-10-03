import Foundation
import RunletCore
import Testing

/// #162: tables in the output grow with their rows up to a limit, then scroll inside; a
/// vertical scroll the table can't take scrolls the output.
struct OutputTableLayoutTests {
    @Test func gridGrowsWithItsRowsUpToTheLimit() {
        let one = OutputTableLayout.gridHeight(rows: 1)
        #expect(OutputTableLayout.gridHeight(rows: 0) == one)
        #expect(OutputTableLayout.gridHeight(rows: 3) == one + 2 * OutputTableLayout.rowPitch)
        #expect(OutputTableLayout.gridHeight(rows: 1000) == OutputTableLayout.maxHeight)
        #expect(OutputTableLayout.gridHeight(rows: 3, scroller: 15) == OutputTableLayout.gridHeight(rows: 3) + 15)
        #expect(OutputTableLayout.gridHeight(rows: 1000, scroller: 15) == OutputTableLayout.maxHeight)
    }

    @Test func verticalScrollsTheTableCantTakeGoToTheOutput() {
        func goes(_ deltaY: Double, minY: Double, deltaX: Double = 0, height: Double = 1000, flipped: Bool = true) -> Bool {
            OutputTableLayout.scrollGoesToOutput(deltaX: deltaX, deltaY: deltaY, visibleMinY: minY, visibleHeight: 200, documentHeight: height, flipped: flipped)
        }
        // Rows that fit leave every vertical scroll to the output.
        #expect(goes(5, minY: 0, height: 150))
        #expect(goes(-5, minY: 0, height: 150))
        // At the top: up goes to the output, down scrolls the rows.
        #expect(goes(5, minY: 0))
        #expect(!goes(-5, minY: 0))
        // In the middle the table scrolls either way.
        #expect(!goes(5, minY: 400))
        #expect(!goes(-5, minY: 400))
        // At the bottom: down goes to the output.
        #expect(goes(-5, minY: 800))
        #expect(!goes(5, minY: 800))
        // Unflipped documents grow upward: their top is the largest y.
        #expect(goes(5, minY: 800, flipped: false))
        #expect(goes(-5, minY: 0, flipped: false))
        // Mostly horizontal scrolls, and no movement, stay with the table.
        #expect(!goes(2, minY: 0, deltaX: 10))
        #expect(!goes(0, minY: 0, height: 150))
    }
}
