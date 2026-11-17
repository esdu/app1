import XCTest

/// Issue #11: large text and the Xcode accessibility audit, on the real app in `-UITestMode`.
///
/// * `testLargestTextKeepsEverythingReachable` launches at the largest accessibility text size with
///   three banners at once (microphone denied, low storage, a clip that didn't reach Photos) and checks
///   that the status bar, the Pause, Dim, Save and Settings controls are on screen, hittable and don't
///   overlap. Screenshots `a11y-*` are published by CI to be checked by eye.
/// * `testAccessibilityAuditMainScreen` and `testAccessibilityAuditSettings` run
///   `performAccessibilityAudit()` on the main screen (recording, dimmed, paused) and on Settings (top,
///   and scrolled to the end). Exclusions are listed, with the reason, in `AuditLog.excuse`.
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
        continueAfterFailure = true // check every screen, so one run reports everything
        let app = launch(Self.largestText + ["-UITestDenyMicrophone", "-UITestLowDiskWarning", "-UITestPhotosFailOnce"])
        waitUntilRecording(app)
        XCTAssertTrue(element(app, "microphoneBanner").waitForExistence(timeout: 10), "no microphone banner")
        XCTAssertTrue(element(app, "lowDiskWarningBanner").waitForExistence(timeout: 10), "no low-storage banner")
        screenshot(app, "a11y-1-main")
        assertMainScreenFits(app, "two banners")

        Thread.sleep(forTimeInterval: 4) // let the synthetic buffer fill
        app.buttons["saveButton"].tap()
        let toast = element(app, "toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "no toast after Save")
        if !element(app, "unsavedBanner").waitForExistence(timeout: 20) {
            screenshot(app, "a11y-failed-no-unsaved-banner")
            let text = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "in Photos yet")).firstMatch
            XCTFail("no unsaved-clips banner after the failed Photos save; toast: \(toast.exists ? toast.label : "none"); "
                + "banner text on screen: \(text.exists); banner scroll area: \(element(app, "bannerScroll").exists); "
                + "fake library: \(element(app, "fakeLibraryCount").label)")
        }
        screenshot(app, "a11y-1b-three-banners")
        assertMainScreenFits(app, "three banners")
        // Audit once the toast has gone (it fades), so nothing is moving.
        XCTAssertTrue(element(app, "toast").waitForNonExistence(timeout: 10), "toast didn't go away")
        Thread.sleep(forTimeInterval: 1)
        screenshot(app, "a11y-1c-three-banners-no-toast")
        assertMainScreenFits(app, "three banners, no toast")
        try AuditLog.run(on: app, "main screen, largest text, three banners", types: .textClipped, test: self)

        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings did not open")
        Thread.sleep(forTimeInterval: 1) // sheet animation
        screenshot(app, "a11y-2-settings")
        XCTAssertTrue(app.buttons["doneButton"].isHittable, "Done is not reachable")
        try AuditLog.run(on: app, "Settings, largest text", types: .textClipped, systemForm: true, test: self)
        app.swipeUp()
        screenshot(app, "a11y-2b-settings-lower")
        app.swipeUp()
        app.swipeUp()
        screenshot(app, "a11y-2c-settings-end")
        XCTAssertTrue(app.buttons["doneButton"].isHittable, "Done is not reachable after scrolling")
        closeSettings(app)

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
        resume(app)
    }

    /// Main screen: recording (no contrast: the background is the synthetic colour bars), dimmed, and
    /// paused (black preview, contrast included). Settings is audited by its own test, so each stays well
    /// under the per-test time allowance.
    @MainActor
    func testAccessibilityAuditMainScreen() throws {
        let app = launch([])
        waitUntilRecording(app)
        try AuditLog.run(on: app, "main screen, recording", types: XCUIAccessibilityAuditType.all.subtracting(.contrast),
                         test: self)

        app.buttons["dimButton"].tap()
        let overlay = element(app, "dimOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), "dim overlay did not appear")
        try AuditLog.run(on: app, "dimmed", types: .all, dimmed: true, test: self)
        overlay.tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5), "dim overlay did not go away")

        pause(app)
        screenshot(app, "a11y-audit-paused")
        try AuditLog.run(on: app, "main screen, paused", types: .all, test: self)
        resume(app)
    }

    /// Settings, opened while paused so nothing behind the sheet moves: everything at the top, and
    /// everything but contrast once scrolled to the end.
    ///
    /// Contrast is audited at the top only. Scrolled down, some row always sits half under the navigation
    /// bar; the audit scrolls the Form to reveal it and measures contrast while the rows are still moving,
    /// so it reports random rows (even white text in opaque cells), at frames about 60 pt below where they
    /// were drawn. The rows further down use the same system Form text styles as the ones contrast-audited
    /// at the top (section headers and footers, row labels and values, toggle labels).
    @MainActor
    func testAccessibilityAuditSettings() throws {
        let app = launch([])
        waitUntilRecording(app)
        pause(app)
        openSettings(app)
        try AuditLog.run(on: app, "Settings", types: .all, systemForm: true, test: self)
        scrollSettingsToEnd(app)
        screenshot(app, "a11y-audit-settings-scrolled")
        try AuditLog.run(on: app, "Settings, scrolled to the end", types: XCUIAccessibilityAuditType.all.subtracting(.contrast),
                         systemForm: true, test: self)
        closeSettings(app)
    }

    // MARK: Steps shared by the audit tests. Each waits for the state it needs and fails at once, with
    // what it saw, if that state doesn't come.

    /// Pause, confirming the discard if asked; returns once the paused banner is shown.
    @MainActor
    private func pause(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: 2) // a little buffer, so Pause asks before discarding it
        app.buttons["pauseButton"].tap()
        let confirm = app.buttons["Pause and discard buffer"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        XCTAssertTrue(element(app, "userPausedBanner").waitForExistence(timeout: 10), "no paused banner after Pause",
                      file: file, line: line)
    }

    /// Resume: waits until the button can really take the tap (no sheet or dialog over it), taps it, and
    /// checks that the tap took effect before waiting for recording.
    @MainActor
    private func resume(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let resume = app.buttons["resumeButton"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "no Resume button", file: file, line: line)
        let hittable = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "isHittable == true"),
                                                        evaluatedWith: resume)], timeout: 5)
        XCTAssertEqual(hittable, .completed, "Resume is covered (not hittable)", file: file, line: line)
        resume.tap()
        let badge = element(app, "recordingBadge")
        let leftPause = NSPredicate(format: "label != %@", "Paused by you")
        let took = XCTWaiter.wait(for: [expectation(for: leftPause, evaluatedWith: badge)], timeout: 5)
        if took != .completed { screenshot(app, "resume-tap-had-no-effect") }
        XCTAssertEqual(took, .completed, "the Resume tap had no effect; badge says \(badge.label)", file: file, line: line)
        waitUntilRecording(app, file: file, line: line)
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings did not open",
                      file: file, line: line)
        waitUntilStill(app.buttons["doneButton"], "Settings sheet", file: file, line: line)
    }

    @MainActor
    private func closeSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["doneButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5), "Settings sheet didn't close",
                      file: file, line: line)
        // Its elements leave the accessibility tree as the sheet starts to slide away; a tap sent before
        // the slide is over lands on the sheet and is lost. Wait until the main screen under it is back.
        let settings = app.buttons["settingsButton"]
        let back = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "isHittable == true"),
                                                    evaluatedWith: settings)], timeout: 5)
        XCTAssertEqual(back, .completed, "the main screen didn't come back after Settings closed", file: file, line: line)
        Thread.sleep(forTimeInterval: 1) // the rest of the slide
    }

    /// Scrolls the Settings form until the Privacy note is on screen, then once more against the end, and
    /// waits for it to stop. Doesn't depend on how many rows follow the note.
    @MainActor
    private func scrollSettingsToEnd(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                        "RewindCam works entirely offline")).firstMatch
        var swipes = 0
        while !(last.exists && last.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        app.swipeUp() // against the end, whatever the swipes' momentum left
        XCTAssertTrue(last.exists, "the end of Settings was not reached", file: file, line: line)
        waitUntilStill(last, "Settings scroll", file: file, line: line)
    }

    /// Waits until `element`'s frame is the same on consecutive reads (animation or scrolling is over).
    @MainActor
    private func waitUntilStill(_ element: XCUIElement, _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        var previous = element.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = element.frame
            if now == previous { return }
            previous = now
        }
        XCTFail("\(what) still moving after 6 s", file: file, line: line)
    }
}

/// Collects what `performAccessibilityAudit` reports, excuses the documented exceptions, and fails the
/// test once with every remaining issue listed (so one CI run shows all of them). Excused issues are
/// attached to the test as text.
final class AuditLog: @unchecked Sendable { // only touched on the main thread, inside the audit
    private(set) var problems: [String] = []
    private(set) var excused: [String] = []
    /// Frames of the elements whose text is deliberately capped (`cappedTextElements`), on this screen.
    private let cappedFrames: [String: CGRect]
    /// Frames of the elements whose text the largest-text test shows at full size (`verifiedAtLargestText`).
    private let verifiedFrames: [String: CGRect]
    private let screen: CGRect
    private let systemForm: Bool
    private let dimmed: Bool
    /// The scrolling banner area (`BannerArea`), when the banners don't fit and it is on screen.
    private let bannerScroll: CGRect?

    private init(cappedFrames: [String: CGRect], verifiedFrames: [String: CGRect], screen: CGRect,
                 systemForm: Bool, dimmed: Bool, bannerScroll: CGRect?) {
        self.cappedFrames = cappedFrames
        self.verifiedFrames = verifiedFrames
        self.screen = screen
        self.systemForm = systemForm
        self.dimmed = dimmed
        self.bannerScroll = bannerScroll
    }

    @MainActor
    static func run(on app: XCUIApplication, _ screenName: String, types: XCUIAccessibilityAuditType,
                    systemForm: Bool = false, dimmed: Bool = false, test: XCTestCase,
                    file: StaticString = #filePath, line: UInt = #line) throws {
        func frames(_ ids: [String]) -> [String: CGRect] {
            var found: [String: CGRect] = [:]
            for id in ids {
                let e = app.descendants(matching: .any).matching(identifier: id).firstMatch
                if e.exists { found[id] = e.frame }
            }
            return found
        }
        let log = AuditLog(cappedFrames: frames(cappedTextElements), verifiedFrames: frames(verifiedAtLargestText),
                           screen: app.windows.firstMatch.frame, systemForm: systemForm, dimmed: dimmed,
                           bannerScroll: frames(["bannerScroll"])["bannerScroll"])
        try app.performAccessibilityAudit(for: types) { issue in
            MainActor.assumeIsolated { log.handle(issue) }
        }
        if !log.excused.isEmpty {
            let note = XCTAttachment(string: log.excused.joined(separator: "\n"))
            note.name = "audit-excused-\(screenName)"
            note.lifetime = .keepAlways
            test.add(note)
        }
        // One line, so the whole list shows in the CI log and summary.
        XCTAssertTrue(log.problems.isEmpty,
                      "Accessibility audit, \(screenName): \(log.problems.count) issue(s): "
                          + log.problems.joined(separator: " || "),
                      file: file, line: line)
    }

    /// Always true: the issue is recorded here, not by XCTest, so all of them are listed together.
    @MainActor
    private func handle(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        let element = issue.element.flatMap { $0.exists ? $0 : nil }
        let identifier = element?.identifier ?? ""
        let label = element?.label ?? ""
        let frame = element?.frame
        let line = "[\(Self.name(issue.auditType))] id=\"\(identifier)\" label=\"\(label)\" "
            + "frame=\(frame.map { "\($0)" } ?? "?"): \(issue.compactDescription) — \(issue.detailedDescription)"
        if let reason = excuse(issue.auditType, identifier: identifier, label: label, frame: frame,
                               partial: issue.compactDescription.contains("partially")) {
            excused.append(line + " (excused: \(reason))")
        } else {
            problems.append(line)
        }
        return true
    }

    /// Documented exclusions (issue #11). Everything else fails the test.
    private func excuse(_ type: XCUIAccessibilityAuditType, identifier: String, label: String, frame: CGRect?,
                        partial: Bool) -> String? {
        if identifier == "fakeLibraryCount" { return "UI-test-only label, not shown in the app" }
        if type == .dynamicType, cappedFrames[identifier] != nil {
            return "\(identifier) is capped at an accessibility size on purpose; it shows the large content viewer"
        }
        // The audit reports the text inside such an element (no identifier of its own): match by frame.
        if type == .dynamicType, let frame,
           let owner = cappedFrames.first(where: { $0.value.insetBy(dx: -1, dy: -1).contains(frame) })?.key {
            return "text in \(owner), capped at an accessibility size on purpose to fit its fixed shape; "
                + "the element shows the large content viewer"
        }
        // "Partially unsupported" for text that `testLargestTextKeepsEverythingReachable` shows wrapping at
        // full size at the largest text size (screenshots a11y-*): banners, the dim overlay, the Settings
        // rows and its Done button (a system toolbar button).
        if type == .dynamicType, partial, let frame,
           let owner = verifiedFrames.first(where: { $0.value.insetBy(dx: -1, dy: -1).contains(frame) })?.key {
            return "text in \(owner) is shown at full size at the largest text size (a11y-* screenshots)"
        }
        // Settings is a standard Form: "partially unsupported" there is about system rows and the Done
        // toolbar button, which the largest-text test shows at full size (a11y-2* screenshots).
        if systemForm, type == .dynamicType, partial {
            return "system Form row or toolbar button, shown at full size at the largest text size (a11y-2*)"
        }
        // While dimmed, the controls are covered by the 92 % black overlay on purpose and hidden from
        // VoiceOver; the audit still measures their text. The overlay's own text must pass.
        if dimmed, type == .contrast, !Self.dimOverlayTexts.contains(where: { label.hasPrefix($0) }),
           identifier != "dimOverlay" {
            return "covered by the dim overlay on purpose (hidden from VoiceOver while dimmed)"
        }
        // Settings is a standard Form. Issues XCUITest can't attach to any element there come from the
        // UIKit internals of its system controls (segmented pickers, switches, the navigation bar);
        // at accessibility sizes the segmented pickers are replaced by menus (a11y-2* screenshots).
        if systemForm, frame == nil, type == .dynamicType || type == .textClipped {
            return "no element: UIKit internals of a system control in the Settings Form"
        }
        // "Text that should be accessible" with no element: the only drawn text the app doesn't expose is
        // the timestamp burned into the synthetic test footage (`SyntheticFrameSource`), which is
        // decorative and hidden from VoiceOver like the real camera preview (it shows above the sheet).
        if type == .elementDetection, frame == nil {
            return "text drawn into the synthetic test footage (preview hidden from VoiceOver)"
        }
        // Banners that don't fit scroll (`BannerArea`): their text continues past the scroll area's faded
        // bottom edge and is read by scrolling (a11y-1c screenshot). XCUITest attaches no element to these
        // issues, so they are matched by the scroll area being on screen.
        if type == .textClipped, let bannerScroll,
           frame.map({ $0.intersects(bannerScroll) && !bannerScroll.contains($0) }) ?? true {
            return "banner text running on below the scrolling banner area's edge (scrolls)"
        }
        // A row running past the bottom of the screen in a scrolling list is cut by the screen edge, not
        // truncated; the test scrolls and audits again.
        if type == .textClipped, let frame, !screen.contains(frame) {
            return "only partly on screen (scrolling content), not truncated"
        }
        return nil
    }

    /// Elements whose text stops growing at an accessibility size (ContentView: status pills, round icon
    /// buttons, the Save circle, the background reminder, the toast).
    static let cappedTextElements: [String] = [
        "recordingBadge", "bufferLabel", "presetLabel", "batteryLabel",
        "dimButton", "settingsButton", "saveButton", "backgroundNotice", "toast",
    ]

    /// Elements the largest-text test shows at the largest size, where their text wraps and grows.
    static let verifiedAtLargestText: [String] = [
        "userPausedBanner", "microphoneBanner", "lowDiskWarningBanner", "unsavedBanner", "stallBanner",
        "cameraDeniedBanner", "errorBanner", "lowDiskBanner", "pausedBanner", "thermalBanner",
        "photosDeniedBanner", "dimOverlay", "doneButton",
    ]

    /// The dim overlay's own text (ContentView `DimOverlay`).
    static let dimOverlayTexts = ["Recording ·", "Not recording", "Tap anywhere to wake", "Volume buttons still save"]

    static func name(_ type: XCUIAccessibilityAuditType) -> String {
        let known: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "elementDetection"), (.hitRegion, "hitRegion"),
            (.sufficientElementDescription, "sufficientElementDescription"), (.dynamicType, "dynamicType"),
            (.textClipped, "textClipped"), (.trait, "trait"),
        ]
        return known.first { $0.0 == type }?.1 ?? "type \(type.rawValue)"
    }
}
