import AVFoundation
import Foundation
import Testing
@testable import RewindCam

/// Microphone denied or unusable (issue #3): the recorder follows what the source captures, the user
/// is told, and saves keep working. In the `AppModelTests` suite so it shares its serialization and
/// time limit.
@MainActor
extension AppModelTests {

    /// Records `seconds`, saves, and lets the save finish (export + fake Photos).
    private func recordAndSaveClip(_ model: AppModel, _ h: ModelHarness, seconds: Double = 5) async throws {
        h.source.generate(seconds: seconds)
        let task = try #require(model.save())
        h.source.generate(seconds: 2)
        await task.value
    }

    @Test("Microphone denied with Record sound on: video-only writer, a notice with Open Settings, playable clips")
    func microphoneDeniedRecordsVideoOnly() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.source.setAudioUnavailable(.microphoneDenied)
        let model = h.makeModel()
        #expect(model.settings.audioEnabled, "Record sound is on by default")
        #expect(model.microphoneNotice == nil, "nothing to report before capture starts")
        model.start()
        await model.waitForPipeline()

        #expect(model.phase == .recording)
        #expect(model.captureConfiguration.audioEnabled, "sound was asked for")
        #expect(model.activeCapture == ActiveCapture(audioCaptured: false, audioUnavailable: .microphoneDenied))
        #expect(model.recorder.currentConfiguration.audioEnabled == false, "no audio input that would never be fed")
        #expect(model.settings.audioEnabled, "the user's setting is not silently changed")
        let notice = try #require(model.microphoneNotice)
        #expect(notice.id == "microphoneBanner")
        #expect(notice.title == "Sound is off")
        #expect(notice.message.contains("Microphone access is denied"), "message: \(notice.message)")
        #expect(notice.message.contains("without sound"))
        #expect(notice.severity == .warning)
        #expect(notice.action == .openSettings)

        // The buffer fills: segments keep coming without audio (a writer with an unfed audio input stalls).
        h.source.generate(seconds: 5)
        try await waitUntil(timeout: 30) { model.recorder.status().bufferedSeconds >= 2 }

        let save = try #require(model.save())
        h.source.generate(seconds: 2)
        await save.value
        #expect(model.toast?.message.hasPrefix("Saved") == true, "toast: \(String(describing: model.toast))")
        let clip = try #require(h.library.clips().first)
        let info = try await inspectClip(clip)
        #expect(info.duration > 3, "duration \(info.duration)")
        expectHealthyClip(info, frameRate: 15, audio: false)

        // What the banner's button does.
        #expect(h.appSettings.openCount == 0)
        model.openAppSettings()
        #expect(h.appSettings.openCount == 1)

        // The user allows the microphone in Settings and returns: sound is recorded again.
        h.source.setAudioUnavailable(nil)
        model.scenePhaseChanged(.background)
        await model.waitForPipeline()
        #expect(model.activeCapture == nil)
        #expect(model.microphoneNotice == nil)
        model.scenePhaseChanged(.active)
        await model.waitForPipeline()
        #expect(model.phase == .recording)
        #expect(model.activeCapture == ActiveCapture(audioCaptured: true, audioUnavailable: nil))
        #expect(model.recorder.currentConfiguration.audioEnabled)
        #expect(model.microphoneNotice == nil)

        try await recordAndSaveClip(model, h)
        let clips = h.library.clips()
        #expect(clips.count == 2)
        var withSound = 0
        for url in clips {
            let clipInfo = try await inspectClip(url)
            #expect(clipInfo.isPlayable && clipInfo.readerCompleted)
            if clipInfo.hasAudio { withSound += 1 }
        }
        #expect(withSound == 1, "only the clip recorded after access was allowed has sound")

        model.stop()
        await model.waitForPipeline()
    }

    @Test("Voice trigger with the microphone denied reports it can't listen; settings stay as chosen")
    func voiceTriggerWithMicrophoneDenied() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.source.setAudioUnavailable(.microphoneDenied)
        let model = h.makeModel()
        model.updateSettings {
            $0.audioEnabled = false
            $0.voiceTriggerEnabled = true
        }
        model.start()
        await model.waitForPipeline()

        #expect(model.phase == .recording)
        #expect(model.captureConfiguration.audioEnabled, "the voice trigger asks for the microphone")
        #expect(model.activeCapture?.audioUnavailable == .microphoneDenied)
        #expect(!model.isVoiceListening)
        #expect(!h.voice.isRunning)
        #expect(model.voiceListeningLabel == "No — microphone access is denied")
        let notice = try #require(model.microphoneNotice)
        #expect(notice.title == "The voice trigger can't listen")
        #expect(!notice.message.contains("without sound"), "sound is off by choice: \(notice.message)")
        #expect(notice.action == .openSettings)
        #expect(model.settings.voiceTriggerEnabled, "the setting is not silently changed")
        #expect(model.recorder.currentConfiguration.audioEnabled == false)

        // Turning sound on as well: one notice naming both; the writer still gets no audio input.
        model.updateSettings { $0.audioEnabled = true }
        await model.waitForPipeline()
        #expect(model.phase == .recording)
        #expect(model.microphoneNotice?.title == "Sound and the voice trigger are off")
        #expect(model.recorder.currentConfiguration.audioEnabled == false)
        h.source.generate(seconds: 4)
        try await waitUntil(timeout: 30) { model.recorder.status().bufferedSeconds >= 1 }

        // Allowed in Settings, capture restarts: the trigger listens and sound is recorded.
        h.source.setAudioUnavailable(nil)
        model.stop()
        await model.waitForPipeline()
        model.start()
        await model.waitForPipeline()
        try await waitUntil { h.voice.isRunning }
        #expect(model.isVoiceListening)
        #expect(model.voiceListeningLabel == "Yes")
        #expect(model.microphoneNotice == nil)
        #expect(model.recorder.currentConfiguration.audioEnabled)
        h.source.generate(seconds: 1)
        #expect(h.voice.audioSamplesSeen > 0)

        model.stop()
        await model.waitForPipeline()
    }

    @Test("Sound and voice trigger off: the microphone isn't requested, so a denial shows nothing")
    func microphoneDeniedButNotWanted() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.source.setAudioUnavailable(.microphoneDenied)
        let model = h.makeModel()
        model.updateSettings { $0.audioEnabled = false }
        model.start()
        await model.waitForPipeline()
        #expect(model.phase == .recording)
        #expect(!model.captureConfiguration.audioEnabled)
        #expect(model.activeCapture == ActiveCapture(audioCaptured: false, audioUnavailable: nil))
        #expect(model.microphoneNotice == nil)
        #expect(model.recorder.currentConfiguration.audioEnabled == false)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Microphone allowed: the recorder writes audio because the source captures it")
    func recorderAudioFollowsSource() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        #expect(model.recorder.currentConfiguration.audioEnabled == false, "no audio before the source starts")
        model.start()
        await model.waitForPipeline()
        #expect(model.activeCapture == ActiveCapture(audioCaptured: true, audioUnavailable: nil))
        #expect(model.recorder.currentConfiguration.audioEnabled)
        #expect(model.microphoneNotice == nil)
        try await recordAndSaveClip(model, h)
        let clip = try #require(h.library.clips().first)
        let info = try await inspectClip(clip)
        expectHealthyClip(info, frameRate: 15, audio: true)
        model.stop()
        await model.waitForPipeline()
    }
}

/// The `FrameSource.start` contract, on the synthetic source: it reports what it captures and
/// delivers exactly that.
@Suite("Frame source start contract")
struct FrameSourceContractTests {
    final class CountingSink: SampleSink, @unchecked Sendable {
        // @unchecked: counts are behind a lock.
        private let counts = Locked((video: 0, audio: 0))
        var video: Int { counts.current.video }
        var audio: Int { counts.current.audio }
        func reset() { counts.withLock { $0 = (0, 0) } }
        func consume(_ sampleBuffer: CMSampleBuffer, kind: MediaKind) {
            counts.withLock { c in
                if kind == .video { c.video += 1 } else { c.audio += 1 }
            }
        }
    }

    @Test("start reports whether audio is captured, and why not; no audio samples when it isn't")
    func reportsWhatItCaptures() async throws {
        let source = SyntheticFrameSource(format: .init(width: 64, height: 64, frameRate: 15, audioEnabled: true),
                                          mode: .manual)
        let sink = CountingSink()
        source.setSink(sink)
        var configuration = CaptureConfiguration(preset: .lowest, audioEnabled: true, camera: .back)

        let allowed = try await source.start(configuration)
        #expect(allowed == ActiveCapture(audioCaptured: true, audioUnavailable: nil))
        source.generate(seconds: 1)
        #expect(sink.video > 0)
        #expect(sink.audio > 0)

        source.setAudioUnavailable(.microphoneDenied)
        await source.stop()
        sink.reset()
        let denied = try await source.start(configuration)
        #expect(denied == ActiveCapture(audioCaptured: false, audioUnavailable: .microphoneDenied))
        source.generate(seconds: 1)
        #expect(sink.video > 0)
        #expect(sink.audio == 0)

        source.setAudioUnavailable(.microphoneUnavailable("unplugged"))
        await source.stop()
        let broken = try await source.start(configuration)
        #expect(broken == ActiveCapture(audioCaptured: false, audioUnavailable: .microphoneUnavailable("unplugged")))

        // Not asked for: not captured, and nothing to report even though the mic is unusable.
        configuration.audioEnabled = false
        await source.stop()
        sink.reset()
        let notRequested = try await source.start(configuration)
        #expect(notRequested == ActiveCapture(audioCaptured: false, audioUnavailable: nil))
        source.generate(seconds: 1)
        #expect(sink.audio == 0)
        await source.stop()
    }
}
