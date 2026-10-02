import AppKit
import XCTest

/// Opt-in visual review (TEST_RUNNER_RUNLET_SNAPSHOT_DIR=<dir>): opens each major view and
/// asks the app to render its own windows to PNG (no Screen Recording permission needed).
final class VisualTourUITests: XCTestCase {
    @MainActor
    func shot(_ app: XCUIApplication, _ name: String, window: XCUIElement? = nil) {
        app.typeKey("s", modifierFlags: [.command, .control, .option])
        usleep(400_000)
    }

    @MainActor
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
        // Nor the developer's SSH hosts: a fake ssh (Debug builds; runs execute on this Mac and
        // nothing reaches a server) and a made-up ~/.ssh/config, with one SSH profile.
        let fakeSSH = repo.appendingPathComponent("Tests/Fixtures/fake-ssh/ssh")
        let sshConfig = data.appendingPathComponent("ssh_config")
        try Data("Host shop-prod\n    HostName shop.example.com\n    User forge\n\nHost shop-staging\n    HostName staging.shop.example.com\n    User forge\n".utf8).write(to: sshConfig)
        let sshProfile: [String: Any] = ["id": UUID().uuidString, "name": "Shop", "host": "shop-prod", "user": "forge", "remoteDirectory": repo.appendingPathComponent("Tests/Fixtures/composer").path, "environment": "production"]
        let seededTargets: [String: Any] = ["schemaVersion": 1, "savedAt": 0, "data": ["sshProfiles": [sshProfile]]]
        try JSONSerialization.data(withJSONObject: seededTargets).write(to: data.appendingPathComponent("State/targets.json"))
        let app = XCUIApplication()
        app.launchEnvironment["RUNLET_DATA_DIR"] = data.path
        app.launchEnvironment["RUNLET_SNAPSHOT_DIR"] = snapshots
        app.launchEnvironment["RUNLET_SSH_EXECUTABLE"] = fakeSSH.path
        app.launchEnvironment["RUNLET_SSH_CONFIG"] = sshConfig.path
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

        // The Profiles window (Docker and SSH) with the seeded SSH profile.
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("p", modifierFlags: [.command, .shift])
        let search = app.descendants(matching: .any).matching(identifier: "palette-search").firstMatch
        if search.waitForExistence(timeout: 5) {
            search.typeText("manage profiles\r")
            sleep(2)
            shot(app, "13-profiles")
        }
    }
}
