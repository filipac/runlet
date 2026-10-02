import XCTest

/// ⇧⌘P command palette, ⌘P Open Anything prefixes, ⇧⌘T reopen, and remapped shortcuts.
final class CommandPaletteUITests: XCTestCase {
    var dataDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-palette-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("State"), withIntermediateDirectories: true)
    }

    func launch(settings: [String: Any] = [:]) throws -> XCUIApplication {
        if !settings.isEmpty {
            let envelope: [String: Any] = ["schemaVersion": 1, "savedAt": 0, "data": settings]
            try JSONSerialization.data(withJSONObject: envelope).write(to: dataDirectory.appendingPathComponent("State/settings.json"))
        }
        let app = XCUIApplication()
        app.launchEnvironment["RUNLET_DATA_DIR"] = dataDirectory.path
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        return app
    }

    func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testCommandPaletteRunsCommands() throws {
        let app = try launch()
        app.typeKey("p", modifierFlags: [.command, .shift])
        let search = element(app, "palette-search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("vertical tabs")
        let first = element(app, "palette-row")
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertTrue(first.label.contains("Toggle Vertical Tabs"), first.label)
        XCTAssertTrue(first.label.contains("⌃⌘T"), first.label)
        search.typeText("\r")
        XCTAssertTrue(element(app, "vertical-tabs").waitForExistence(timeout: 5), "command did not run")
    }

    func testReopenClosedTabRestoresCode() throws {
        let app = try launch()
        let editor = app.textViews["code-editor"]
        editor.click()
        editor.typeText("'closed tab code'")
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(((app.textViews["code-editor"].value as? String) ?? "").contains("closed tab code"))
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(((app.textViews["code-editor"].value as? String) ?? "").contains("closed tab code"), "⇧⌘T did not reopen the tab")
        XCTAssertFalse(element(app, "output-finished").exists, "reopening must not run code")
    }

    func testRemappedShortcutRunsCode() throws {
        // Run remapped to ⌃⌘E; ⌘R no longer runs.
        let app = try launch(settings: ["shortcutOverrides": ["run.run": ["combo": ["key": "e", "modifiers": ["control", "command"]]]]])
        let editor = app.textViews["code-editor"]
        editor.click()
        editor.typeText("40 + 2")
        app.typeKey("r", modifierFlags: .command)
        sleep(2)
        XCTAssertFalse(element(app, "output-finished").exists, "old shortcut still ran")
        app.typeKey("e", modifierFlags: [.control, .command])
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 60), "remapped shortcut did not run")
    }
}
