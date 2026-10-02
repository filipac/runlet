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

    /// The palette floats over the window instead of a sheet: ⌘P / ⇧⌘P switch an open palette's
    /// mode (keeping the text) or close it when it already shows that mode, ">" and ⌫ switch
    /// too, typing never leaves command mode, and a click outside only closes it.
    @MainActor
    func testPaletteSwitchesModesAndClosesOnOutsideClick() throws {
        let app = try launch()
        let commandMode = element(app, "palette-mode")
        app.typeKey("p", modifierFlags: [.command, .shift])
        let search = element(app, "palette-search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(commandMode.exists, "⇧⌘P did not open command mode")
        search.typeText("dock")
        XCTAssertTrue(commandMode.exists, "typing left command mode")
        XCTAssertEqual(search.value as? String, "dock")
        XCTAssertTrue(element(app, "palette-row").label.contains("Docker"), element(app, "palette-row").label)
        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(commandMode.waitForNonExistence(timeout: 3), "⌘P did not switch to Open Anything")
        XCTAssertEqual(search.value as? String, "dock")
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(commandMode.waitForExistence(timeout: 3), "⇧⌘P did not switch back to commands")
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(search.waitForNonExistence(timeout: 3), "the same shortcut did not close the palette")

        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText(">")
        XCTAssertTrue(commandMode.waitForExistence(timeout: 3), "> did not switch to commands")
        XCTAssertFalse((search.value as? String ?? "").contains(">"), "> was not consumed")
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(commandMode.waitForNonExistence(timeout: 3), "⌫ did not return to Open Anything")

        let tabCount = tabs(app)
        element(app, "new-tab-button").click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 3), "a click outside did not close the palette")
        XCTAssertEqual(tabs(app), tabCount, "the click also reached the New Tab button")
    }

    @MainActor
    func tabs(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab-Tab'")).count
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
