import XCTest

/// Drives the real app: native editor input, Run/Stop, output, restoration.
/// Each test uses an isolated data directory (RUNLET_DATA_DIR), so user data is untouched.
final class RunletUITests: XCTestCase {
    var dataDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    }

    func launch(_ extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RUNLET_DATA_DIR"] = dataDirectory.path
        for (key, value) in extra { app.launchEnvironment[key] = value }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        return app
    }

    func editor(_ app: XCUIApplication) -> XCUIElement {
        let editor = app.textViews["code-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        return editor
    }

    func replaceEditorText(_ app: XCUIApplication, with text: String) {
        let editor = editor(app)
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        editor.typeText(text)
    }

    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func waitForFinished(_ app: XCUIApplication, timeout: TimeInterval = 30) {
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: timeout), "run did not finish")
    }

    func texts(in element: XCUIElement) -> String {
        let own = [element.label, (element.value as? String) ?? ""]
        let children = element.descendants(matching: .staticText).allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
        return (own + children).joined(separator: " ")
    }

    /// Window screenshots are opt-in (TEST_RUNNER_RUNLET_UI_SCREENSHOTS=1) because they need
    /// Screen Recording permission. Only Runlet's window is captured, never the full screen.
    func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        guard ProcessInfo.processInfo.environment["RUNLET_UI_SCREENSHOTS"] == "1" else { return }
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Acceptance 1: sandbox without a project, final value, multiple dumps, versions.
    func testSandboxRunShowsResultDumpsAndVersions() throws {
        let app = launch()
        replaceEditorText(app, with: "dump('first');\ndump(['second' => 2]);\ncollect([1, 2, 3])->map(fn ($n) => $n * 2)->sum()")
        app.typeKey("r", modifierFlags: .command)
        waitForFinished(app, timeout: 60)
        let result = element(app, "output-result")
        XCTAssertTrue(result.exists)
        attachScreenshot(app, "sandbox-run")
        XCTAssertTrue(texts(in: result).contains("12"), "result was: \(texts(in: result))")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "output-dump").count, 2)
        let status = texts(in: element(app, "status-bar"))
        XCTAssertTrue(status.contains("PHP"), status)
        XCTAssertTrue(status.contains("Laravel 13.34.0"), status)
        attachScreenshot(app, "sandbox-run")
    }

    /// Acceptance 8: selection runs alone, errors map to editor lines, fix and rerun.
    func testErrorsMapToLinesAndRecover() throws {
        let app = launch()
        replaceEditorText(app, with: "$a = 1;\n$b = ;\n")
        app.typeKey("r", modifierFlags: .command)
        waitForFinished(app)
        XCTAssertTrue(element(app, "output-error").exists)
        XCTAssertTrue(element(app, "error-line-link").exists)
        XCTAssertTrue((element(app, "error-line-link").label).contains("line 2"), element(app, "error-line-link").label)
        attachScreenshot(app, "parse-error")

        replaceEditorText(app, with: "$a = 1;\n$b = 2;\n$a + $b")
        app.typeKey("r", modifierFlags: .command)
        waitForFinished(app)
        XCTAssertFalse(element(app, "output-error").exists)
        XCTAssertTrue(texts(in: element(app, "output-result")).contains("3"))
    }

    func testRunSelectionOnly() throws {
        let app = launch()
        replaceEditorText(app, with: "throw new Exception('not selected');\n40 + 2")
        // Select the second line with the keyboard: move to end, select to line start.
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.leftArrow, modifierFlags: [.command, .shift])
        app.typeKey("r", modifierFlags: [.command, .shift])
        waitForFinished(app)
        XCTAssertFalse(element(app, "output-error").exists)
        XCTAssertTrue(texts(in: element(app, "output-result")).contains("42"))
    }

    /// Acceptance 9 (local half): Stop a long-running run and regain a usable editor.
    func testStopLongRunningRun() throws {
        let app = launch()
        replaceEditorText(app, with: "echo 'started';\nsleep(60);")
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element(app, "output-stdout").waitForExistence(timeout: 30))
        let started = Date()
        app.typeKey(".", modifierFlags: .command)
        waitForFinished(app, timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        XCTAssertTrue(texts(in: element(app, "output-finished")).contains("Stopped"))
        // The editor is usable again.
        replaceEditorText(app, with: "'again'")
        app.typeKey("r", modifierFlags: .command)
        waitForFinished(app)
        XCTAssertTrue(texts(in: element(app, "output-result")).contains("again"))
    }

    /// Acceptance 10: restart restores tabs and code, and nothing runs automatically.
    func testRestartRestoresTabsWithoutRunning() throws {
        var app = launch()
        replaceEditorText(app, with: "file_put_contents(sys_get_temp_dir() . '/runlet-should-not-run', 'x');\n'first tab'")
        app.typeKey("t", modifierFlags: .command)
        replaceEditorText(app, with: "'second tab'")
        sleep(2) // debounced session save
        app.terminate()

        let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runlet-should-not-run")
        try? FileManager.default.removeItem(at: marker)
        app = launch()
        XCTAssertTrue(element(app, "tab-Tab 1").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "tab-Tab 2").exists)
        XCTAssertEqual(editor(app).value as? String, "'second tab'")
        sleep(2)
        XCTAssertFalse(element(app, "output-finished").exists, "nothing may run on restore")
        XCTAssertFalse(element(app, "output-result").exists)
        element(app, "tab-Tab 1").click()
        XCTAssertTrue((editor(app).value as? String ?? "").contains("'first tab'"))
        attachScreenshot(app, "restored-tabs")
    }

    /// Acceptance 13 (partial): completion for a tagless scratch snippet.
    func testCompletionPopupForTaglessSnippet() throws {
        let app = launch()
        replaceEditorText(app, with: "array_ma")
        // PHPantom may still be indexing right after launch; retry the explicit request.
        let list = app.tables["completion-list"]
        for _ in 0..<10 where !list.exists {
            app.typeKey(.space, modifierFlags: .control)
            _ = list.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(list.exists, "completion list did not appear")
        attachScreenshot(app, "completion")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue((editor(app).value as? String ?? "").hasPrefix("array_map"), "\(editor(app).value ?? "")")
    }
}
