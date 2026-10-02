import AppKit
import XCTest

/// Vertical tabs: toggling, the details on each card, and persistence across relaunch.
final class TabLayoutUITests: XCTestCase {
    /// #1: the native editor's gutter divider used to paint through the title bar and tabs,
    /// even though the editor and tab controls themselves had correct frames.
    @MainActor func testPaneDrawingStaysBelowToolbarInBothTabLayouts() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-titlebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }

        let app = XCUIApplication()
        app.launchEnvironment["RUNLET_DATA_DIR"] = data.path
        let snapshots = data.appendingPathComponent("snapshots")
        app.launchEnvironment["RUNLET_SNAPSHOT_DIR"] = snapshots.path
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let editor = app.textViews["code-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        for vertical in [false, true, false] {
            let sidebar = app.descendants(matching: .any).matching(identifier: "vertical-tabs").firstMatch
            if sidebar.exists != vertical {
                app.buttons["tab-layout-toggle"].click()
                XCTAssertEqual(sidebar.waitForExistence(timeout: 2), vertical)
            }
            // Render Runlet's own window through its Debug capture command so this
            // check needs no Screen Recording access or whole-display capture.
            let existing = Set((try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? [])
            app.typeKey("s", modifierFlags: [.command, .control, .option])
            var snapshot: URL?
            let captured = NSPredicate { _, _ in
                snapshot = ((try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? [])
                    .first { $0.pathExtension == "png" && !existing.contains($0) }
                return snapshot != nil
            }
            let expectation = XCTNSPredicateExpectation(predicate: captured, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
            let png = try Data(contentsOf: XCTUnwrap(snapshot))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = vertical ? "Vertical tabs — title bar" : "Horizontal tabs — title bar"
            attachment.lifetime = .keepAlways
            add(attachment)

            let image = try XCTUnwrap(NSBitmapImageRep(data: png))
            let scale = CGFloat(image.pixelsWide) / window.frame.width
            // Scan a narrow strip around the editor's left edge, above every toolbar
            // control. This detects painted overflow; checking element frames cannot.
            let edge = Int((editor.frame.minX - window.frame.minX) * scale)
            let left = max(0, edge - Int(6 * scale))
            let right = min(image.pixelsWide - 1, edge + Int(6 * scale))
            var rows: [(String, CGFloat)] = [("title bar", 4)]
            if !vertical {
                // Sample just above the editor, below the tab pills. Accessibility
                // reports the pills' bounds rather than the strip's padded bounds.
                rows.append(("horizontal tab strip", editor.frame.minY - window.frame.minY - 3))
            }
            for (name, row) in rows {
                let colors = try (left...right).map { x in
                    try XCTUnwrap(image.colorAt(x: x, y: Int(row * scale))?.usingColorSpace(.deviceRGB))
                }
                for component in [\NSColor.redComponent, \NSColor.greenComponent, \NSColor.blueComponent] {
                    let values = colors.map { $0[keyPath: component] }
                    XCTAssertLessThan(try XCTUnwrap(values.max()) - XCTUnwrap(values.min()), 0.03,
                                      "A pane divider/background extends behind the \(name) (vertical=\(vertical))")
                }
            }
        }
    }

    func testVerticalTabsPersistAndShowTargetDetails() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        func launch() -> XCUIApplication {
            let app = XCUIApplication()
            app.launchEnvironment["RUNLET_DATA_DIR"] = data.path
            if let snapshots = ProcessInfo.processInfo.environment["RUNLET_SNAPSHOT_DIR"] {
                app.launchEnvironment["RUNLET_SNAPSHOT_DIR"] = snapshots
            }
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
            return app
        }
        func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: id).firstMatch
        }

        var app = launch()
        XCTAssertFalse(element(app, "vertical-tabs").exists, "horizontal by default")
        app.typeKey("t", modifierFlags: [.command, .control])
        XCTAssertTrue(element(app, "vertical-tabs").waitForExistence(timeout: 5))

        // Run once so the card learns PHP/framework details from the run.
        let editor = app.textViews["code-editor"]
        editor.click()
        editor.typeText("PHP_VERSION")
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element(app, "output-finished").waitForExistence(timeout: 60))
        let card = element(app, "tab-Tab 1")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let label = card.label
        XCTAssertTrue(label.contains("Tab 1"), label)
        XCTAssertTrue(label.contains("PHP "), label)
        XCTAssertTrue(label.contains("Laravel 13.34"), label)
        if ProcessInfo.processInfo.environment["RUNLET_SNAPSHOT_DIR"] != nil {
            app.typeKey("t", modifierFlags: .command)
            app.typeKey("s", modifierFlags: [.command, .control, .option])
            sleep(1)
        }

        sleep(1)
        app.terminate()
        app = launch()
        XCTAssertTrue(element(app, "vertical-tabs").waitForExistence(timeout: 5), "vertical tabs were not remembered")
        app.typeKey("t", modifierFlags: [.command, .control])
        XCTAssertTrue(element(app, "tab-Tab 1").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "vertical-tabs").exists)
    }
}
