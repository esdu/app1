import Foundation
import Testing
@testable import RewindCam

/// Camera denied and other start failures (issue #8): the user is told why and given a way out
/// (Open Settings, Try Again), Save is disabled, and returning to the foreground re-checks. In the
/// `AppModelTests` suite so it shares its serialization and time limit.
@MainActor
extension AppModelTests {

    /// Records `seconds`, saves, and lets the save finish (export + fake Photos).
    private func recordThenSave(_ model: AppModel, _ h: ModelHarness, seconds: Double = 5) async throws {
        h.source.generate(seconds: seconds)
        let task = try #require(model.save())
        h.source.generate(seconds: 2)
        await task.value
    }

    @Test("Camera denied: an Open Settings notice, nothing recording, Save refused with a reason")
    func cameraDeniedShowsNoticeAndRefusesSave() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.source.setStartError(.cameraAccessDenied)
        let model = h.makeModel()
        #expect(model.startFailureNotice == nil, "nothing to report before the first start")
        model.scenePhaseChanged(.active)
        await model.waitForPipeline()

        #expect(model.phase == .cameraDenied)
        #expect(model.phase.isStartFailure)
        #expect(model.activeCapture == nil)
        #expect(h.screen.idleTimerDisabled == false, "the screen may lock: nothing is being recorded")
        #expect(model.microphoneNotice == nil, "no second notice about the microphone")
        #expect(!model.isVoiceListening)
        let notice = try #require(model.startFailureNotice)
        #expect(notice.id == "cameraDeniedBanner")
        #expect(notice.title == "Camera access is off")
        #expect(notice.message.contains("needs the camera"), "message: \(notice.message)")
        #expect(notice.message.contains("Settings › RewindCam › Camera"), "message: \(notice.message)")
        #expect(notice.severity == .error)
        #expect(notice.action == .openSettings)
        #expect(model.status.bufferedSeconds == 0)
        #expect(model.photosAccessGranted == nil, "Photos isn't asked before the camera runs")

        // Save is disabled in the UI; a save from the volume buttons says why and does nothing else.
        let reason = try #require(model.saveUnavailableReason)
        #expect(reason.contains("Camera access is off"))
        #expect(model.save() == nil)
        #expect(!model.isSaving)
        #expect(model.toast?.isError == true)
        #expect(model.toast?.message == "Can't save. \(reason)", "toast: \(String(describing: model.toast))")
        #expect(h.haptics.failures == 1)
        #expect(h.backgroundTasks.begun == 0, "no save was started")
        #expect(h.library.clips().isEmpty)
        #expect(model.unsavedClips.isEmpty)

        // The notice's button.
        model.openAppSettings()
        #expect(h.appSettings.openCount == 1)

        // Settings still work while denied, and don't start capture on their own.
        let starts = h.source.startCount
        model.updateSettings { $0.bufferSeconds = 60 }
        await model.waitForPipeline()
        #expect(model.settings.bufferSeconds == 60)
        #expect(model.phase == .cameraDenied)
        #expect(h.source.startCount == starts)

        // Back in the foreground but still denied: checked again, same notice.
        model.scenePhaseChanged(.active)
        await model.waitForPipeline()
        #expect(h.source.startCount == starts + 1)
        #expect(model.phase == .cameraDenied)

        model.stop()
        await model.waitForPipeline()
    }

    @Test("Camera allowed in Settings: returning to the foreground starts recording (with and without a background trip)")
    func cameraAllowedThenForegroundStartsRecording() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.source.setStartError(.cameraAccessDenied)
        let model = h.makeModel()
        model.scenePhaseChanged(.active)
        await model.waitForPipeline()
        #expect(model.phase == .cameraDenied)

        // `.active` without `.background` in between (e.g. a permission prompt was just answered):
        // the failed start is retried explicitly.
        h.source.setStartError(nil)
        model.scenePhaseChanged(.active)
        await model.waitForPipeline()
        #expect(model.phase == .recording)
        #expect(model.startFailureNotice == nil)
        #expect(model.saveUnavailableReason == nil)
        #expect(h.screen.idleTimerDisabled)
        try await recordThenSave(model, h)
        #expect(h.library.clips().count == 1)
        #expect(model.toast?.message.hasPrefix("Saved") == true, "toast: \(String(describing: model.toast))")

        // Denied again (the user turned it off), then the usual trip: Open Settings backgrounds the
        // app, the user allows the camera, and the app comes back.
        h.source.setStartError(.cameraAccessDenied)
        model.scenePhaseChanged(.background)
        await model.waitForPipeline()
        model.scenePhaseChanged(.active)
        await model.waitForPipeline()
        #expect(model.phase == .cameraDenied)
        model.openAppSettings()
        model.scenePhaseChanged(.inactive)
        model.scenePhaseChanged(.background)
        await model.waitForPipeline()
        #expect(model.startFailureNotice == nil, "paused while in the background")
        h.source.setStartError(nil)
        model.scenePhaseChanged(.active)
        await model.waitForPipeline()
        #expect(model.phase == .recording)
        #expect(model.startFailureNotice == nil)
        try await recordThenSave(model, h)
        #expect(h.library.clips().count == 2)

        // While recording, `.active` doesn't restart capture.
        let starts = h.source.startCount
        model.scenePhaseChanged(.active)
        await model.waitForPipeline()
        #expect(h.source.startCount == starts)

        model.stop()
        await model.waitForPipeline()
    }

    @Test("Other start failures offer Try Again, which re-runs the start pipeline once per tap")
    func otherStartFailuresOfferTryAgain() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.source.setStartError(.configurationFailed("simulated"))
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()

        #expect(model.phase == .failed("Couldn't start the camera: simulated"))
        let notice = try #require(model.startFailureNotice)
        #expect(notice.id == "errorBanner")
        #expect(notice.message == "Couldn't start the camera: simulated")
        #expect(notice.severity == .error)
        #expect(notice.action == .tryAgain)
        #expect(model.saveUnavailableReason != nil)
        #expect(model.save() == nil)
        #expect(!h.screen.idleTimerDisabled)

        // Still failing: a double tap makes one attempt, and the notice comes back.
        var starts = h.source.startCount
        h.source.setStartError(.noCamera)
        model.retryStart()
        #expect(model.phase == .starting, "the notice goes away while trying")
        #expect(model.startFailureNotice == nil)
        model.retryStart()
        await model.waitForPipeline()
        #expect(h.source.startCount == starts + 1)
        #expect(model.phase == .failed("No camera is available on this device."))
        #expect(model.startFailureNotice?.action == .tryAgain)

        // Fixed: Try Again starts recording.
        starts = h.source.startCount
        h.source.setStartError(nil)
        model.retryStart()
        await model.waitForPipeline()
        #expect(h.source.startCount == starts + 1)
        #expect(model.phase == .recording)
        #expect(model.startFailureNotice == nil)
        #expect(h.screen.idleTimerDisabled)

        // Try Again does nothing unless a start failed.
        model.retryStart()
        await model.waitForPipeline()
        #expect(h.source.startCount == starts + 1)
        #expect(model.phase == .recording)

        model.stop()
        await model.waitForPipeline()
    }

    @Test("A restart that fails (camera switch) stops capture and lets the screen lock; foreground retries it")
    func failedRestartStopsCaptureAndForegroundRetries() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()
        #expect(model.phase == .recording)
        #expect(h.screen.idleTimerDisabled)
        h.source.generate(seconds: 3)

        h.source.setStartError(.configurationFailed("front camera busy"))
        model.updateSettings { $0.camera = .front }
        await model.waitForPipeline()
        #expect(model.phase == .failed("Couldn't start the camera: front camera busy"))
        #expect(model.activeCapture == nil)
        #expect(!h.screen.idleTimerDisabled)
        #expect(model.recorder.status().bufferedSeconds == 0)
        #expect(model.startFailureNotice?.action == .tryAgain)

        h.source.setStartError(nil)
        model.scenePhaseChanged(.active)
        await model.waitForPipeline()
        #expect(model.phase == .recording)
        #expect(h.screen.idleTimerDisabled)

        model.stop()
        await model.waitForPipeline()
    }

    @Test("Camera denied after a relaunch: clips that didn't reach Photos can still be retried")
    func unsavedClipsRetryWhileCameraDenied() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.library.failNextSaves(["Simulated failure."])
        let first = h.makeModel()
        first.start()
        await first.waitForPipeline()
        try await recordThenSave(first, h)
        let kept = try #require(first.unsavedClips.first)
        first.stop()
        await first.waitForPipeline()

        h.source.setStartError(.cameraAccessDenied)
        let second = h.makeModel()
        second.scenePhaseChanged(.active)
        await second.waitForPipeline()
        #expect(second.phase == .cameraDenied)
        #expect(second.unsavedClips.map(\.name) == [kept.name], "launch cleanup still ran")

        let retry = try #require(second.retryUnsavedClips())
        await retry.value
        #expect(h.library.clips().count == 1)
        #expect(second.unsavedClips.isEmpty)
        #expect(second.phase == .cameraDenied)

        second.stop()
        await second.waitForPipeline()
    }
}
