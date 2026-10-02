import XCTest

/// Multiple windows with their own tabs, and `.runlet` workspace files.
final class WorkspaceUITests: XCTestCase {
    var dataDirectory: URL!
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("plan.md").path) { return url }
        }
        return URL(fileURLWithPath: "/")
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("State"), withIntermediateDirectories: true)
    }

    func writeState(_ name: String, _ data: Any) throws {
        let envelope: [String: Any] = ["schemaVersion": 1, "savedAt": 0, "data": data]
        try JSONSerialization.data(withJSONObject: envelope).write(to: dataDirectory.appendingPathComponent("State/\(name).json"))
    }

    func tab(_ title: String, _ code: String) -> [String: Any] {
        ["id": UUID().uuidString, "title": title, "code": code, "target": ["sandbox": [String: Any]()], "selection": ["location": 0, "length": 0], "createdAt": 0]
    }

    func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RUNLET_DATA_DIR"] = dataDirectory.path
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        return app
    }

    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Windows that show Runlet content (have an editor).
    func contentWindows(_ app: XCUIApplication) -> Int {
        app.windows.allElementsBoundByIndex.filter { $0.textViews["code-editor"].exists }.count
    }

    func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    func testWindowsAndTheirTabsAreRestored() throws {
        try writeState("session", ["windows": [
            ["id": UUID().uuidString, "tabs": [tab("Alpha 1", "'alpha one'"), tab("Alpha 2", "'alpha two'")]],
            ["id": UUID().uuidString, "tabs": [tab("Beta 1", "'beta one'")]],
        ]])
        var app = launch()
        XCTAssertTrue(waitFor { self.contentWindows(app) == 2 }, "expected two restored windows")
        XCTAssertTrue(element(app, "tab-Alpha 2").exists)
        XCTAssertTrue(element(app, "tab-Beta 1").exists)
        // Each window shows only its own tabs.
        for window in app.windows.allElementsBoundByIndex where window.textViews["code-editor"].exists {
            let hasAlpha = window.descendants(matching: .any).matching(identifier: "tab-Alpha 1").count > 0
            let hasBeta = window.descendants(matching: .any).matching(identifier: "tab-Beta 1").count > 0
            XCTAssertNotEqual(hasAlpha, hasBeta, "a window mixes tabs from both windows")
        }
        sleep(1)
        app.terminate()
        app = launch()
        XCTAssertTrue(waitFor { self.contentWindows(app) == 2 }, "windows were not restored after relaunch")
        XCTAssertFalse(element(app, "output-finished").exists, "restoring must not run code")
    }

    func testNewWindowAndCloseConfirmation() throws {
        try writeState("session", ["windows": [["id": UUID().uuidString, "tabs": [tab("Main", "'main'")]]]])
        let app = launch()
        XCTAssertTrue(waitFor { self.contentWindows(app) == 1 })
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitFor { self.contentWindows(app) == 2 }, "⌘N did not open a window")

        // Type scratch code in the new (key) window, then close it: Runlet asks first.
        let editor = app.windows.firstMatch.textViews["code-editor"]
        editor.click()
        editor.typeText("'scratch in new window'")
        app.typeKey("w", modifierFlags: [.command, .shift])
        let closeButton = app.dialogs.buttons["Close"].exists ? app.dialogs.buttons["Close"] : app.sheets.buttons["Close"]
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5) || app.sheets.firstMatch.waitForExistence(timeout: 1), "no close confirmation")
        (app.dialogs.buttons["Close"].exists ? app.dialogs.buttons["Close"] : closeButton).click()
        XCTAssertTrue(waitFor { self.contentWindows(app) == 1 }, "window did not close")
        XCTAssertTrue(element(app, "tab-Main").exists)
    }

    func testOpenEditAndSaveWorkspaceFile() throws {
        try writeState("session", ["windows": [["id": UUID().uuidString, "tabs": [tab("Scratch", "'scratch'")]]]])
        let workspace = dataDirectory.appendingPathComponent("Shop.runlet")
        let laravelApp = Self.repoRoot.appendingPathComponent("Tests/Fixtures/laravel-app").path
        let document: [String: Any] = [
            "format": "runlet-workspace", "version": 1, "selectedIndex": 1,
            "tabs": [
                ["title": "Sandbox tab", "code": "'from workspace'", "target": ["kind": "sandbox"]],
                ["title": "Widgets", "code": "App\\Models\\Widget::count()", "target": ["kind": "local", "local": ["name": "Fixture Laravel", "path": laravelApp]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: document, options: .prettyPrinted).write(to: workspace)

        let app = launch(arguments: [workspace.path])
        // The workspace's local project isn't in the library yet: Runlet asks before adding it.
        let add = app.dialogs.buttons["Add and Open"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no add-targets confirmation")
        add.click()
        XCTAssertTrue(element(app, "tab-Widgets").waitForExistence(timeout: 10))
        XCTAssertTrue(app.windows["Shop"].waitForExistence(timeout: 5), "workspace window should be titled after the file")

        // Run the restored target (a real local Laravel project) to prove the definition resolved.
        let shop = app.windows["Shop"]
        shop.click()
        element(app, "tab-Widgets").click()
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 60))
        XCTAssertTrue(element(app, "output-result").descendants(matching: .staticText).allElementsBoundByIndex.contains { (($0.value as? String) ?? $0.label).contains("3") })

        // Edit and save with ⌘S: the file is rewritten with the new code (and nothing else runs).
        let editor = shop.textViews["code-editor"]
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        editor.typeText("App\\Models\\Widget::pluck('name')")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(waitFor {
            let text = (try? String(contentsOf: workspace, encoding: .utf8)) ?? ""
            return text.contains("pluck('name')")
        }, "⌘S did not save the workspace")
        let saved = try String(contentsOf: workspace, encoding: .utf8)
        XCTAssertTrue(saved.contains("Fixture Laravel"))
        XCTAssertFalse(saved.contains("lastContainerId"))
    }
}
