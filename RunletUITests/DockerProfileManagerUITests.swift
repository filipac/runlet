import XCTest

/// Library ▸ Manage Docker Profiles…: switching, editing with Save and the unsaved-changes
/// prompt, creating from a container, and deleting. Profiles are seeded into an isolated data
/// directory, and Runlet uses the fake Docker CLI (`Tests/Fixtures/fake-docker/docker`), so
/// the developer's real containers are never listed and nothing is executed in a container.
final class DockerProfileManagerUITests: XCTestCase {
    var dataDirectory: URL!
    let shop = UUID()
    let billing = UUID()

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
        dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-profiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("State"), withIntermediateDirectories: true)
        let fakeDocker = Self.repoRoot.appendingPathComponent("Tests/Fixtures/fake-docker/docker").path
        let profiles: [[String: Any]] = [
            ["id": shop.uuidString, "name": "Acme Shop", "identity": ["composeProject": "acme-shop", "composeService": "app"], "workingDirectory": "/var/www/html", "phpExecutable": "php", "temporaryDirectory": "/tmp", "autoResolve": false, "revision": 1],
            ["id": billing.uuidString, "name": "Billing API", "identity": ["composeProject": "billing-api", "composeService": "php"], "workingDirectory": "/app", "phpExecutable": "php", "temporaryDirectory": "/tmp", "autoResolve": false, "revision": 1],
        ]
        let tab: [String: Any] = ["id": UUID().uuidString, "title": "Shop", "code": "'shop'", "target": ["docker": ["_0": shop.uuidString]], "selection": ["location": 0, "length": 0], "createdAt": Date().timeIntervalSinceReferenceDate]
        try write("targets", ["localProjects": [[String: Any]](), "dockerProfiles": profiles])
        try write("session", ["tabs": [tab]])
        try write("settings", ["dockerExecutable": fakeDocker])
    }

    func write(_ name: String, _ data: Any) throws {
        let envelope: [String: Any] = ["schemaVersion": 1, "savedAt": Date().timeIntervalSinceReferenceDate, "data": data]
        try JSONSerialization.data(withJSONObject: envelope).write(to: dataDirectory.appendingPathComponent("State/\(name).json"))
    }

    /// Saved profile names, read back from the app's targets file.
    func savedNames() throws -> [String] {
        let data = try Data(contentsOf: dataDirectory.appendingPathComponent("State/targets.json"))
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let library = envelope?["data"] as? [String: Any]
        let profiles = library?["dockerProfiles"] as? [[String: Any]] ?? []
        return profiles.compactMap { $0["name"] as? String }.sorted()
    }

    @MainActor
    func launchAndOpenManager() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RUNLET_DATA_DIR"] = dataDirectory.path
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("p", modifierFlags: [.command, .shift])
        let search = element(app, "palette-search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("manage docker profiles\r")
        XCTAssertTrue(element(app, "profile-manager-list").waitForExistence(timeout: 5), "manager window did not open")
        return app
    }

    @MainActor
    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        element(app, "profile-manager-row-\(name)")
    }

    @MainActor
    func replaceName(_ app: XCUIApplication, with name: String) {
        let field = element(app, "docker-profile-name")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText(name)
    }

    @MainActor
    func nameValue(_ app: XCUIApplication) -> String {
        (element(app, "docker-profile-name").value as? String) ?? ""
    }

    /// Opens on the current tab's profile; switching loads another; Save writes the edit.
    @MainActor
    func testSwitchEditAndSave() throws {
        let app = launchAndOpenManager()
        XCTAssertTrue(row(app, "Acme Shop").exists)
        XCTAssertTrue(row(app, "Billing API").exists)
        XCTAssertEqual(nameValue(app), "Acme Shop", "should open on the current tab's profile")

        row(app, "Billing API").click()
        XCTAssertEqual(nameValue(app), "Billing API")
        XCTAssertFalse(element(app, "profile-manager-save").isEnabled, "nothing to save yet")

        replaceName(app, with: "Billing Service")
        XCTAssertTrue(element(app, "profile-manager-unsaved").waitForExistence(timeout: 2))
        element(app, "profile-manager-save").click()
        XCTAssertTrue(row(app, "Billing Service").waitForExistence(timeout: 3))
        XCTAssertFalse(element(app, "profile-manager-unsaved").exists)
        XCTAssertEqual(try savedNames(), ["Acme Shop", "Billing Service"])
    }

    /// Switching away from unsaved edits asks; Don't Save drops them, Cancel keeps editing.
    @MainActor
    func testUnsavedChangesPrompt() throws {
        let app = launchAndOpenManager()
        replaceName(app, with: "Renamed Shop")
        row(app, "Billing API").click()
        let dontSave = app.buttons["Don't Save"].firstMatch
        XCTAssertTrue(dontSave.waitForExistence(timeout: 3), "no unsaved-changes prompt")
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertEqual(nameValue(app), "Renamed Shop", "Cancel must keep the edits")

        row(app, "Billing API").click()
        XCTAssertTrue(dontSave.waitForExistence(timeout: 3))
        dontSave.click()
        XCTAssertEqual(nameValue(app), "Billing API")
        XCTAssertEqual(try savedNames(), ["Acme Shop", "Billing API"], "Don't Save must not write")
    }

    /// + starts a draft; choosing a (fake) container fills it in; Save adds the profile.
    @MainActor
    func testCreateFromContainer() throws {
        let app = launchAndOpenManager()
        element(app, "profile-manager-add").click()
        XCTAssertEqual(nameValue(app), "")
        XCTAssertFalse(element(app, "profile-manager-save").isEnabled, "a draft without a container can't be saved")
        let container = element(app, "docker-container-list").descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "acme-shop-worker-1")).firstMatch
        XCTAssertTrue(container.waitForExistence(timeout: 10), "fake containers were not listed")
        container.click()
        XCTAssertEqual(nameValue(app), "worker")
        element(app, "profile-manager-save").click()
        XCTAssertTrue(row(app, "worker").waitForExistence(timeout: 3))
        XCTAssertEqual(try savedNames(), ["Acme Shop", "Billing API", "worker"])
    }

    /// − asks with the same confirmation as the target menu and removes only Runlet's entry.
    @MainActor
    func testDeleteSelectedProfile() throws {
        let app = launchAndOpenManager()
        row(app, "Billing API").click()
        element(app, "profile-manager-remove").click()
        let delete = app.buttons["Delete Profile"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "no delete confirmation")
        delete.click()
        XCTAssertFalse(row(app, "Billing API").waitForExistence(timeout: 2))
        XCTAssertTrue(row(app, "Acme Shop").exists)
        XCTAssertEqual(try savedNames(), ["Acme Shop"])
    }
}
