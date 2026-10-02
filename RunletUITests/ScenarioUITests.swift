import XCTest

/// Acceptance scenarios that need saved targets. Targets are seeded into an isolated data
/// directory (the same versioned JSON the app writes), so no file pickers are driven.
final class ScenarioUITests: XCTestCase {
    var dataDirectory: URL!
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("plan.md").path) { return url }
        }
        return URL(fileURLWithPath: "/")
    }()
    var fixtures: URL { Self.repoRoot.appendingPathComponent("Tests/Fixtures") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-scenario-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("State"), withIntermediateDirectories: true)
    }

    // MARK: Seeding (versioned envelopes, matching JSONDocumentStore)

    func write(_ name: String, _ data: Any) throws {
        let envelope: [String: Any] = ["schemaVersion": 1, "savedAt": Date().timeIntervalSinceReferenceDate, "data": data]
        let json = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted])
        try json.write(to: dataDirectory.appendingPathComponent("State/\(name).json"))
    }

    func local(_ id: UUID) -> [String: Any] { ["local": ["_0": id.uuidString]] }
    func docker(_ id: UUID) -> [String: Any] { ["docker": ["_0": id.uuidString]] }
    var sandbox: [String: Any] { ["sandbox": [String: Any]()] }

    func tab(_ title: String, _ code: String, _ target: [String: Any]) -> [String: Any] {
        ["id": UUID().uuidString, "title": title, "code": code, "target": target, "selection": ["location": 0, "length": 0], "createdAt": Date().timeIntervalSinceReferenceDate]
    }

    func seed(projects: [[String: Any]] = [], profiles: [[String: Any]] = [], tabs: [[String: Any]], settings: [String: Any] = [:]) throws {
        try write("targets", ["localProjects": projects, "dockerProfiles": profiles])
        try write("session", ["tabs": tabs])
        try write("settings", settings)
    }

    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RUNLET_DATA_DIR"] = dataDirectory.path
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        return app
    }

    // MARK: Helpers

    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func texts(in element: XCUIElement) -> String {
        let own = [element.label, (element.value as? String) ?? ""]
        let children = element.descendants(matching: .staticText).allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
        return (own + children).joined(separator: " ")
    }

    /// Clears output, runs the selected tab, and waits for its terminal status.
    @discardableResult
    func run(_ app: XCUIApplication, timeout: TimeInterval = 60) -> String {
        app.typeKey("k", modifierFlags: .command)
        app.typeKey("r", modifierFlags: .command)
        let finished = element(app, "output-finished")
        XCTAssertTrue(finished.waitForExistence(timeout: timeout), "run did not finish")
        return texts(in: element(app, "output-list"))
    }

    func selectTab(_ app: XCUIApplication, _ title: String) {
        let tab = element(app, "tab-\(title)")
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "missing tab \(title)")
        tab.click()
    }

    func editorValue(_ app: XCUIApplication) -> String {
        (app.textViews["code-editor"].value as? String) ?? ""
    }

    /// The UI-test runner is sandboxed and cannot call Docker itself, so Docker scenarios run
    /// when the caller confirms the fixtures are up: TEST_RUNNER_RUNLET_DOCKER_FIXTURES=1.
    func dockerFixturesRunning() -> Bool {
        ProcessInfo.processInfo.environment["RUNLET_DOCKER_FIXTURES"] == "1"
    }

    // MARK: Scenarios

    /// #4: Explain is an editing action, tied to the original run even after retargeting.
    @MainActor func testExplainPreservesCapturedTargetAndWaitsForExplicitProductionRun() throws {
        let project = UUID()
        let template = Self.repoRoot.appendingPathComponent("Resources/Sandbox/laravel")
        let sandboxProject = dataDirectory.appendingPathComponent("laravel")
        try FileManager.default.copyItem(at: template, to: sandboxProject)
        let drivers = sandboxProject.appendingPathComponent(".runlet")
        try FileManager.default.createDirectory(at: drivers, withIntermediateDirectories: true)
        // Resolve the named connection during fixture bootstrap so its live query hooks
        // are installed before the snippet. Every run gets an isolated in-memory DB.
        try """
        <?php
        class ExplainFixtureDriver extends \\Runlet\\Drivers\\LaravelDriver {
            public function bootstrap(string $projectPath): void {
                parent::bootstrap($projectPath);
                $this->app->make('config')->set('database.connections.sqlite.database', ':memory:');
                $this->app->make('db')->connection('sqlite');
            }
        }
        """.write(to: drivers.appendingPathComponent("ExplainFixtureDriver.php"), atomically: true, encoding: .utf8)
        let code = #"Illuminate\Support\Facades\DB::connection('sqlite')->select('select ? as marker', ['$original \' value']);"#
        try seed(projects: [["id": project.uuidString, "name": "Explain fixture", "path": sandboxProject.path,
                             "revision": 1, "environment": "production"]],
                 tabs: [tab("Captured query", code, local(project))])
        var app = launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: dataDirectory)
        }
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element(app, "production-confirmation").waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 60))
        XCTAssertFalse(element(app, "output-error").exists, texts(in: element(app, "output-list")))
        element(app, "target-menu").click()
        let sandboxItem = app.menuItems.matching(identifier: "shippingbox").firstMatch
        XCTAssertTrue(sandboxItem.waitForExistence(timeout: 5))
        sandboxItem.click()
        element(app, "output-section-Queries").click()
        let explain = app.buttons["query-explain-1"]
        XCTAssertTrue(explain.waitForExistence(timeout: 5))
        XCTAssertTrue(explain.isEnabled)
        explain.click()
        XCTAssertTrue(element(app, "tab-Explain #1").waitForExistence(timeout: 5))
        XCTAssertTrue(editorValue(app).contains("EXPLAIN QUERY PLAN select ? as marker"))
        XCTAssertTrue(editorValue(app).contains(#"0 => "\$original ' value""#))
        XCTAssertTrue(editorValue(app).contains(#"$connectionName = "sqlite""#))
        XCTAssertTrue(element(app, "environment-badge-production").exists, "Explain keeps the captured target, not the current sandbox target")
        XCTAssertFalse(element(app, "output-finished").exists)
        XCTAssertFalse(element(app, "production-confirmation").exists, "opening Explain must not request execution")

        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element(app, "production-confirmation").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "output-finished").exists, "Run must wait for production confirmation")
        app.typeKey(.return, modifierFlags: [])
        app.terminate()
        app = launch()
        XCTAssertTrue(editorValue(app).contains("EXPLAIN QUERY PLAN select ? as marker"))
        XCTAssertTrue(element(app, "environment-badge-production").exists)
        XCTAssertFalse(element(app, "output-finished").exists, "restoring Explain must not run it")
        XCTAssertFalse(element(app, "production-confirmation").exists)

        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element(app, "production-confirmation").waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 60))
        XCTAssertFalse(element(app, "output-error").exists, texts(in: element(app, "output-list")))
        element(app, "output-mode-picker").radioButtons["Plain"].click()
        XCTAssertTrue(texts(in: element(app, "output-transcript")).contains("SCAN CONSTANT ROW"), "confirmed Explain returns a SQLite plan")
    }

    /// Scenarios 2, 3, 5: native Laravel and Composer projects and the sandbox in separate
    /// tabs; switch repeatedly and check every result belongs to its own target.
    func testManyApplicationsInSeparateTabs() throws {
        let laravel = UUID()
        let composer = UUID()
        try seed(
            projects: [
                ["id": laravel.uuidString, "name": "Fixture Laravel", "path": fixtures.appendingPathComponent("laravel-app").path, "revision": 1],
                ["id": composer.uuidString, "name": "Fixture Composer", "path": fixtures.appendingPathComponent("composer").path, "revision": 1],
            ],
            tabs: [
                tab("Laravel", "app(App\\Services\\PriceFormatter::class)->format(App\\Models\\Widget::expensive()->sum('price'))", local(laravel)),
                tab("Composer", "(new Acme\\Greeter('Hi'))->greet('Runlet')", local(composer)),
                tab("Sandbox", "'sandbox:' . app()->version()", sandbox),
            ]
        )
        let app = launch()
        let expectations = [("Laravel", "$14.50", "Fixture Laravel"), ("Composer", "Hi, Runlet!", "Fixture Composer"), ("Sandbox", "sandbox:13.34.0", "Sandbox")]
        for round in 1...2 {
            for (title, result, label) in expectations {
                selectTab(app, title)
                let output = run(app)
                XCTAssertTrue(output.contains(result), "round \(round), \(title): \(output)")
                XCTAssertTrue(texts(in: element(app, "output-header")).contains(label), "round \(round), \(title) label")
                for (otherTitle, otherResult, _) in expectations where otherTitle != title {
                    XCTAssertFalse(output.contains(otherResult), "\(title) shows \(otherTitle)'s result")
                }
            }
        }
        // Editing project code is visible on the next run (fresh context per run).
        let probe = fixtures.appendingPathComponent("laravel-app/app/Services/UiEditProbe.php")
        defer { try? FileManager.default.removeItem(at: probe) }
        if (try? "<?php namespace App\\Services; class UiEditProbe { public static function v() { return 'edit-one'; } }".write(to: probe, atomically: true, encoding: .utf8)) != nil {
            selectTab(app, "Laravel")
            let editor = app.textViews["code-editor"]
            editor.click()
            app.typeKey("a", modifierFlags: .command)
            editor.typeText("App\\Services\\UiEditProbe::v()")
            XCTAssertTrue(run(app).contains("edit-one"))
            try "<?php namespace App\\Services; class UiEditProbe { public static function v() { return 'edit-two'; } }".write(to: probe, atomically: true, encoding: .utf8)
            XCTAssertTrue(run(app).contains("edit-two"))
        }
    }

    /// Scenarios 4, 7, 9: existing Docker applications, a restricted non-root read-only
    /// container, and Stop leaving the container running.
    func testDockerProfilesRunAndStop() throws {
        try XCTSkipUnless(dockerFixturesRunning(), "start fixtures with scripts/setup-fixtures.sh docker")
        let laravel = UUID()
        let restricted = UUID()
        try seed(
            profiles: [
                ["id": laravel.uuidString, "name": "Fixture App", "identity": ["composeProject": "runlet-fixtures", "composeService": "laravel"], "workingDirectory": "/var/www/html", "phpExecutable": "php", "temporaryDirectory": "/tmp", "autoResolve": true, "revision": 1],
                ["id": restricted.uuidString, "name": "Restricted", "identity": ["composeProject": "runlet-fixtures", "composeService": "restricted"], "workingDirectory": "/app", "phpExecutable": "php", "user": "1000:1000", "temporaryDirectory": "/scratch", "autoResolve": true, "revision": 1],
            ],
            tabs: [
                tab("Docker App", "dump(getenv('FIXTURE_SERVICE'));\nApp\\Models\\Widget::orderBy('price')->pluck('name')->implode(',')", docker(laravel)),
                tab("Restricted", "posix_geteuid() . ' ' . PHP_VERSION . ' ' . (new Acme\\Greeter())->greet('ro')", docker(restricted)),
            ]
        )
        let app = launch()
        selectTab(app, "Docker App")
        var output = run(app)
        XCTAssertTrue(output.contains("Gear,Sprocket,Flywheel"), output)
        XCTAssertTrue(output.contains("laravel"), output)
        XCTAssertTrue(texts(in: element(app, "output-header")).contains("Fixture App"))

        selectTab(app, "Restricted")
        output = run(app)
        XCTAssertTrue(output.contains("1000 7.4"), output)
        XCTAssertTrue(output.contains("Hello, ro!"), output)

        // Stop a long Docker run, then show the container still serves runs.
        let editor = app.textViews["code-editor"]
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        editor.typeText("echo 'go';\nsleep(60);")
        app.typeKey("k", modifierFlags: .command)
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element(app, "output-stdout").waitForExistence(timeout: 30))
        let stopAt = Date()
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 10))
        XCTAssertLessThan(Date().timeIntervalSince(stopAt), 6)
        XCTAssertTrue(texts(in: element(app, "output-finished")).contains("Stopped"))
        XCTAssertFalse(element(app, "status-bar").staticTexts.matching(NSPredicate(format: "label CONTAINS 'may still be running'")).firstMatch.exists)

        editor.click()
        app.typeKey("a", modifierFlags: .command)
        editor.typeText("'still running'")
        XCTAssertTrue(run(app).contains("still running"))
    }

    /// Scenario 12: the sandbox in Docker (no host PHP used for execution).
    func testSandboxInDocker() throws {
        try XCTSkipUnless(dockerFixturesRunning(), "requires Docker")
        try seed(tabs: [tab("Docker Sandbox", "PHP_VERSION . ' ' . app()->version()", sandbox)], settings: ["sandboxRuntime": "docker"])
        let app = launch()
        let output = run(app, timeout: 120)
        XCTAssertTrue(output.contains("8.4"), output)
        XCTAssertTrue(output.contains("13.34.0"), output)
        XCTAssertTrue(texts(in: element(app, "output-header")).contains("(Docker)"))
    }

    /// Output display modes: structured cards with a table view, plain transcript, raw bytes.
    func testOutputModesAndTable() throws {
        try seed(tabs: [tab("Modes", "echo \"raw text\\n\";\ndump(['a' => 1]);\n[['id' => 1, 'name' => 'x'], ['id' => 2, 'name' => 'y']]", sandbox)])
        let app = launch()
        run(app)
        let viewPicker = element(app, "value-view-picker")
        XCTAssertTrue(viewPicker.waitForExistence(timeout: 5))
        viewPicker.radioButtons.element(boundBy: 1).click()
        XCTAssertTrue(element(app, "value-table").waitForExistence(timeout: 5))

        let modes = element(app, "output-mode-picker")
        modes.radioButtons["Raw"].click()
        let transcript = element(app, "output-transcript")
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let raw = texts(in: transcript)
        XCTAssertTrue(raw.contains("raw text"), raw)
        XCTAssertFalse(raw.contains("dump"), raw)

        modes.radioButtons["Plain"].click()
        let plain = texts(in: element(app, "output-transcript"))
        XCTAssertTrue(plain.contains("dump"), plain)
        XCTAssertTrue(plain.contains("=>"), plain)
        modes.radioButtons["Structured"].click()
    }

    /// Scenario 10 (library half): history and snippets persist; restoring never runs code.
    func testHistoryAndSnippetsPersist() throws {
        try seed(tabs: [tab("Library", "'history-entry'", sandbox)])
        var app = launch()
        XCTAssertTrue(run(app).contains("history-entry"))

        app.typeKey("y", modifierFlags: .command)
        let historyRow = element(app, "history-row")
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
        historyRow.doubleClick()
        XCTAssertTrue(editorValue(app).contains("'history-entry'"))
        sleep(1)
        XCTAssertFalse(element(app, "output-finished").exists, "restoring history must not run code")

        app.typeKey("s", modifierFlags: [.command, .option])
        let label = element(app, "snippet-label-field")
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        label.click()
        label.typeText("Saved UI snippet")
        element(app, "snippet-save-button").click()
        XCTAssertTrue(element(app, "snippet-row").waitForExistence(timeout: 5))
        sleep(1)
        app.terminate()

        app = launch()
        app.typeKey("l", modifierFlags: [.command, .shift])
        let snippetRow = element(app, "snippet-row")
        XCTAssertTrue(snippetRow.waitForExistence(timeout: 5))
        XCTAssertTrue(texts(in: snippetRow).contains("Saved UI snippet"))
        app.typeKey("y", modifierFlags: .command)
        XCTAssertTrue(element(app, "history-row").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "output-finished").exists)
    }

    /// M21: open a PHP file, edit, save; saving writes the file and never executes code.
    func testOpenEditAndSaveFileWithoutRunning() throws {
        try seed(tabs: [tab("Scratch", "'scratch'", sandbox)])
        let file = dataDirectory.appendingPathComponent("opened-snippet.php")
        let marker = dataDirectory.appendingPathComponent("executed-marker")
        try "<?php\nfile_put_contents('\(marker.path)', 'ran');\necho 'from file';\n".write(to: file, atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["RUNLET_DATA_DIR"] = dataDirectory.path
        app.launchArguments = [file.path]
        app.launch()
        XCTAssertTrue(element(app, "tab-opened-snippet.php").waitForExistence(timeout: 15))
        XCTAssertTrue(editorValue(app).contains("echo 'from file';"))

        let editor = app.textViews["code-editor"]
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("// edited in Runlet\n")
        app.typeKey("s", modifierFlags: .command)
        sleep(1)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("// edited in Runlet"), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "saving or opening must not execute code")
        XCTAssertFalse(element(app, "output-finished").exists)
    }

    /// M06: search saved targets quickly and switch the tab's target (never runs code).
    func testTargetSwitcherSearchesProfiles() throws {
        let api = UUID()
        let worker = UUID()
        try seed(
            profiles: [
                ["id": api.uuidString, "name": "Lease API", "identity": ["composeProject": "lease-api", "composeService": "app"], "workingDirectory": "/var/www/html", "phpExecutable": "php", "temporaryDirectory": "/tmp", "autoResolve": false, "revision": 1],
                ["id": worker.uuidString, "name": "Catalog Worker", "identity": ["composeProject": "catalog", "composeService": "worker"], "workingDirectory": "/app", "phpExecutable": "php", "temporaryDirectory": "/tmp", "autoResolve": false, "revision": 1],
            ],
            tabs: [tab("Switch", "'switch'", sandbox)]
        )
        let app = launch()
        app.typeKey("p", modifierFlags: .command)
        let search = element(app, "palette-search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("@catal")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "palette-row").count, 1)
        search.typeText("\r")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'target-menu' AND title CONTAINS 'Catalog Worker'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "output-finished").exists)
    }
}
