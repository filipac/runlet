import Foundation
import Testing
@testable import RunletCore

/// Renaming a tab (#285): what each way of ending a rename does with the typed name, how a
/// field's text movement ends it, when the field takes the keyboard back, and Open Anything's words.
struct TabRenameTests {
    @Test func returnAndFocusLossCommitTheTrimmedName() {
        #expect(TabRename.newTitle(after: .commit, text: "Orders", current: "Tab 2") == "Orders")
        #expect(TabRename.newTitle(after: .focusLost, text: "Orders", current: "Tab 2") == "Orders")
        #expect(TabRename.newTitle(after: .commit, text: "  Orders report \n", current: "Tab 2") == "Orders report")
    }

    @Test func escKeepsTheOldTitle() {
        #expect(TabRename.newTitle(after: .cancel, text: "Orders", current: "Tab 2") == nil)
    }

    @Test func anEmptyOrWhitespaceNameKeepsTheOldTitle() {
        #expect(TabRename.newTitle(after: .commit, text: "", current: "Tab 2") == nil)
        #expect(TabRename.newTitle(after: .commit, text: "   ", current: "Tab 2") == nil)
        #expect(TabRename.newTitle(after: .focusLost, text: "\n\t ", current: "Tab 2") == nil)
    }

    @Test func theSameNameChangesNothing() {
        #expect(TabRename.newTitle(after: .commit, text: "Tab 2", current: "Tab 2") == nil)
        #expect(TabRename.newTitle(after: .commit, text: " Tab 2 ", current: "Tab 2") == nil)
    }

    @Test func textMovementsEndTheRename() {
        #expect(TabRename.end(forTextMovement: TabRename.TextMovement.return) == .commit)
        #expect(TabRename.end(forTextMovement: TabRename.TextMovement.tab) == .commit)
        #expect(TabRename.end(forTextMovement: TabRename.TextMovement.backtab) == .commit)
        #expect(TabRename.end(forTextMovement: TabRename.TextMovement.cancel) == .cancel)
        // The field resigned without a key: something else took the keyboard.
        #expect(TabRename.end(forTextMovement: TabRename.TextMovement.other) == .focusLost)
        #expect(TabRename.end(forTextMovement: 0x14) == .focusLost)
    }

    @Test func theFieldTakesTheKeyboardBackOnlyFromCodeRightAfterTheStart() {
        // A closing palette or an editor that grabs the keyboard right after the start.
        #expect(TabRename.reclaimsFocus(secondsSinceFocused: 0, byUser: false))
        #expect(TabRename.reclaimsFocus(secondsSinceFocused: 0.4, byUser: false))
        // A click or key press of the user's always ends it.
        #expect(!TabRename.reclaimsFocus(secondsSinceFocused: 0.1, byUser: true))
        // Later, losing the keyboard ends it whatever took it.
        #expect(!TabRename.reclaimsFocus(secondsSinceFocused: TabRename.reclaimSeconds, byUser: false))
        #expect(!TabRename.reclaimsFocus(secondsSinceFocused: 5, byUser: false))
        #expect(!TabRename.reclaimsFocus(secondsSinceFocused: -1, byUser: false))
    }

    @Test func openAnythingListsRenameTabForRenameWords() {
        #expect(TabRename.paletteMatches("rename"))
        #expect(TabRename.paletteMatches("ren"))
        #expect(TabRename.paletteMatches("Rename tab"))
        #expect(TabRename.paletteMatches("rename title"))
        // Not for a tab, a target, or a snippet search.
        #expect(!TabRename.paletteMatches("tab"))
        #expect(!TabRename.paletteMatches("re"))
        #expect(!TabRename.paletteMatches("rename users"))
        #expect(!TabRename.paletteMatches("report"))
        #expect(!TabRename.paletteMatches(""))
    }
}
