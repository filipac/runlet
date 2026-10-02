import XCTest

final class RunletUITests: XCTestCase {
    func testLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
}
