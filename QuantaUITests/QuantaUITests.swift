import XCTest

final class QuantaUITests: XCTestCase {
    func testLaunchShowsMainWindow() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
}
