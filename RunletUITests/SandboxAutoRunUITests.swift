import XCTest

/// #30: real editor events and PHP side effects, with isolated sandbox/session data.
final class SandboxAutoRunUITests: XCTestCase {
    var data: URL!
    var marker: URL { data.appendingPathComponent("runs.txt") }
    var code: String {
        "file_put_contents('\(marker.path)', \"run\\n\", FILE_APPEND);\nreturn 'whole-tab-result';\n// "
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        data = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-auto-\(UUID())")
        try FileManager.default.createDirectory(at: data.appendingPathComponent("State"), withIntermediateDirectories: true)
    }

    func write(_ name: String, _ value: Any) throws {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "savedAt": 0, "data": value])
            .write(to: data.appendingPathComponent("State/\(name).json"))
    }
    func tab(_ title: String, _ target: [String: Any], file: URL? = nil) -> [String: Any] {
        var result: [String: Any] = ["id": UUID().uuidString, "title": title, "code": code,
            "target": target, "selection": ["location": 0, "length": 0], "createdAt": 0]
        if let file { result["fileURL"] = file.absoluteString }
        return result
    }
    var sandbox: [String: Any] { ["sandbox": [String: Any]() ] }
    func count() -> Int {
        ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }
    @MainActor func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RUNLET_DATA_DIR"] = data.path
        app.launch()
        XCTAssertTrue(app.textViews["code-editor"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor func edit(_ app: XCUIApplication, _ text: String = "x") {
        let editor = app.textViews["code-editor"]
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText(text)
    }
    @MainActor func isOn(_ app: XCUIApplication) -> Bool {
        element(app, "auto-run-toggle").label.contains("AUTO")
    }

    @MainActor func testOptInDebouncesWholeTabAndNeverRestores() throws {
        try write("session", ["tabs": [tab("Auto sandbox", sandbox), tab("Other sandbox", sandbox)]])
        try write("settings", ["runPrefersSelection": true])
        var app = launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: data) }
        XCTAssertFalse(isOn(app))
        edit(app, "off")
        usleep(1_200_000)
        XCTAssertEqual(count(), 0, "edits are off by default")
        element(app, "auto-run-toggle").click()
        XCTAssertTrue(isOn(app))
        usleep(1_200_000)
        XCTAssertEqual(count(), 0, "opting in does not run existing code")

        let editor = app.textViews["code-editor"]
        editor.typeText("a")
        usleep(200_000)
        editor.typeText("b")
        app.typeKey(.leftArrow, modifierFlags: .shift) // Select only b, not executable PHP.
        XCTAssertEqual(count(), 0, "the edit debounce must not execute immediately")
        XCTAssertTrue(wait { count() == 1 })
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "output-error").exists, "auto-run must ignore the selection")
        usleep(1_200_000)
        XCTAssertEqual(count(), 1, "rapid edits coalesce into one execution")

        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertFalse(isOn(app), "opt-in belongs to one tab")
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(isOn(app))
        edit(app, "manual")
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(wait { count() == 2 })
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 15))
        usleep(1_200_000)
        XCTAssertEqual(count(), 2, "explicit Run cancels the pending automatic execution")
        // Cancel a pending edit by disabling before the debounce expires.
        edit(app)
        element(app, "auto-run-toggle").click()
        usleep(1_200_000)
        XCTAssertEqual(count(), 2)
        element(app, "auto-run-toggle").click()
        usleep(800_000) // Give the normal session saver time to persist the edited code.
        app.terminate()
        app = launch()
        XCTAssertFalse(isOn(app), "session restoration must discard opt-in")
        edit(app, "restored")
        usleep(1_200_000)
        XCTAssertEqual(count(), 2, "restoring or editing a restored tab must not execute")
    }

    @MainActor func testOnlySandboxOffersOptInAndRetargetingResetsIt() throws {
        let local = UUID().uuidString, docker = UUID().uuidString, ssh = UUID().uuidString
        try write("targets", [
            "localProjects": [["id": local, "name": "Example production", "path": data.path, "revision": 1, "environment": "production"]],
            "dockerProfiles": [["id": docker, "name": "Example container", "identity": ["containerName": "example"], "workingDirectory": "/app", "phpExecutable": "php", "temporaryDirectory": "/tmp", "autoResolve": false, "revision": 1]],
            "sshProfiles": [["id": ssh, "name": "Example server", "host": "example.invalid", "remoteDirectory": "/app", "phpExecutable": "php", "authentication": "automatic", "environment": "production", "revision": 1]]])
        try write("session", ["tabs": [tab("Sandbox", sandbox), tab("Local", ["local": ["_0": local]]),
            tab("Docker", ["docker": ["_0": docker]]), tab("SSH", ["ssh": ["_0": ssh]])]])
        let app = launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: data) }
        for _ in ["Local", "Docker", "SSH"] {
            app.typeKey("]", modifierFlags: [.command, .shift])
            XCTAssertFalse(element(app, "auto-run-toggle").exists)
            edit(app)
            usleep(1_000_000)
            XCTAssertEqual(count(), 0)
            XCTAssertFalse(element(app, "production-confirmation").exists)
        }
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element(app, "production-confirmation").waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: []) // Cancel, preserving the explicit-run guard.
        XCTAssertEqual(count(), 0)
        app.typeKey("[", modifierFlags: [.command, .shift])
        element(app, "auto-run-toggle").click()
        XCTAssertTrue(isOn(app))
        element(app, "target-menu").click()
        let projectItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "Example production")).firstMatch
        XCTAssertTrue(projectItem.waitForExistence(timeout: 5))
        projectItem.click()
        XCTAssertFalse(element(app, "auto-run-toggle").exists)
        element(app, "target-menu").click()
        let sandboxItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "Laravel Sandbox")).firstMatch
        XCTAssertTrue(sandboxItem.waitForExistence(timeout: 5))
        sandboxItem.click()
        XCTAssertFalse(isOn(app), "returning to sandbox requires a fresh opt-in")
        edit(app)
        usleep(1_200_000)
        XCTAssertEqual(count(), 0)
    }

    @MainActor func testExternalFileLoadDisarmsAutoRun() throws {
        let file = data.appendingPathComponent("example.php")
        try code.write(to: file, atomically: true, encoding: .utf8)
        try write("session", ["tabs": [tab("example.php", sandbox, file: file)]])
        let app = launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: data) }
        element(app, "auto-run-toggle").click()
        XCTAssertTrue(isOn(app))
        let replacement = code + "loaded from disk"
        try replacement.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(wait { (app.textViews["code-editor"].value as? String) == replacement })
        XCTAssertFalse(isOn(app), "file reloads are loads, not opted-in editor edits")
        usleep(1_200_000)
        XCTAssertEqual(count(), 0)
        edit(app)
        usleep(1_200_000)
        XCTAssertEqual(count(), 0)
    }
    @MainActor func testEditsDuringRunWaitWithoutOverlapping() throws {
        var slow = tab("Slow sandbox", sandbox)
        slow["code"] = """
        $lock = fopen('\(data.path)/lock', 'c');
        if (!flock($lock, LOCK_EX | LOCK_NB)) { file_put_contents('\(data.path)/overlap', 'overlap'); }
        usleep(2500000);
        file_put_contents('\(marker.path)', "run\\n", FILE_APPEND);
        return 'finished';
        //
        """
        try write("session", ["tabs": [slow]])
        let app = launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: data) }
        element(app, "auto-run-toggle").click()
        edit(app)
        XCTAssertTrue(element(app, "stop-button").waitForExistence(timeout: 15))
        edit(app, "queued")
        XCTAssertTrue(wait { count() == 2 }, "the latest edit should run after the active run finishes")
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 15))
        usleep(1_200_000)
        XCTAssertEqual(count(), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("overlap").path))
        XCTAssertFalse(element(app, "output-error").exists)
    }

    @MainActor func testStopAndCloseCancelPendingExecutionAndReopenIsOff() throws {
        var slow = tab("Slow sandbox", sandbox)
        slow["code"] = "usleep(5000000);\n" + code
        try write("session", ["tabs": [slow]])
        let app = launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: data) }
        element(app, "auto-run-toggle").click()
        edit(app)
        XCTAssertTrue(element(app, "stop-button").waitForExistence(timeout: 15))
        edit(app, "queued")
        element(app, "stop-button").click()
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 15))
        usleep(1_200_000)
        XCTAssertEqual(count(), 0, "Stop must cancel the queued auto-run")
        XCTAssertFalse(element(app, "stop-button").exists)
        edit(app, "close")
        app.typeKey("w", modifierFlags: .command)
        usleep(1_200_000)
        XCTAssertEqual(count(), 0, "closing a tab must cancel its pending execution")
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(element(app, "tab-Slow sandbox").waitForExistence(timeout: 5))
        XCTAssertFalse(isOn(app), "reopened tabs require a new opt-in")
        edit(app, "reopened")
        usleep(1_200_000)
        XCTAssertEqual(count(), 0)
    }

    @MainActor func testHistoryLoadIntoEnabledTabDisarmsAutoRun() throws {
        try write("session", ["tabs": [tab("Sandbox", sandbox)]])
        try write("settings", ["libraryOpenBehavior": "currentTab"])
        let app = launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: data) }
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(wait { count() == 1 })
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 15))
        element(app, "auto-run-toggle").click()
        XCTAssertTrue(isOn(app))
        app.typeKey("y", modifierFlags: .command)
        let row = element(app, "history-row")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.doubleClick()
        XCTAssertFalse(isOn(app), "loading history into an opted-in tab must reset it")
        usleep(1_200_000)
        XCTAssertEqual(count(), 1)
        edit(app, "loaded")
        usleep(1_200_000)
        XCTAssertEqual(count(), 1)
    }

}
