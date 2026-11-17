import Foundation
import Testing
@testable import RewindCam

/// Issue #15: an explicit user pause that every automatic path respects. Starts that are still pending
/// (a slow start, a permission prompt) are held with `SyntheticFrameSource.holdNextStart()`, time is the
/// harness's `FakeDelayScheduler`, so no test sleeps. In the `AppModelTests` suite so it shares its
/// serialization and time limit.
@MainActor
extension AppModelTests {

    private func recordingModel(_ h: ModelHarness) async -> AppModel {
        let model = h.makeModel()
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        #expect(model.phase == .recording)
        return model
    }

    /// The paused state as the user sees it, and nothing running behind it.
    private func expectUserPaused(_ model: AppModel, _ h: ModelHarness, sourceStopped: Bool = true,
                                  _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let checks: [(Bool, String)] = [
            (model.phase == .userPaused, "phase is \(model.phase)"),
            (model.isUserPaused, "isUserPaused"),
            (model.userPausedNotice?.id == "userPausedBanner", "paused notice"),
            (model.startFailureNotice == nil, "no start-failure notice"),
            (model.stallNotice == nil, "no stall notice"),
            (model.recovery == nil, "no recovery"),
            (model.recorder.status().isSuspended, "recorder suspended"),
            (model.activeCapture == nil, "no active capture"),
            (!model.isVoiceListening && !h.voice.isRunning, "voice trigger off"),
            (!h.screen.idleTimerDisabled, "the screen may lock"),
            (!model.isDimmed, "not dimmed"),
            (!model.frameWatchdog.isArmed, "watchdog disarmed"),
            (model.saveUnavailableReason == "Recording is paused. Tap Resume to record again.", "Save says why"),
            (!sourceStopped || h.source.runState == .stopped, "source is \(h.source.runState)"),
        ]
        let context = comment.map { " (" + $0.rawValue + ")" } ?? ""
        for (ok, what) in checks where !ok {
            Issue.record(Comment(rawValue: what + context), sourceLocation: sourceLocation)
        }
    }

    private func expectRecordingAgain(_ model: AppModel, _ h: ModelHarness) async throws {
        #expect(model.phase == .recording)
        #expect(!model.isUserPaused)
        #expect(model.userPausedNotice == nil)
        #expect(h.source.runState == .running)
        #expect(h.screen.idleTimerDisabled)
        h.source.generate(seconds: 3)
        try await waitUntil { model.recorder.status().bufferedSeconds > 0 }
        #expect(model.saveUnavailableReason == nil)
    }

    @Test("Pause: camera off, buffer discarded, voice and dim off, Save refused from every trigger; kept clips stay")
    func pauseStopsCaptureAndRefusesSave() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.updateSettings { $0.voiceTriggerEnabled = true }
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        try await waitUntil { h.voice.isRunning }

        // A clip Photos refused stays kept in the app (issue #1).
        h.library.failNextSaves(["Simulated Photos failure."])
        h.source.generate(seconds: 5)
        let saveTask = try #require(model.save())
        h.source.generate(seconds: 2)
        await saveTask.value
        #expect(model.unsavedClips.count == 1)
        let kept = try #require(model.unsavedClips.first).url

        h.source.generate(seconds: 4)
        try await waitUntil { model.recorder.status().bufferedSeconds >= 2 }
        model.refreshStatus()
        let warning = try #require(model.pauseDiscardWarning, "Pause says what it discards")
        #expect(warning.contains("haven't been saved and will be discarded"))
        #expect(warning.contains("Clips you saved"))
        h.screen.brightness = 0.7
        model.setDimmed(true)
        #expect(h.screen.idleTimerDisabled)

        model.pauseCapture()
        // At once, before any pipeline work: nothing automatic can act in between.
        expectUserPaused(model, h, sourceStopped: false)
        #expect(h.screen.brightness == 0.7, "brightness restored")
        #expect(model.pauseDiscardWarning == nil)
        await model.waitForCapture()
        expectUserPaused(model, h)
        #expect(model.status.bufferedSeconds == 0, "the rolling buffer is discarded")
        #expect(model.recorder.status().segmentCount == 0)
        #expect(FileManager.default.fileExists(atPath: kept.path), "a kept clip is never touched")
        #expect(model.unsavedClips.map(\.url) == [kept])
        let notice = try #require(model.userPausedNotice)
        #expect(notice.severity == .info)
        #expect(notice.action == nil)
        #expect(notice.message.contains("unsaved buffer was discarded"), "message: \(notice.message)")
        #expect(notice.message.contains("Clips you saved"), "message: \(notice.message)")
        #expect(notice.message.contains("until you tap Resume"), "message: \(notice.message)")

        // Save refuses from every trigger, with the reason, and starts nothing.
        let failures = h.haptics.failures
        let begun = h.backgroundTasks.begun
        for trigger in [SaveTrigger.button, .volumeButton, .voice] {
            #expect(model.save(trigger: trigger) == nil)
            #expect(model.toast?.isError == true)
            #expect(model.toast?.message == "Can't save. Recording is paused. Tap Resume to record again.")
        }
        #expect(h.haptics.failures == failures + 3)
        #expect(h.backgroundTasks.begun == begun)
        #expect(!model.isSaving)
        h.voice.hear() // the recogniser was stopped: nothing to call
        #expect(!model.isSaving)

        // Dim is pointless while paused (the screen may lock) and is refused.
        model.setDimmed(true)
        #expect(!model.isDimmed)
        #expect(h.screen.brightness == 0.7)

        // Retry for the kept clip still works while paused.
        let retry = try #require(model.retryUnsavedClips())
        await retry.value
        #expect(model.unsavedClips.isEmpty)
        #expect(h.library.clips().count == 1)

        let starts = h.source.startCount
        // Settings and thermal changes don't start anything.
        model.updateSettings {
            $0.bufferSeconds = 60
            $0.resolution = .hd720
        }
        h.thermal.set(.serious)
        h.thermal.set(.nominal)
        await model.waitForCapture()
        #expect(h.source.startCount == starts)
        expectUserPaused(model, h)

        model.resumeCapture()
        #expect(model.phase == .starting, "says so at once")
        await model.waitForCapture()
        #expect(h.source.startCount == starts + 1)
        try await expectRecordingAgain(model, h)
        try await waitUntil { h.voice.isRunning }
        #expect(model.isVoiceListening)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Pause holds across foreground, a trip to Settings, Try Again, start() and 30 s of status ticks")
    func pauseHoldsUntilResume() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await recordingModel(h)
        model.pauseCapture()
        await model.waitForCapture()
        let starts = h.source.startCount

        model.scenePhaseChanged(.inactive)
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        expectUserPaused(model, h, "foreground without leaving")

        // Open Settings and come back: background, then active.
        model.openAppSettings()
        model.scenePhaseChanged(.inactive)
        model.scenePhaseChanged(.background)
        await model.waitForCapture()
        expectUserPaused(model, h, "in the background it stays the user's pause, not 'backgrounded'")
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        expectUserPaused(model, h, "back from Settings")

        model.retryStart()
        model.start()
        await model.waitForCapture()
        await passTime(30, model, h)
        #expect(h.source.startCount == starts, "nothing started while paused")
        #expect(h.source.resumeCount == 0)
        expectUserPaused(model, h, "after 30 s of status ticks")

        model.pauseCapture() // a second Pause changes nothing
        model.resumeCapture()
        await model.waitForCapture()
        try await expectRecordingAgain(model, h)

        // Without a user pause, the default is unchanged: background pauses, foreground resumes.
        model.scenePhaseChanged(.background)
        await model.waitForCapture()
        #expect(model.phase == .paused(InterruptionReason.backgrounded.message))
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        try await expectRecordingAgain(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Pause while the camera is still starting: the late start publishes nothing and is stopped")
    func pauseDuringPendingStart() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.updateSettings { $0.voiceTriggerEnabled = true }
        h.source.holdNextStart()
        model.scenePhaseChanged(.active)
        await h.source.waitForHeldStart()
        #expect(model.phase == .starting)

        model.pauseCapture()
        expectUserPaused(model, h)
        h.source.releaseHeldStart()
        await model.waitForCapture()
        #expect(h.source.startCount == 1, "the held start did run")
        expectUserPaused(model, h, "the late start left nothing running")
        #expect(h.library.accessRequests == 0, "a stale start doesn't go on to ask for Photos")
        #expect(model.status.bufferedSeconds == 0)

        // Frames that still trickle in reach no buffer.
        h.source.generate(seconds: 2)
        await passTime(10, model, h)
        expectUserPaused(model, h)
        #expect(model.status.bufferedSeconds == 0)

        model.resumeCapture()
        await model.waitForCapture()
        try await expectRecordingAgain(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Pause during the camera permission prompt: a late denial shows nothing; Resume asks again")
    func pauseDuringPermissionPrompt() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        h.source.setStartError(.cameraAccessDenied) // the user will answer "Don't Allow"
        h.source.holdNextStart()
        model.scenePhaseChanged(.active)
        await h.source.waitForHeldStart()

        model.pauseCapture()
        h.source.releaseHeldStart()
        await model.waitForCapture()
        expectUserPaused(model, h, "no camera-denied notice for a start the user paused")
        #expect(h.haptics.failures == 0)

        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        expectUserPaused(model, h)
        #expect(h.source.startCount == 1)

        // Resume tries again, and now says the camera is off.
        model.resumeCapture()
        await model.waitForCapture()
        #expect(model.phase == .cameraDenied)
        #expect(model.startFailureNotice?.action == .openSettings)

        // Same prompt, this time allowed while paused: nothing records.
        h.source.setStartError(nil)
        h.source.holdNextStart()
        model.retryStart()
        await h.source.waitForHeldStart()
        model.pauseCapture()
        h.source.releaseHeldStart()
        await model.waitForCapture()
        expectUserPaused(model, h, "an allowed prompt answered after Pause")

        model.resumeCapture()
        await model.waitForCapture()
        try await expectRecordingAgain(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Background while the camera is still starting: no recording survives, foreground starts as before")
    func backgroundDuringPendingStart() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        h.source.holdNextStart()
        model.scenePhaseChanged(.active)
        await h.source.waitForHeldStart()
        model.scenePhaseChanged(.background)
        h.source.releaseHeldStart()
        await model.waitForCapture()
        #expect(model.phase == .paused(InterruptionReason.backgrounded.message))
        #expect(h.source.runState == .stopped)
        #expect(!h.screen.idleTimerDisabled)
        #expect(model.recorder.status().isSuspended)
        #expect(!model.isUserPaused)

        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        try await expectRecordingAgain(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Rapid pause/resume/background/foreground settles on the newest intent, one session at a time")
    func rapidIntentChangesSettleOnNewest() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        h.source.holdNextStart()
        model.scenePhaseChanged(.active)
        await h.source.waitForHeldStart()

        model.pauseCapture()
        model.resumeCapture()
        model.pauseCapture()
        model.resumeCapture()
        model.scenePhaseChanged(.background)
        model.scenePhaseChanged(.active)
        #expect(h.source.isHoldingStart, "nothing else reached the source while the first start runs")
        h.source.releaseHeldStart()
        await model.waitForCapture()
        #expect(h.source.startCount == 2, "the held start, then only the newest one")
        try await expectRecordingAgain(model, h)

        // Ending on Pause: paused, and stopped.
        model.pauseCapture()
        model.resumeCapture()
        model.scenePhaseChanged(.background)
        model.scenePhaseChanged(.active)
        model.pauseCapture()
        await model.waitForCapture()
        expectUserPaused(model, h)
        #expect(h.source.startCount <= 3)

        model.resumeCapture()
        model.pauseCapture()
        model.resumeCapture()
        await model.waitForCapture()
        try await expectRecordingAgain(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Pause during recovery backoff: no later attempt, no give-up notice; Resume starts fresh")
    func pauseDuringRecoveryBackoff() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await recordingModel(h)
        h.source.setResumeFailures(1_000)
        h.source.simulateRuntimeError(sessionStops: true)
        await model.waitForCapture()
        #expect(model.recovery != nil)
        #expect(h.source.resumeCount == 1)
        h.scheduler.advance(by: 1)
        await model.waitForCapture()
        #expect(h.source.resumeCount == 2)

        model.pauseCapture()
        await model.waitForCapture()
        expectUserPaused(model, h)
        // Every pending backoff timer fires and finds its recovery gone.
        h.scheduler.advance(by: 120)
        await model.waitForCapture()
        #expect(h.source.resumeCount == 2, "no restart attempt after Pause")
        #expect(h.haptics.failures == 0, "no give-up either")
        expectUserPaused(model, h)

        // A runtime error reported while paused starts no recovery.
        h.source.simulateRuntimeError(sessionStops: false)
        await model.waitForCapture()
        #expect(h.source.resumeCount == 2)
        expectUserPaused(model, h)

        h.source.setResumeFailures(0)
        let starts = h.source.startCount
        model.resumeCapture()
        await model.waitForCapture()
        #expect(h.source.startCount == starts + 1, "a fresh start, not a recovery attempt")
        #expect(h.source.resumeCount == 2)
        try await expectRecordingAgain(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Pause while a stall restart is starting the camera: the restart is dropped; the watchdog re-arms after Resume")
    func pauseDuringStallRestart() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await recordingModel(h)
        await passTime(2, model, h, deliver: true)
        #expect(model.frameWatchdog.isArmed)
        h.source.withholdVideo(true)
        await passTime(4.5, model, h)
        let starts = h.source.startCount
        h.source.holdNextStart()
        h.scheduler.advance(by: AppModel.statusInterval)
        #expect(model.recovery?.reason == .stalled(.noVideo))
        await h.source.waitForHeldStart() // the watchdog's restart: stopped, now starting

        model.pauseCapture()
        h.source.releaseHeldStart()
        await model.waitForCapture()
        #expect(h.source.startCount == starts + 1)
        expectUserPaused(model, h, "the restart's late start left nothing running")
        #expect(model.recoveredStall == nil)
        await passTime(30, model, h)
        #expect(h.source.startCount == starts + 1, "no further restart while paused")
        expectUserPaused(model, h)

        // Resume: the watchdog arms on the first tick with a fresh baseline and the full timeout.
        h.source.withholdVideo(false)
        model.resumeCapture()
        await model.waitForCapture()
        #expect(!model.frameWatchdog.isArmed)
        await passTime(2, model, h, deliver: true)
        #expect(model.frameWatchdog.isArmed)
        #expect(model.phase == .recording)
        #expect(model.stallNotice == nil)
        h.source.withholdVideo(true)
        await passTime(4.5, model, h)
        #expect(model.phase == .recording, "4.5 s since the last new frame")
        #expect(model.recovery == nil)
        h.scheduler.advance(by: AppModel.statusInterval)
        #expect(model.recovery?.reason == .stalled(.noVideo), "the re-armed watchdog still catches a stall")
        model.pauseCapture()
        await model.waitForCapture()
        expectUserPaused(model, h)
    }

    @Test("Interruption ended while paused: no resume, no recovery, nothing restarted")
    func interruptionEndedWhilePaused() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await recordingModel(h)
        h.source.simulate(.interrupted(.cameraInUseByAnotherApp))
        await model.waitForCaptureEvents()
        #expect(model.phase == .paused(InterruptionReason.cameraInUseByAnotherApp.message))

        model.pauseCapture()
        await model.waitForCapture()
        expectUserPaused(model, h)
        let starts = h.source.startCount
        // The late "interruption ended" (the synthetic source then reports it runs again, which a stopped
        // session wouldn't; the model must not act on either).
        h.source.simulate(.interruptionEnded)
        await model.waitForCapture()
        expectUserPaused(model, h, sourceStopped: false)
        await passTime(10, model, h)
        expectUserPaused(model, h, sourceStopped: false, "the safety net leaves a user pause alone")
        #expect(h.source.startCount == starts)
        #expect(h.source.resumeCount == 0)

        // An interruption that begins and ends while paused changes nothing either.
        h.source.simulate(.interrupted(.audioInUseByAnotherApp))
        h.source.simulate(.interruptionEnded)
        await model.waitForCapture()
        expectUserPaused(model, h, sourceStopped: false)

        model.resumeCapture()
        await model.waitForCapture()
        try await expectRecordingAgain(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Try Again while paused does nothing; a Try Again still queued when Pause comes is dropped")
    func tryAgainWhilePaused() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.source.setStartError(.noCamera)
        let model = h.makeModel()
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        #expect(model.phase.isStartFailure)
        let starts = h.source.startCount

        // Try Again and Pause in the same run-loop turn: the queued start never reaches the source.
        model.retryStart()
        model.pauseCapture()
        await model.waitForCapture()
        #expect(h.source.startCount == starts)
        expectUserPaused(model, h)

        model.retryStart()
        await model.waitForCapture()
        #expect(h.source.startCount == starts)
        expectUserPaused(model, h)

        // Resume tries the start again (still no camera).
        model.resumeCapture()
        await model.waitForCapture()
        #expect(h.source.startCount == starts + 1)
        #expect(model.startFailureNotice?.action == .tryAgain)

        // Pausing from the failure hides it; Resume brings recording back once the camera works.
        model.pauseCapture()
        await model.waitForCapture()
        expectUserPaused(model, h)
        h.source.setStartError(nil)
        model.resumeCapture()
        await model.waitForCapture()
        try await expectRecordingAgain(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Low disk: the free-space check doesn't run while paused, and a stop it queued just before Pause yields to it")
    func lowDiskWhilePaused() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.disk.set(5_000_000_000)
        let model = await recordingModel(h)
        await passTime(4.5, model, h, deliver: true)
        h.disk.set(50_000_000) // below the reserve
        let reads = h.disk.readCount
        h.source.generate(seconds: AppModel.statusInterval)
        h.scheduler.advance(by: AppModel.statusInterval) // the 5 s check queues the low-disk stop
        #expect(h.disk.readCount == reads + 1)
        model.pauseCapture()
        await model.waitForCapture()
        expectUserPaused(model, h, "Pause wins over the stop queued before it")
        #expect(h.haptics.failures == 0)

        await passTime(30, model, h)
        #expect(h.disk.readCount == reads + 1, "no free-space checks while paused")
        expectUserPaused(model, h)

        // Resume checks like any start.
        model.resumeCapture()
        await model.waitForCapture()
        guard case .outOfSpace = model.phase else {
            Issue.record("expected outOfSpace, got \(model.phase)")
            return
        }
        h.disk.set(5_000_000_000)
        model.retryStart()
        await model.waitForCapture()
        try await expectRecordingAgain(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("A relaunch starts recording: the pause is not persisted")
    func pauseIsNotPersisted() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let first = await recordingModel(h)
        first.pauseCapture()
        await first.waitForCapture()
        #expect(first.isUserPaused)

        let second = h.makeModel()
        #expect(!second.isUserPaused)
        second.scenePhaseChanged(.active)
        await second.waitForCapture()
        try await expectRecordingAgain(second, h)
        second.stop()
        await second.waitForPipeline()
    }
}
