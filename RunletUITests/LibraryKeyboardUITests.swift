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
        XCTAssertTrue(rowText(row).contains("Post::count()"), rowText(row))
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

    func savedSnippets() throws -> [[String: Any]] {
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: dataDirectory.appendingPathComponent("State/snippets.json"))) as! [String: Any]
        return envelope["data"] as! [[String: Any]]
    }

    @MainActor func rowText(_ row: XCUIElement) -> String {
        // macOS may expose combined SwiftUI row text as its value rather than its label.
        [row.label, row.value as? String ?? ""].joined(separator: " ")
    }

    @MainActor func replaceField(_ app: XCUIApplication, _ id: String, with value: String) {
        let field = element(app, id)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        if !value.isEmpty { field.typeText(value) }
    }

    /// #52: actual save/edit/search/palette/clear paths, including a restart and a legacy row.
    @MainActor func testPersonalSnippetDescriptionsSaveEditSearchAndSurviveRestart() throws {
        let app = try launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: dataDirectory) }
        let marker = dataDirectory.appendingPathComponent("must-not-run.txt")
        let code = "file_put_contents('\(marker.path)', 'unexpected');"
        let editor = app.textViews["code-editor"]
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        editor.typeText(code)
        app.typeKey("s", modifierFlags: [.command, .option])
        replaceField(app, "snippet-label-field", with: "Order lookup")
        replaceField(app, "snippet-description-field", with: "  Unshipped invoices ")
        XCTAssertEqual(element(app, "snippet-description-field").value as? String, "  Unshipped invoices ")
        element(app, "snippet-save-button").click()
        XCTAssertTrue(waitFor { (try? self.savedSnippets().first?["description"] as? String) == "Unshipped invoices" }, "Saved: \(String(describing: try? savedSnippets()))")
        XCTAssertEqual(try savedSnippets().count, 2, "old snippets must survive saving")
        XCTAssertNil(try savedSnippets().last?["description"])
        app.typeKey("l", modifierFlags: [.command, .shift])
        replaceField(app, "snippet-search", with: "invoices")
        let row = element(app, "snippet-row")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(rowText(row).contains("Unshipped invoices"), rowText(row))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { self.editorText(app).contains("must-not-run") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        app.typeKey("l", modifierFlags: [.command, .shift])
        replaceField(app, "snippet-search", with: "invoices")
        element(app, "snippet-edit-button").click()
        XCTAssertEqual(element(app, "snippet-edit-description").value as? String, "Unshipped invoices")
        replaceField(app, "snippet-edit-description", with: "Monthly reconciliation")
        element(app, "snippet-edit-save").click()
        XCTAssertTrue(waitFor { (try? self.savedSnippets().first?["description"] as? String) == "Monthly reconciliation" })
        app.terminate()
        app.launch() // Keep the persisted library, without reseeding it.
        XCTAssertTrue(app.textViews["code-editor"].waitForExistence(timeout: 15))
        app.typeKey("p", modifierFlags: .command)
        replaceField(app, "palette-search", with: "#reconciliation")
        let paletteRow = element(app, "palette-row")
        XCTAssertTrue(paletteRow.waitForExistence(timeout: 5))
        XCTAssertTrue(rowText(paletteRow).contains("Monthly reconciliation"), rowText(paletteRow))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { self.editorText(app).contains("must-not-run") })
        XCTAssertFalse(element(app, "output-finished").exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "saving, editing, restoring, and opening must never execute")
        app.typeKey("l", modifierFlags: [.command, .shift])
        replaceField(app, "snippet-search", with: "reconciliation")
        element(app, "snippet-edit-button").click()
        replaceField(app, "snippet-edit-description", with: " ")
        element(app, "snippet-edit-save").click()
        XCTAssertTrue(waitFor { (try? self.savedSnippets().first?["description"]) == nil })
        replaceField(app, "snippet-search", with: "cache")
        XCTAssertTrue(element(app, "snippet-row").waitForExistence(timeout: 5), "legacy snippets still searchable")
    }

    /// #52: project metadata stays in the file, while copy and duplicate retain it personally.
    @MainActor func testProjectCopiesAndDuplicatesPreserveDescriptions() throws {
        let root = dataDirectory.appendingPathComponent("Shop")
        let folder = root.appendingPathComponent(".runlet/snippets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("orders.php")
        let contents = "<?php\n/**\n * @label Orders\n * @description Pending shipments\n */\nOrder::count();\n"
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let id = UUID().uuidString
        let target: [String: Any] = ["local": ["_0": id]]
        try writeState("targets", ["localProjects": [["id": id, "name": "Shop", "path": root.path, "environment": "development", "revision": 1]], "dockerProfiles": []])
        try writeState("session", ["tabs": [["id": UUID().uuidString, "title": "Shop", "code": "", "target": target, "selection": ["location": 0, "length": 0], "createdAt": 0]]])
        let app = try launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: dataDirectory) }
        app.typeKey("l", modifierFlags: [.command, .shift])
        replaceField(app, "snippet-search", with: "shipments")
        XCTAssertTrue(element(app, "project-snippet-copy-personal-button").waitForExistence(timeout: 5))
        element(app, "project-snippet-copy-personal-button").click()
        XCTAssertTrue(waitFor { (try? self.savedSnippets().first?["description"] as? String) == "Pending shipments" })
        let personal = element(app, "snippet-row")
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        XCTAssertTrue(rowText(personal).contains("Pending shipments"), rowText(personal))
        personal.rightClick()
        app.menuItems["Duplicate"].click()
        XCTAssertTrue(waitFor { (try? self.savedSnippets().count) == 3 })
        let snippets = try savedSnippets()
        XCTAssertEqual(snippets[0]["label"] as? String, "Orders copy")
        XCTAssertEqual(snippets[0]["description"] as? String, "Pending shipments")
        XCTAssertEqual(snippets[0]["target"] as? [String: [String: String]], ["local": ["_0": id]])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), contents)
        XCTAssertFalse(element(app, "output-finished").exists)
    }

}
