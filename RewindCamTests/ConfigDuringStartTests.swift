import Foundation
import Testing
@testable import RewindCam

/// Issue #35: a setting or thermal change made while the camera starts is started too, before anything
/// is published. Starts are held with `SyntheticFrameSource.holdNextStart()` (as in the #15 pause
/// tests); a second hold on the corrective start shows what the model publishes before it. Time is the
/// harness's `FakeDelayScheduler`, so no test sleeps. In the `AppModelTests` suite so it shares its
/// serialization and time limit.
@MainActor
extension AppModelTests {

    /// One kind of change made while a start is held. Starts from the default settings (1080p 30 fps,
    /// back camera, Record sound on, voice trigger off) at a nominal thermal level.
    enum MidStartChange: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case camera, resolution, frameRate, soundOn, soundOff, thermal

        var testDescription: String { rawValue }

        /// Settings before the start, so that the change is a change.
        @MainActor func prepare(_ model: AppModel) {
            if self == .soundOn { model.updateSettings { $0.audioEnabled = false } }
        }

        @MainActor func apply(_ model: AppModel, _ h: ModelHarness) {
            switch self {
            case .camera: model.updateSettings { $0.camera = .front }
            case .resolution: model.updateSettings { $0.resolution = .uhd4K }
            case .frameRate: model.updateSettings { $0.frameRate = .fps60 }
            case .soundOn: model.updateSettings { $0.audioEnabled = true }
            case .soundOff: model.updateSettings { $0.audioEnabled = false }
            case .thermal: h.thermal.set(.serious) // 1080p30 → 720p30
            }
        }

        /// What the camera must end up capturing.
        var expected: CaptureConfiguration {
            let hd = QualityPreset(resolution: .hd1080, frameRate: .fps30)
            return switch self {
            case .camera: CaptureConfiguration(preset: hd, audioEnabled: true, camera: .front)
            case .resolution:
                CaptureConfiguration(preset: QualityPreset(resolution: .uhd4K, frameRate: .fps30),
                                     audioEnabled: true, camera: .back)
            case .frameRate:
                CaptureConfiguration(preset: QualityPreset(resolution: .hd1080, frameRate: .fps60),
                                     audioEnabled: true, camera: .back)
            case .soundOn: CaptureConfiguration(preset: hd, audioEnabled: true, camera: .back)
            case .soundOff: CaptureConfiguration(preset: hd, audioEnabled: false, camera: .back)
            case .thermal: CaptureConfiguration(preset: .lowest, audioEnabled: true, camera: .back)
            }
        }
    }

    /// Recording with `capture`: the source runs with it, the settings still ask for it, and the
    /// recorder is configured for it (preset, and audio only if sound is wanted and captured).
    private func expectRecording(with capture: CaptureConfiguration, _ model: AppModel, _ h: ModelHarness,
                                 audioCaptured: Bool? = nil,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        let captured = audioCaptured ?? capture.audioEnabled
        let recorder = model.recorder.currentConfiguration
        let checks: [(Bool, String)] = [
            (model.phase == .recording, "phase is \(model.phase)"),
            (h.source.runState == .running, "source is \(h.source.runState)"),
            (h.source.runningConfiguration == capture,
             "source runs \(String(describing: h.source.runningConfiguration)), expected \(capture)"),
            (model.captureConfiguration == capture, "settings ask for \(model.captureConfiguration)"),
            (model.activeCapture?.audioCaptured == captured,
             "active capture \(String(describing: model.activeCapture))"),
            (recorder == model.recorderConfiguration, "recorder \(recorder) vs \(model.recorderConfiguration)"),
            (recorder.frameRate == capture.preset.frameRate.rawValue, "recorder frame rate \(recorder.frameRate)"),
            (recorder.videoBitrate == capture.preset.videoBitrate, "recorder bitrate \(recorder.videoBitrate)"),
            (recorder.audioEnabled == (model.settings.audioEnabled && captured),
             "recorder audio \(recorder.audioEnabled)"),
            (!model.recorder.status().isSuspended, "recorder suspended"),
            (h.screen.idleTimerDisabled, "the screen may lock while recording"),
        ]
        for (ok, what) in checks where !ok {
            Issue.record(Comment(rawValue: what), sourceLocation: sourceLocation)
        }
    }

    /// Footage reaches the buffer and nothing restarts the camera over a few status ticks.
    private func expectSettled(_ model: AppModel, _ h: ModelHarness, starts: Int,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await passTime(3, model, h, deliver: true)
        #expect(h.source.startCount == starts, "no further restart", sourceLocation: sourceLocation)
        #expect(model.phase == .recording, sourceLocation: sourceLocation)
        try await waitUntil { model.recorder.status().bufferedSeconds > 0 }
        #expect(model.saveUnavailableReason == nil, sourceLocation: sourceLocation)
    }

    /// Holds the launch start and waits until it is waiting.
    private func modelWithHeldLaunch(_ h: ModelHarness,
                                     prepare: @MainActor (AppModel) -> Void = { _ in }) async -> AppModel {
        let model = h.makeModel()
        prepare(model)
        h.source.holdNextStart()
        model.scenePhaseChanged(.active)
        await h.source.waitForHeldStart()
        #expect(model.phase == .starting)
        return model
    }

    @Test("A change while the camera starts is started before Recording, recorder to match", arguments: MidStartChange.allCases)
    func changeWhileCameraStarts(_ change: MidStartChange) async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await modelWithHeldLaunch(h, prepare: change.prepare)
        let initial = model.captureConfiguration
        change.apply(model, h)
        let newest = model.captureConfiguration
        #expect(newest == change.expected)
        #expect(newest != initial)
        if change == .thermal { #expect(model.thermalMessage != nil, "the banner says quality was lowered") }

        // The launch start returns with the old configuration; the corrective start is held too.
        h.source.holdNextStart()
        h.source.releaseHeldStart()
        await h.source.waitForHeldStart()
        #expect(h.source.startConfigurations == [initial, newest])
        #expect(model.phase == .starting, "not Recording with the configuration from before the change")
        #expect(model.recorder.status().isSuspended, "nothing from the stale session is buffered")
        #expect(model.saveUnavailableReason == "The camera is starting.")
        #expect(!h.announcer.messages.contains(where: { $0.contains("Recording.") }), "VoiceOver wasn't told it records")

        h.source.releaseHeldStart()
        await model.waitForCapture()
        expectRecording(with: newest, model, h)
        #expect(h.source.startCount == 2, "one corrective start")
        if change == .soundOn { #expect(model.recorder.currentConfiguration.audioEnabled, "clips have sound") }
        if change == .soundOff { #expect(model.activeCapture?.audioCaptured == false, "the microphone is released") }
        try await expectSettled(model, h, starts: 2)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Record sound turned on while the camera starts, microphone denied: the notice, never silently silent")
    func soundOnWhileStartingWithMicrophoneDenied() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.source.setAudioUnavailable(.microphoneDenied)
        let model = await modelWithHeldLaunch(h) { model in model.updateSettings { $0.audioEnabled = false } }
        #expect(model.microphoneNotice == nil)
        model.updateSettings { $0.audioEnabled = true }
        h.source.releaseHeldStart()
        await model.waitForCapture()

        let newest = MidStartChange.soundOn.expected
        #expect(h.source.startConfigurations.map(\.audioEnabled) == [false, true], "the microphone was asked for")
        expectRecording(with: newest, model, h, audioCaptured: false)
        #expect(model.activeCapture == ActiveCapture(audioCaptured: false, audioUnavailable: .microphoneDenied))
        #expect(model.recorder.currentConfiguration.audioEnabled == false, "no audio input that is never fed")
        let notice = try #require(model.microphoneNotice)
        #expect(notice.id == "microphoneBanner")
        #expect(notice.title == "Sound is off")
        #expect(notice.action == .openSettings)
        try await expectSettled(model, h, starts: 2)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Several changes while the camera starts: one corrective start with the newest configuration")
    func severalChangesWhileCameraStarts() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await modelWithHeldLaunch(h)
        let initial = model.captureConfiguration
        model.updateSettings { $0.resolution = .uhd4K }
        model.updateSettings { $0.frameRate = .fps60 }
        model.updateSettings { $0.camera = .front }
        let newest = CaptureConfiguration(preset: QualityPreset(resolution: .uhd4K, frameRate: .fps60),
                                         audioEnabled: true, camera: .front)
        #expect(model.captureConfiguration == newest)
        h.source.releaseHeldStart()
        await model.waitForCapture()
        #expect(h.source.startConfigurations == [initial, newest], "not one restart per change")
        expectRecording(with: newest, model, h)
        try await expectSettled(model, h, starts: 2)

        // Changed and changed back while starting: nothing to correct.
        model.stop()
        await model.waitForPipeline()
        h.source.holdNextStart()
        model.start()
        await h.source.waitForHeldStart()
        model.updateSettings { $0.frameRate = .fps30 }
        model.updateSettings { $0.frameRate = .fps60 }
        h.source.releaseHeldStart()
        await model.waitForCapture()
        #expect(h.source.startCount == 3)
        expectRecording(with: newest, model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("A change during each corrective start: settles on the newest, one start per change, no loop")
    func changesDuringCorrectiveStarts() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await modelWithHeldLaunch(h)
        let a = model.captureConfiguration
        model.updateSettings { $0.resolution = .uhd4K }
        let b = model.captureConfiguration
        h.source.holdNextStart()
        h.source.releaseHeldStart()
        await h.source.waitForHeldStart() // starting with b
        h.thermal.set(.serious) // 4K30 → 1080p30
        let c = model.captureConfiguration
        h.source.holdNextStart()
        h.source.releaseHeldStart()
        await h.source.waitForHeldStart() // starting with c
        model.updateSettings { $0.audioEnabled = false }
        let d = model.captureConfiguration
        #expect(model.phase == .starting)
        h.source.releaseHeldStart()
        await model.waitForCapture()
        #expect(h.source.startConfigurations == [a, b, c, d])
        #expect(d.preset == QualityPreset(resolution: .hd1080, frameRate: .fps30) && !d.audioEnabled)
        expectRecording(with: d, model, h)
        try await expectSettled(model, h, starts: 4)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Two changes in quick succession while recording (the issue's sequence): the second lands in the first's restart")
    func secondChangeDuringReconfigureRestart() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        #expect(model.phase == .recording)

        h.source.holdNextStart()
        model.updateSettings { $0.resolution = .uhd4K } // restarts the camera
        await h.source.waitForHeldStart()
        #expect(h.source.startConfigurations.last?.preset == QualityPreset(resolution: .uhd4K, frameRate: .fps30))
        model.updateSettings { $0.frameRate = .fps60 } // lands while that restart starts
        h.source.releaseHeldStart()
        await model.waitForCapture()
        let newest = CaptureConfiguration(preset: QualityPreset(resolution: .uhd4K, frameRate: .fps60),
                                         audioEnabled: true, camera: .back)
        expectRecording(with: newest, model, h)
        #expect(h.source.startCount == 3, "launch, the 4K restart, one corrective start")
        try await expectSettled(model, h, starts: 3)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("A change while the camera starts, then Pause: Pause wins; Resume starts the newest configuration")
    func changeThenPauseWhileStarting() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }

        // Paused while the launch start (old configuration) is still waiting.
        let model = await modelWithHeldLaunch(h)
        let initial = model.captureConfiguration
        model.updateSettings { $0.camera = .front }
        let newest = model.captureConfiguration
        model.pauseCapture()
        h.source.releaseHeldStart()
        await model.waitForCapture()
        #expect(h.source.startConfigurations == [initial], "no corrective start for a start the user paused")
        expectPausedWithNothingRunning(model, h)
        await passTime(10, model, h)
        #expect(h.source.startCount == 1)
        expectPausedWithNothingRunning(model, h)

        model.resumeCapture()
        await model.waitForCapture()
        expectRecording(with: newest, model, h)
        try await expectSettled(model, h, starts: 2)

        // Paused while the corrective start is waiting.
        model.stop()
        await model.waitForPipeline()
        model.updateSettings { $0.camera = .back }
        let second = model.captureConfiguration
        h.source.holdNextStart()
        model.start()
        await h.source.waitForHeldStart()
        model.updateSettings { $0.frameRate = .fps60 }
        let third = model.captureConfiguration
        h.source.holdNextStart()
        h.source.releaseHeldStart()
        await h.source.waitForHeldStart()
        #expect(Array(h.source.startConfigurations.suffix(2)) == [second, third])
        model.pauseCapture()
        h.source.releaseHeldStart()
        await model.waitForCapture()
        #expect(h.source.startCount == 4)
        expectPausedWithNothingRunning(model, h)
        await passTime(10, model, h)
        #expect(h.source.startCount == 4, "nothing restarts while paused")

        model.resumeCapture()
        await model.waitForCapture()
        expectRecording(with: third, model, h)
        try await expectSettled(model, h, starts: 5)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("A change while the camera starts, then background: nothing records; foreground starts the newest configuration")
    func changeThenBackgroundWhileStarting() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await modelWithHeldLaunch(h)
        model.updateSettings { $0.resolution = .hd720 }
        let newest = model.captureConfiguration
        h.source.holdNextStart()
        h.source.releaseHeldStart()
        await h.source.waitForHeldStart() // the corrective start
        model.scenePhaseChanged(.background)
        h.source.releaseHeldStart()
        await model.waitForCapture()
        #expect(model.phase == .paused(InterruptionReason.backgrounded.message))
        #expect(h.source.runState == .stopped)
        #expect(h.source.runningConfiguration == nil)
        #expect(model.recorder.status().isSuspended)
        #expect(!h.screen.idleTimerDisabled)
        #expect(h.source.startCount == 2)

        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        expectRecording(with: newest, model, h)
        try await expectSettled(model, h, starts: 3)
        model.stop()
        await model.waitForPipeline()
    }

    /// The user paused and nothing that a start began is left running.
    private func expectPausedWithNothingRunning(_ model: AppModel, _ h: ModelHarness,
                                                sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(model.phase == .userPaused, sourceLocation: sourceLocation)
        #expect(h.source.runState == .stopped, sourceLocation: sourceLocation)
        #expect(h.source.runningConfiguration == nil, sourceLocation: sourceLocation)
        #expect(model.activeCapture == nil, sourceLocation: sourceLocation)
        #expect(model.recorder.status().isSuspended, sourceLocation: sourceLocation)
        #expect(!h.screen.idleTimerDisabled, sourceLocation: sourceLocation)
        #expect(model.startFailureNotice == nil, sourceLocation: sourceLocation)
    }

    @Test("A change during the frame watchdog's restart is started by that restart; the stall notice stays")
    func changeDuringStallRestart() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        let initial = model.captureConfiguration
        await passTime(2, model, h, deliver: true)
        #expect(model.frameWatchdog.isArmed)
        h.source.withholdVideo(true)
        await passTime(4.5, model, h)
        let starts = h.source.startCount
        h.source.holdNextStart()
        h.scheduler.advance(by: AppModel.statusInterval)
        #expect(model.recovery?.reason == .stalled(.noVideo))
        await h.source.waitForHeldStart() // the watchdog's restart: stopped, now starting

        h.thermal.set(.serious) // 1080p30 → 720p30 while it starts
        let newest = model.captureConfiguration
        #expect(newest.preset == .lowest)
        h.source.withholdVideo(false)
        h.source.holdNextStart()
        h.source.releaseHeldStart()
        await h.source.waitForHeldStart()
        #expect(Array(h.source.startConfigurations.suffix(2)) == [initial, newest])
        #expect(model.phase == .paused(CaptureRecoveryReason.stalled(.noVideo).pausedMessage),
                "not Recording with the configuration from before the change")
        h.source.releaseHeldStart()
        await model.waitForCapture()

        expectRecording(with: newest, model, h)
        #expect(h.source.startCount == starts + 2, "the restart started the newest configuration; nothing else queued")
        #expect(model.recovery == nil)
        #expect(model.stallNotice?.id == "stallBanner", "the same recovery brought recording back")
        #expect(model.thermalMessage != nil)
        // The watchdog arms again on a later tick, with the full timeout.
        try await expectSettled(model, h, starts: starts + 2)
        #expect(model.frameWatchdog.isArmed)
        model.stop()
        await model.waitForPipeline()
    }

    /// Changes that make the buffer not fit in free space that was enough for the defaults.
    enum GrowingChange: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case quality, bufferLength
        var testDescription: String { rawValue }
        @MainActor func apply(_ model: AppModel) {
            switch self {
            case .quality: model.updateSettings { $0.resolution = .uhd4K; $0.frameRate = .fps60 }
            case .bufferLength: model.updateSettings { $0.bufferSeconds = 120 }
            }
        }
    }

    @Test("A change while the camera starts that doesn't fit in free space: the out-of-space notice, not Recording",
          arguments: GrowingChange.allCases)
    func changeWhileStartingThatDoesNotFit(_ change: GrowingChange) async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        // Room for the defaults' buffer and a save, not for more.
        let fits = model.diskPolicy.requiredBytesToBufferAndSave
        h.disk.set(fits)
        h.source.holdNextStart()
        model.scenePhaseChanged(.active)
        await h.source.waitForHeldStart()
        change.apply(model)
        #expect(model.diskPolicy.requiredBytesToBuffer > fits)
        h.source.releaseHeldStart()
        await model.waitForCapture()

        guard case .outOfSpace(let check) = model.phase else {
            Issue.record(Comment(rawValue: "phase is \(model.phase)"))
            return
        }
        #expect(check.level == .tooLow)
        #expect(model.startFailureNotice?.id == "lowDiskBanner")
        #expect(h.source.startCount == 1, "never started with settings that don't fit")
        #expect(h.source.runState == .stopped)
        #expect(model.activeCapture == nil)
        #expect(!h.screen.idleTimerDisabled)

        // Room again: Try Again records with the new settings.
        h.disk.set(nil)
        model.retryStart()
        await model.waitForCapture()
        expectRecording(with: model.captureConfiguration, model, h)
        #expect(model.recorder.currentConfiguration.bufferDuration == Double(model.settings.bufferSeconds))
        model.stop()
        await model.waitForPipeline()
    }
}
