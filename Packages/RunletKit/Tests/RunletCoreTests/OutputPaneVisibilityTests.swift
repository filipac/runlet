import Foundation
import Testing
@testable import RunletCore

/// Output pane auto-hide and Escape (#60): the settings, their defaults in older settings
/// files, and how runs, Clear Output, Show/Hide, and Escape show or hide the pane.
struct OutputPaneVisibilityTests {
    @Test func settingsDefaultOffAndRoundTrip() throws {
        let defaults = AppSettings()
        #expect(!defaults.hideOutputUntilRun && !defaults.escapeHidesOutput && defaults.outputVisible)
        // A settings file saved before #60 has neither key.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"outputVisible": false, "outputLayout": "bottom", "editorSplitBottom": 0.3}"#.utf8))
        #expect(!old.hideOutputUntilRun && !old.escapeHidesOutput)
        #expect(!old.outputVisible && old.outputLayout == .bottom && old.editorSplitBottom == 0.3)
        var settings = AppSettings()
        settings.hideOutputUntilRun = true
        settings.escapeHidesOutput = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(settings))
        #expect(decoded.hideOutputUntilRun && decoded.escapeHidesOutput)
        let garbage = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hideOutputUntilRun": "yes", "escapeHidesOutput": 1}"#.utf8))
        #expect(!garbage.hideOutputUntilRun && !garbage.escapeHidesOutput)
    }

    @Test func offByDefaultTheManualSwitchDecidesAsBefore() {
        var visibility = OutputPaneVisibility(paneVisible: true)
        #expect(visibility.isShown)
        visibility.apply(.runStarted)
        visibility.apply(.outputCleared(running: false))
        #expect(visibility.isShown, "runs and Clear Output leave the pane alone")
        visibility.apply(.toggle)
        #expect(!visibility.isShown && !visibility.paneVisible)
        visibility.apply(.runStarted)
        #expect(!visibility.isShown, "a run doesn't show a pane the user hid")
        visibility.apply(.show)
        #expect(visibility.isShown && visibility.paneVisible)
    }

    @Test func hiddenUntilARunThenHiddenAgainByClearOutput() {
        var visibility = OutputPaneVisibility(paneVisible: true, hideUntilRun: true)
        #expect(!visibility.isShown, "a tab that hasn't run shows the editor alone")
        visibility.apply(.runStarted)
        #expect(visibility.isShown)
        visibility.apply(.outputCleared(running: true))
        #expect(visibility.isShown, "clearing a running tab keeps the pane for what comes next")
        visibility.apply(.outputCleared(running: false))
        #expect(!visibility.isShown)
        #expect(visibility.paneVisible, "the saved Show/Hide state is untouched")
    }

    @Test func hideUntilRunRevealsEvenAfterTheManualSwitchHidIt() {
        var visibility = OutputPaneVisibility(paneVisible: false, hideUntilRun: true)
        visibility.apply(.runStarted)
        #expect(visibility.isShown)
        visibility.apply(.toggle)
        #expect(!visibility.isShown && !visibility.tabRevealed)
        visibility.apply(.toggle)
        #expect(visibility.isShown, "Show/Hide shows the pane of a tab, even before it runs")
        #expect(!visibility.paneVisible, "only the tab changed")
    }

    @Test func runsAreRememberedWhileTheSettingIsOff() {
        var visibility = OutputPaneVisibility(paneVisible: true, hideUntilRun: false)
        visibility.apply(.runStarted)
        visibility.hideUntilRun = true
        #expect(visibility.isShown, "a tab that already ran keeps its output in view")
    }

    @Test func escapeHidesTheTabsPaneUntilItsNextRun() {
        var visibility = OutputPaneVisibility(paneVisible: true)
        var used = visibility.escape(hidesPane: false)
        #expect(!used && visibility.isShown, "off, Escape is left to the editor")
        used = visibility.escape(hidesPane: true)
        #expect(used && !visibility.isShown)
        #expect(visibility.paneVisible, "Escape never changes the saved Show/Hide setting")
        used = visibility.escape(hidesPane: true)
        #expect(!used, "a hidden pane leaves Escape to the editor")
        visibility.apply(.runStarted)
        #expect(visibility.isShown, "the next run brings the pane back")
        _ = visibility.escape(hidesPane: true)
        visibility.apply(.toggle)
        #expect(visibility.isShown && visibility.paneVisible, "Show/Hide brings it back too")

        var hiddenByUser = OutputPaneVisibility(paneVisible: false)
        used = hiddenByUser.escape(hidesPane: true)
        #expect(!used, "nothing to hide")

        var tab = OutputPaneVisibility(paneVisible: true, hideUntilRun: true)
        used = tab.escape(hidesPane: true)
        #expect(!used, "nothing to hide before the first run")
        tab.apply(.runStarted)
        used = tab.escape(hidesPane: true)
        #expect(used && !tab.isShown && tab.paneVisible, "with hide-until-run, Escape hides the tab's pane until its next run")
        tab.apply(.runStarted)
        #expect(tab.isShown)
    }
}
