import XCTest

/// Vertical tabs: toggling, the details on each card, and persistence across relaunch.
final class TabLayoutUITests: XCTestCase {
    func testVerticalTabsPersistAndShowTargetDetails() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        func launch() -> XCUIApplication {
            let app = XCUIApplication()
            app.launchEnvironment["RUNLET_DATA_DIR"] = data.path
            if let snapshots = ProcessInfo.processInfo.environment["RUNLET_SNAPSHOT_DIR"] {
                app.launchEnvironment["RUNLET_SNAPSHOT_DIR"] = snapshots
            }
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
            return app
        }
        func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: id).firstMatch
        }

        var app = launch()
        XCTAssertFalse(element(app, "vertical-tabs").exists, "horizontal by default")
        app.typeKey("t", modifierFlags: [.command, .control])
        XCTAssertTrue(element(app, "vertical-tabs").waitForExistence(timeout: 5))

        // Run once so the card learns PHP/framework details from the run.
        let editor = app.textViews["code-editor"]
        editor.click()
        editor.typeText("PHP_VERSION")
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 60))
        let card = element(app, "tab-Tab 1")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let label = card.label
        XCTAssertTrue(label.contains("Tab 1"), label)
        XCTAssertTrue(label.contains("PHP "), label)
        XCTAssertTrue(label.contains("Laravel 13.34"), label)
        if ProcessInfo.processInfo.environment["RUNLET_SNAPSHOT_DIR"] != nil {
            app.typeKey("t", modifierFlags: .command)
            app.typeKey("s", modifierFlags: [.command, .control, .option])
            sleep(1)
        }

        sleep(1)
        app.terminate()
        app = launch()
        XCTAssertTrue(element(app, "vertical-tabs").waitForExistence(timeout: 5), "vertical tabs were not remembered")
        app.typeKey("t", modifierFlags: [.command, .control])
        XCTAssertTrue(element(app, "tab-Tab 1").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "vertical-tabs").exists)
    }
}
