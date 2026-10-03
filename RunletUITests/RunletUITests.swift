import AppKit
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

    @MainActor
    func testSpecializedJSONAndTextViewers() throws {
        let app = launch()
        replaceEditorText(app, with: "return '{\"name\":\"Widget\",\"values\":[true,null,3]}';")
        app.typeKey("r", modifierFlags: .command)
        waitForFinished(app, timeout: 60)
        app.radioButtons["JSON"].click()
        XCTAssertTrue(element(app, "json-value-tree").exists)
        XCTAssertTrue(texts(in: element(app, "output-result")).contains("Widget"))
        element(app, "copy-pretty-json").click()
        let copied = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertTrue(copied.contains("\n"))
        let json = try JSONSerialization.jsonObject(with: Data(copied.utf8)) as? [String: Any]
        XCTAssertEqual(json?["name"] as? String, "Widget")
        app.radioButtons["Tree"].click()
        XCTAssertFalse(element(app, "json-value-tree").exists)

        replaceEditorText(app, with: "return str_repeat(\"Widget status is ready. \", 80) . \"\\nWidget at end.\";")
        app.typeKey("r", modifierFlags: .command)
        waitForFinished(app)
        XCTAssertTrue(element(app, "string-text").exists, "long strings default to Text")
        let search = app.textFields["string-search"]
        search.click()
        search.typeText("widget")
        XCTAssertTrue(texts(in: element(app, "string-match-count")).contains("1 of 81"))
        element(app, "string-next-match").click()
        XCTAssertTrue(texts(in: element(app, "string-match-count")).contains("2 of 81"))
        element(app, "string-previous-match").click()
        XCTAssertTrue(texts(in: element(app, "string-match-count")).contains("1 of 81"))
        element(app, "string-wrap").click()
        XCTAssertTrue(element(app, "string-text").exists)
        search.click()
        app.typeKey("a", modifierFlags: .command)
        search.typeText("missing")
        XCTAssertTrue(texts(in: element(app, "string-match-count")).contains("No matches"))
        XCTAssertFalse(element(app, "string-next-match").isEnabled)
    }

    @MainActor
    func testSpecializedImageAndHTMLViewers() throws {
        let app = launch()
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
        let pngData = try XCTUnwrap(Data(base64Encoded: png))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: pngData))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).base64EncodedString()
        for code in ["return '\(png)';", "return base64_decode('\(png)');", "return 'data:image/jpeg;base64,\(jpeg)';"] {
            replaceEditorText(app, with: code)
            app.typeKey("r", modifierFlags: .command)
            waitForFinished(app, timeout: 60)
            XCTAssertTrue(element(app, "string-image-preview").exists)
            XCTAssertFalse(element(app, "string-image-unavailable").exists)
            app.radioButtons["Text"].click()
            XCTAssertTrue(element(app, "string-text").exists)
        }
        let oversized = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4097, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let oversizedPNG = try XCTUnwrap(oversized.representation(using: .png, properties: [:])).base64EncodedString()
        let invalidPNG = Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString()
        for encoded in [oversizedPNG, invalidPNG] {
            replaceEditorText(app, with: "return '\(encoded)';")
            app.typeKey("r", modifierFlags: .command)
            waitForFinished(app)
            XCTAssertTrue(element(app, "string-image-unavailable").exists)
            XCTAssertFalse(element(app, "string-image-preview").exists)
        }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"80\"><rect width=\"120\" height=\"80\" fill=\"teal\"/></svg>"
        replaceEditorText(app, with: "return '\(Data(svg.utf8).base64EncodedString())';")
        app.typeKey("r", modifierFlags: .command)
        waitForFinished(app)
        XCTAssertTrue(element(app, "string-svg-preview").waitForExistence(timeout: 10))

        replaceEditorText(app, with: "return '<h1>HTML string preview</h1><p>Rendered without running again.</p>';")
        app.typeKey("r", modifierFlags: .command)
        waitForFinished(app)
        app.radioButtons["Preview"].click()
        XCTAssertTrue(element(app, "html-preview").waitForExistence(timeout: 10))
        let remote = app.checkBoxes["Load Remote Images"]
        XCTAssertTrue(remote.exists)
        XCTAssertEqual(remote.value as? String, "0")
        app.radioButtons["Source"].click()
        XCTAssertTrue(texts(in: element(app, "output-result")).contains("HTML string preview") || app.textViews.allElementsBoundByIndex.contains { ($0.value as? String ?? "").contains("<h1>HTML string preview</h1>") })
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
    /// #9: real sandbox timings, query metrics, status tooltip, and no stale metrics next run.
    @MainActor func testTimingBreakdownAndStatusDetails() throws {
        let app = launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: dataDirectory) }
        XCTAssertFalse(element(app, "output-finished").exists, "launch/restore must not execute")
        replaceEditorText(app, with: "usleep(125000);\nDB::select('select 1 as number');\nreturn 12;")
        app.typeKey("r", modifierFlags: .command)
        waitForFinished(app, timeout: 60)
        let finished = element(app, "output-finished")
        let status = element(app, "run-status")
        let details = try XCTUnwrap(status.value as? String)
        for label in ["Started:", "Bootstrap:", "Execute:", "Total:", "Peak memory:", "Queries: 1"] {
            XCTAssertTrue(details.contains(label), details)
        }
        XCTAssertFalse(details.contains("Unavailable"), details)
        XCTAssertEqual(finished.value as? String, details, "card and status must share details")
        XCTAssertTrue(texts(in: finished).contains("Bootstrap"))
        XCTAssertTrue(texts(in: finished).contains("Execute"))
        app.typeKey("k", modifierFlags: .command) // Clear Output must keep the completed status metrics.
        XCTAssertEqual(status.value as? String, details)
        replaceEditorText(app, with: "usleep(10000); throw new RuntimeException('timed failure');")
        app.typeKey("r", modifierFlags: .command)
        waitForFinished(app)
        let failed = try XCTUnwrap(status.value as? String)
        XCTAssertTrue(failed.contains("Queries: 0"), failed)
        XCTAssertFalse(failed.contains("Execute: Unavailable"), failed)
        XCTAssertTrue(element(app, "output-error").exists)
        replaceEditorText(app, with: "exit(0);")
        app.typeKey("r", modifierFlags: .command)
        waitForFinished(app)
        let early = try XCTUnwrap(status.value as? String)
        XCTAssertTrue(early.contains("Bootstrap:"), early)
        XCTAssertTrue(early.contains("Execute: Unavailable"), early)
        XCTAssertTrue(early.contains("Queries: 0"), early)
    }

}
