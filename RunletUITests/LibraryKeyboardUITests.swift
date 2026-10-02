import XCTest

/// Keyboard-first History and Snippets (⌘Y, ⇧⌘L, ↑/↓, ↩, ⌘↩, ⇧↩), history in ⌘P behind `!`,
/// and file-backed tabs following their files on disk. Nothing here runs code.
final class LibraryKeyboardUITests: XCTestCase {
    var dataDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("State"), withIntermediateDirectories: true)
    }

    func writeState(_ name: String, _ data: Any) throws {
        let envelope: [String: Any] = ["schemaVersion": 1, "savedAt": 0, "data": data]
        try JSONSerialization.data(withJSONObject: envelope).write(to: dataDirectory.appendingPathComponent("State/\(name).json"))
    }

    func entry(_ code: String, secondsAgo: Double) -> [String: Any] {
        ["id": UUID().uuidString, "runId": UUID().uuidString, "timestamp": Date().timeIntervalSinceReferenceDate - secondsAgo, "code": code,
         "target": ["sandbox": [String: Any]()], "targetLabel": "Sandbox", "status": "completed", "reason": "completed", "elapsedMs": 5]
    }

    @MainActor
    func launch(arguments: [String] = []) throws -> XCUIApplication {
        try writeState("history", [entry("<?php\nUser::count();", secondsAgo: 10), entry("<?php\nPost::count();", secondsAgo: 20), entry("<?php\nnow();", secondsAgo: 30)])
        try writeState("snippets", [["id": UUID().uuidString, "label": "Clear cache", "code": "<?php\nCache::flush();", "createdAt": 0, "updatedAt": 0]])
        let app = XCUIApplication()
        app.launchEnvironment["RUNLET_DATA_DIR"] = dataDirectory.path
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func editorText(_ app: XCUIApplication) -> String {
        (app.textViews["code-editor"].value as? String) ?? ""
    }

    @MainActor
    func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    @MainActor
    func testHistoryIsKeyboardFirst() throws {
        let app = try launch()
        app.typeKey("y", modifierFlags: .command)
        let search = element(app, "history-search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        // ⌘Y put the keyboard in the search: typing filters, ↓ moves, ↩ opens (the blank tab).
        app.typeText("count")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { self.editorText(app).contains("Post::count()") }, "↩ did not open the second match")
        XCTAssertFalse(element(app, "output-finished").exists, "opening must not run code")

        // ⌘↩ opens a new tab; the editor has the keyboard afterwards.
        app.typeKey("y", modifierFlags: .command)
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitFor { self.editorText(app).contains("User::count()") }, "⌘↩ did not open a new tab")
        XCTAssertTrue(element(app, "tab-History").exists)

        // ⇧↩ inserts at the cursor without the open tag.
        app.typeKey("y", modifierFlags: .command)
        app.typeText("now")
        app.typeKey(.return, modifierFlags: .shift)
        XCTAssertTrue(waitFor { self.editorText(app).contains("now();") })
        XCTAssertEqual(self.editorText(app).components(separatedBy: "<?php").count, 2, "⇧↩ inserted a second <?php")
    }

    @MainActor
    func testSnippetsOpenFromTheKeyboard() throws {
        let app = try launch()
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(element(app, "snippet-search").waitForExistence(timeout: 5))
        app.typeText("cache")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { self.editorText(app).contains("Cache::flush()") })
    }

    @MainActor
    func testOpenAnythingSearchesHistoryBehindBang() throws {
        let app = try launch()
        app.typeKey("p", modifierFlags: .command)
        let search = element(app, "palette-search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("!post")
        let row = element(app, "palette-row")
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(row.label.contains("Post::count()"), row.label)
        search.typeText("\r")
        XCTAssertTrue(waitFor { self.editorText(app).contains("Post::count()") })
    }

    @MainActor
    func testFileTabsFollowTheirFiles() throws {
        let file = dataDirectory.appendingPathComponent("watched.php")
        try "<?php\necho 'one';\n".write(to: file, atomically: true, encoding: .utf8)
        let app = try launch(arguments: [file.path])
        XCTAssertTrue(waitFor { self.editorText(app).contains("one") })

        // No unsaved edits: an atomic save elsewhere reloads the tab.
        try "<?php\necho 'two';\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitFor { self.editorText(app).contains("two") }, "the tab did not reload")

        // Unsaved edits: the banner asks instead.
        app.textViews["code-editor"].click()
        app.typeText("// mine\n")
        try "<?php\necho 'three';\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(element(app, "disk-change-banner").waitForExistence(timeout: 5))
        XCTAssertTrue(editorText(app).contains("// mine"))
        element(app, "disk-reload").click()
        XCTAssertTrue(waitFor { self.editorText(app).contains("three") && !self.editorText(app).contains("// mine") })
        XCTAssertFalse(element(app, "disk-change-banner").exists)
    }
}
