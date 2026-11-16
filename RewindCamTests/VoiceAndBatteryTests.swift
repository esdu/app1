import Foundation
import Testing
@testable import RewindCam

@Suite("Voice phrase matching")
struct VoicePhraseTests {
    @Test(arguments: ["Save that", "save that!", "OK, SAVE THAT now", "please save this", "  Save   that. "])
    func matches(_ text: String) {
        #expect(VoicePhrase.matches(text))
    }

    @Test(arguments: ["save the date", "savethat", "that save", "safe that", "", "saved that"])
    func doesNotMatch(_ text: String) {
        #expect(!VoicePhrase.matches(text))
    }
}

@Suite("Battery drain meter")
struct BatteryDrainMeterTests {
    @Test func reportsPercentPerHourAfterTenMinutes() {
        let clock = FakeWallClock()
        var meter = BatteryDrainMeter()
        meter.reset(configuration: "1080p 30 fps, voice off")
        meter.record(level: 0.90, isCharging: false, at: clock.now())
        clock.advance(by: 5 * 60)
        meter.record(level: 0.89, isCharging: false, at: clock.now())
        #expect(meter.percentPerHour == nil, "too early to report")
        clock.advance(by: 25 * 60)
        meter.record(level: 0.85, isCharging: false, at: clock.now())
        let rate = meter.percentPerHour ?? -1
        #expect(abs(rate - 10) < 0.01, "5 points in 30 min = 10 %/h")
        #expect(meter.summary.contains("10.0 %/h"))
    }

    @Test func chargingRestartsTheMeasurement() {
        let clock = FakeWallClock()
        var meter = BatteryDrainMeter()
        meter.record(level: 0.5, isCharging: false, at: clock.now())
        clock.advance(by: 3600)
        meter.record(level: 0.6, isCharging: true, at: clock.now())
        #expect(meter.start == nil)
        clock.advance(by: 60)
        meter.record(level: 0.6, isCharging: false, at: clock.now())
        #expect(meter.elapsed == 0)
    }
}

@Suite("Voice trigger in the app", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct VoiceTriggerModelTests {
    @Test("Enabling the voice trigger taps capture audio; hearing the phrase saves a clip")
    func voiceTriggerSaves() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.updateSettings { $0.audioEnabled = false }
        model.start()
        await model.waitForPipeline()
        #expect(!model.captureConfiguration.audioEnabled)

        model.updateSettings { $0.voiceTriggerEnabled = true }
        await model.waitForPipeline()
        try await waitUntil { h.voice.isRunning }
        #expect(model.isVoiceListening)
        // The microphone is captured for recognition even though clips have no sound.
        #expect(model.captureConfiguration.audioEnabled)
        #expect(model.recorder.currentConfiguration.audioEnabled == false)

        h.source.generate(seconds: 5)
        #expect(h.voice.audioSamplesSeen > 0)

        h.voice.hear()
        try await waitUntil { model.isSaving }
        h.source.generate(seconds: 2)
        try await waitUntil(timeout: 30) { !model.isSaving }
        #expect(h.library.clips().count == 1)

        model.updateSettings { $0.voiceTriggerEnabled = false }
        #expect(!h.voice.isRunning)
        #expect(!model.isVoiceListening)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Battery drain is measured while recording, against the injected clock")
    func batteryDrainWhileRecording() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()
        h.battery.level = 0.80
        model.refreshStatus()
        h.clock.advance(by: 3600)
        h.battery.level = 0.72
        model.refreshStatus()
        let rate = try #require(model.batteryDrain.percentPerHour)
        #expect(abs(rate - 8) < 0.01)
        model.stop()
        await model.waitForPipeline()
    }

    private func waitUntil(timeout: Double = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw TimeoutError(description: "condition not met") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
