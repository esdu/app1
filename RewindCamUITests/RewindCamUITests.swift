import XCTest

/// Runs the real app with `-UITestMode`: synthetic camera, fake Photos in Documents.
final class RewindCamUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["saveButton"].waitForExistence(timeout: 20), "main screen did not appear")
        return app
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    func testSaveAfterFiveSecondsAddsOneClip() {
        let app = launch()
        screenshot(app, "save-1-launched")
        XCTAssertEqual(element(app, "fakeLibraryCount").label, "Fake library: 0")

        Thread.sleep(forTimeInterval: 5) // let the synthetic buffer fill
        screenshot(app, "save-2-after-5s")

        app.buttons["saveButton"].tap()
        let toast = element(app, "toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 20), "no confirmation toast")
        screenshot(app, "save-3-toast")
        XCTAssertTrue(toast.label.contains("Saved"), "toast says: \(toast.label)")

        let count = element(app, "fakeLibraryCount")
        let oneClip = NSPredicate(format: "label == %@", "Fake library: 1")
        wait(for: [expectation(for: oneClip, evaluatedWith: count)], timeout: 10)
        screenshot(app, "save-4-library-has-1")
    }

    /// The fake Photos library fails the first save: the clip is kept, a banner offers Retry, and
    /// Retry adds it.
    @MainActor
    func testPhotosFailureKeepsClipAndRetryAddsIt() {
        let app = launch(extraArguments: ["-UITestPhotosFailOnce"])
        Thread.sleep(forTimeInterval: 5) // let the synthetic buffer fill

        app.buttons["saveButton"].tap()
        let banner = element(app, "unsavedBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "no unsaved-clips banner after a failed Photos save")
        screenshot(app, "unsaved-1-banner")
        XCTAssertEqual(element(app, "fakeLibraryCount").label, "Fake library: 0")

        let retry = app.buttons["retryUnsavedButton"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "no Retry button")
        retry.tap()
        let count = element(app, "fakeLibraryCount")
        let oneClip = NSPredicate(format: "label == %@", "Fake library: 1")
        wait(for: [expectation(for: oneClip, evaluatedWith: count)], timeout: 20)
        XCTAssertTrue(banner.waitForNonExistence(timeout: 10), "banner still shown after a successful retry")
        screenshot(app, "unsaved-2-after-retry")
    }

    /// Microphone denied with "Record sound" on (the default): recording and saving still work, a
    /// banner says sound is off, and its Open Settings button opens the Settings app.
    @MainActor
    func testMicrophoneDeniedShowsNoticeAndSavesStillWork() {
        let app = launch(extraArguments: ["-UITestDenyMicrophone"])
        let banner = element(app, "microphoneBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no microphone banner")
        let openSettings = banner.buttons["openSettingsButton"]
        XCTAssertTrue(openSettings.exists, "no Open Settings button in the microphone banner")
        Thread.sleep(forTimeInterval: 5) // let the synthetic buffer fill
        screenshot(app, "mic-denied-1-banner")

        app.buttons["saveButton"].tap()
        let toast = element(app, "toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 20), "no confirmation toast")
        XCTAssertTrue(toast.label.contains("Saved"), "toast says: \(toast.label)")
        let count = element(app, "fakeLibraryCount")
        let oneClip = NSPredicate(format: "label == %@", "Fake library: 1")
        wait(for: [expectation(for: oneClip, evaluatedWith: count)], timeout: 10)
        screenshot(app, "mic-denied-2-saved")

        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "microphoneSettingsNote").waitForExistence(timeout: 5),
                      "Settings doesn't say why there's no sound")
        XCTAssertTrue(app.switches["audioToggle"].exists)
        XCTAssertEqual(app.switches["audioToggle"].value as? String, "1", "Record sound must stay on")
        screenshot(app, "mic-denied-3-settings")
        app.buttons["doneButton"].tap()

        XCTAssertTrue(openSettings.waitForExistence(timeout: 5))
        openSettings.tap()
        let settingsApp = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settingsApp.wait(for: .runningForeground, timeout: 15), "the Settings app did not open")
    }

    @MainActor
    func testChangeBufferTo60Seconds() {
        let app = launch()
        XCTAssertEqual(element(app, "bufferLabel").label, "Buffer 30 s")
        screenshot(app, "settings-1-main")

        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        screenshot(app, "settings-2-open")

        let sixty = app.buttons["60 s"]
        XCTAssertTrue(sixty.waitForExistence(timeout: 5))
        sixty.tap()
        XCTAssertTrue(sixty.isSelected, "60 s segment should be selected")
        screenshot(app, "settings-3-60s-selected")
        app.swipeUp()
        screenshot(app, "settings-3b-lower-sections")

        app.buttons["doneButton"].tap()
        let label = element(app, "bufferLabel")
        let is60 = NSPredicate(format: "label == %@", "Buffer 60 s")
        wait(for: [expectation(for: is60, evaluatedWith: label)], timeout: 5)
        screenshot(app, "settings-4-main-60s")
    }

    @MainActor
    func testDimModeTogglesOverlay() {
        let app = launch()
        screenshot(app, "dim-1-awake")

        app.buttons["dimButton"].tap()
        let overlay = element(app, "dimOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), "dim overlay did not appear")
        screenshot(app, "dim-2-dimmed")

        overlay.tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5), "dim overlay did not go away")
        XCTAssertTrue(app.buttons["saveButton"].isHittable)
        screenshot(app, "dim-3-awake-again")
    }
}
