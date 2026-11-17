import XCTest

/// Issue #11: large text and the Xcode accessibility audit, on the real app in `-UITestMode`.
///
/// * `testLargestTextKeepsEverythingReachable` launches at the largest accessibility text size with
///   three banners at once (microphone denied, low storage, a clip that didn't reach Photos) and checks
///   that the status bar, the Pause, Dim, Save and Settings controls are on screen, hittable and don't
///   overlap. Screenshots `a11y-*` are published by CI to be checked by eye.
/// * `testAccessibilityAudit` runs `performAccessibilityAudit()` on the main screen (recording, dimmed,
///   paused) and Settings. Exclusions are listed, with the reason, in `AuditLog.excuse(_:)`.
final class AccessibilityUITests: XCTestCase {

    /// The largest Dynamic Type size (Settings › Accessibility › Display & Text Size › Larger Text, all
    /// the way up).
    static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extraArguments: [String]) -> XCUIApplication {
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
    private func waitUntilRecording(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let badge = element(app, "recordingBadge")
        let recording = NSPredicate(format: "label == %@", "Recording")
        let result = XCTWaiter.wait(for: [expectation(for: recording, evaluatedWith: badge)], timeout: 20)
        XCTAssertEqual(result, .completed, "not recording; badge says \(badge.label)", file: file, line: line)
    }

    /// Status bar and controls: on screen, hittable where they are buttons, and no two overlap.
    @MainActor
    private func assertMainScreenFits(_ app: XCUIApplication, _ when: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let screen = app.windows.firstMatch.frame
        let pauseOrResume = app.buttons["pauseButton"].exists ? "pauseButton" : "resumeButton"
        let buttons = [pauseOrResume, "dimButton", "saveButton", "settingsButton"]
        let pills = ["recordingBadge", "bufferLabel", "presetLabel", "batteryLabel"]
        var frames: [(String, CGRect)] = []
        for id in pills + buttons {
            let e = element(app, id)
            XCTAssertTrue(e.exists, "\(when): \(id) missing", file: file, line: line)
            XCTAssertTrue(screen.contains(e.frame), "\(when): \(id) \(e.frame) not fully on screen \(screen)",
                          file: file, line: line)
            frames.append((id, e.frame))
        }
        for id in buttons {
            XCTAssertTrue(app.buttons[id].isHittable, "\(when): \(id) is not hittable", file: file, line: line)
        }
        for i in frames.indices {
            for j in frames.indices where j > i {
                let overlap = frames[i].1.intersection(frames[j].1)
                XCTAssertTrue(overlap.isNull || overlap.width < 1 || overlap.height < 1,
                              "\(when): \(frames[i].0) \(frames[i].1) overlaps \(frames[j].0) \(frames[j].1)",
                              file: file, line: line)
            }
        }
    }

    @MainActor
    func testLargestTextKeepsEverythingReachable() throws {
        let app = launch(Self.largestText + ["-UITestDenyMicrophone", "-UITestLowDiskWarning", "-UITestPhotosFailOnce"])
        waitUntilRecording(app)
        XCTAssertTrue(element(app, "microphoneBanner").waitForExistence(timeout: 10), "no microphone banner")
        XCTAssertTrue(element(app, "lowDiskWarningBanner").waitForExistence(timeout: 10), "no low-storage banner")
        screenshot(app, "a11y-1-main")
        assertMainScreenFits(app, "two banners")

        Thread.sleep(forTimeInterval: 4) // let the synthetic buffer fill
        app.buttons["saveButton"].tap()
        XCTAssertTrue(element(app, "unsavedBanner").waitForExistence(timeout: 20),
                      "no unsaved-clips banner after the failed Photos save")
        screenshot(app, "a11y-1b-three-banners")
        assertMainScreenFits(app, "three banners")
        try AuditLog.run(on: app, "main screen, largest text, three banners", types: .textClipped, test: self)

        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings did not open")
        Thread.sleep(forTimeInterval: 1) // sheet animation
        screenshot(app, "a11y-2-settings")
        XCTAssertTrue(app.buttons["doneButton"].isHittable, "Done is not reachable")
        try AuditLog.run(on: app, "Settings, largest text", types: .textClipped, test: self)
        app.swipeUp()
        screenshot(app, "a11y-2b-settings-lower")
        app.swipeUp()
        app.swipeUp()
        screenshot(app, "a11y-2c-settings-end")
        XCTAssertTrue(app.buttons["doneButton"].isHittable, "Done is not reachable after scrolling")
        app.buttons["doneButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))

        app.buttons["dimButton"].tap()
        let overlay = element(app, "dimOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), "dim overlay did not appear")
        screenshot(app, "a11y-3-dimmed")
        overlay.tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))

        app.buttons["pauseButton"].tap()
        let confirm = app.buttons["Pause and discard buffer"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        XCTAssertTrue(element(app, "userPausedBanner").waitForExistence(timeout: 10), "no paused banner")
        screenshot(app, "a11y-4-paused")
        assertMainScreenFits(app, "paused")
        app.buttons["resumeButton"].tap()
        waitUntilRecording(app)
    }

    @MainActor
    func testAccessibilityAudit() throws {
        let app = launch([])
        waitUntilRecording(app)
        // Contrast is checked on the paused screen below (black preview): here the background is the
        // synthetic colour-bar pattern, so contrast results would describe the test footage, not the app.
        try AuditLog.run(on: app, "main screen, recording", types: XCUIAccessibilityAuditType.all.subtracting(.contrast),
                         test: self)

        app.buttons["dimButton"].tap()
        let overlay = element(app, "dimOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        try AuditLog.run(on: app, "dimmed", types: .all, test: self)
        overlay.tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))

        Thread.sleep(forTimeInterval: 2)
        app.buttons["pauseButton"].tap()
        let confirm = app.buttons["Pause and discard buffer"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        XCTAssertTrue(element(app, "userPausedBanner").waitForExistence(timeout: 10))
        screenshot(app, "a11y-audit-paused")
        try AuditLog.run(on: app, "main screen, paused", types: .all, test: self)

        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1) // sheet animation
        try AuditLog.run(on: app, "Settings", types: .all, test: self)
        app.swipeUp()
        app.swipeUp()
        try AuditLog.run(on: app, "Settings, scrolled down", types: .all, test: self)
        app.buttons["doneButton"].tap()
        app.buttons["resumeButton"].tap()
        waitUntilRecording(app)
    }
}

/// Collects what `performAccessibilityAudit` reports, excuses the documented exceptions, and fails the
/// test once with every remaining issue listed (so one CI run shows all of them).
final class AuditLog: @unchecked Sendable { // only touched on the main thread, inside the audit
    private(set) var problems: [String] = []
    private(set) var excused: [String] = []

    @MainActor
    static func run(on app: XCUIApplication, _ screen: String, types: XCUIAccessibilityAuditType,
                    test: XCTestCase, file: StaticString = #filePath, line: UInt = #line) throws {
        let log = AuditLog()
        try app.performAccessibilityAudit(for: types) { issue in
            MainActor.assumeIsolated { log.handle(issue) }
        }
        if !log.excused.isEmpty {
            let note = XCTAttachment(string: log.excused.joined(separator: "\n"))
            note.name = "audit-excused-\(screen)"
            note.lifetime = .keepAlways
            test.add(note)
        }
        XCTAssertTrue(log.problems.isEmpty,
                      "Accessibility audit, \(screen): \(log.problems.count) issue(s):\n"
                          + log.problems.joined(separator: "\n"),
                      file: file, line: line)
    }

    /// Always true: the issue is recorded here, not by XCTest, so all of them are listed together.
    @MainActor
    private func handle(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        let identifier = issue.element.flatMap { $0.exists ? $0.identifier : nil } ?? ""
        let label = issue.element.flatMap { $0.exists ? $0.label : nil } ?? ""
        let line = "[\(Self.name(issue.auditType))] id=\"\(identifier)\" label=\"\(label)\": "
            + "\(issue.compactDescription) — \(issue.detailedDescription)"
        if let reason = Self.excuse(issue.auditType, identifier: identifier) {
            excused.append(line + " (excused: \(reason))")
        } else {
            problems.append(line)
        }
        return true
    }

    /// Documented exclusions (issue #11). Everything else fails the test.
    static func excuse(_ type: XCUIAccessibilityAuditType, identifier: String) -> String? {
        switch type {
        case .dynamicType where cappedTextElements.contains(identifier):
            return "text deliberately capped at an accessibility size to fit a fixed shape; shows the large content viewer"
        default:
            return identifier == "fakeLibraryCount" ? "UI-test-only label, not shown in the app" : nil
        }
    }

    /// Elements whose text stops growing at an accessibility size (ContentView: status pills, round icon
    /// buttons, the Save circle, Pause/Resume, the background reminder, the toast).
    static let cappedTextElements: Set<String> = [
        "recordingBadge", "bufferLabel", "presetLabel", "batteryLabel",
        "dimButton", "settingsButton", "saveButton", "pauseButton", "resumeButton",
        "backgroundNotice", "toast",
    ]

    static func name(_ type: XCUIAccessibilityAuditType) -> String {
        let known: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "elementDetection"), (.hitRegion, "hitRegion"),
            (.sufficientElementDescription, "sufficientElementDescription"), (.dynamicType, "dynamicType"),
            (.textClipped, "textClipped"), (.trait, "trait"),
        ]
        return known.first { $0.0 == type }?.1 ?? "type \(type.rawValue)"
    }
}
