import XCTest

final class SmokeUITests: XCTestCase {
    @MainActor
    func testLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
        app.launch()
        XCTAssertTrue(app.staticTexts["title"].waitForExistence(timeout: 10))
    }
}
