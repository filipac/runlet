import AppKit
import XCTest

/// Opt-in visual review (TEST_RUNNER_RUNLET_SNAPSHOT_DIR=<dir>): opens each major view and
/// asks the app to render its own windows to PNG (no Screen Recording permission needed).
final class VisualTourUITests: XCTestCase {
    func shot(_ app: XCUIApplication, _ name: String, window: XCUIElement? = nil) {
        app.typeKey("s", modifierFlags: [.command, .control, .option])
        usleep(400_000)
    }

    func testVisualTour() throws {
        guard let snapshots = ProcessInfo.processInfo.environment["RUNLET_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_RUNLET_SNAPSHOT_DIR=<directory>")
        }
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-tour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data.appendingPathComponent("State"), withIntermediateDirectories: true)
        // Screenshots must never show the developer's real containers: point Runlet at a fake
        // Docker CLI that reports made-up ones.
        var repo = URL(fileURLWithPath: #filePath)
        while repo.path != "/", !FileManager.default.fileExists(atPath: repo.appendingPathComponent("plan.md").path) { repo.deleteLastPathComponent() }
        let fakeDocker = repo.appendingPathComponent("Tests/Fixtures/fake-docker/docker")
        let seededSettings: [String: Any] = ["schemaVersion": 1, "savedAt": 0, "data": ["dockerExecutable": fakeDocker.path]]
        try JSONSerialization.data(withJSONObject: seededSettings).write(to: data.appendingPathComponent("State/settings.json"))
        let app = XCUIApplication()
        app.launchEnvironment["RUNLET_DATA_DIR"] = data.path
        app.launchEnvironment["RUNLET_SNAPSHOT_DIR"] = snapshots
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let editor = app.textViews["code-editor"]
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("$users = collect([\n    ['id' => 1, 'name' => 'Ana', 'email' => 'ana@example.com'],\n    ['id' => 2, 'name' => 'Bo', 'email' => 'bo@example.com'],\n]);\ndump(now());\n$users", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "output-finished").firstMatch.waitForExistence(timeout: 60))
        shot(app, "1-structured")
        app.descendants(matching: .any).matching(identifier: "value-view-picker").firstMatch.radioButtons.element(boundBy: 1).click()
        shot(app, "2-table")
        app.descendants(matching: .any).matching(identifier: "output-mode-picker").firstMatch.radioButtons["Plain"].click()
        shot(app, "3-plain")
        app.descendants(matching: .any).matching(identifier: "output-mode-picker").firstMatch.radioButtons["Structured"].click()

        // Completion popup over the editor.
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("\n$users->")
        sleep(2)
        shot(app, "4-completion")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("y", modifierFlags: .command)
        sleep(1)
        shot(app, "5-history")
        app.typeKey("p", modifierFlags: .command)
        sleep(1)
        shot(app, "6-switcher")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("n", modifierFlags: [.command, .shift])
        sleep(3)
        shot(app, "7-docker-profile")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.element(boundBy: 0)
        sleep(1)
        shot(app, "8-settings", window: settings)
        for (index, tab) in ["Editor", "PHP", "Docker", "Sandbox"].enumerated() {
            let button = settings.toolbars.buttons[tab]
            if button.exists {
                button.click()
                sleep(1)
                shot(app, "\(9 + index)-settings-\(tab.lowercased())", window: settings)
            }
        }
    }
}
