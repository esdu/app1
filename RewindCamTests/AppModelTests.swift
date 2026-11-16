import Foundation
import Testing
@testable import RewindCam

@Suite("App model", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct AppModelTests {

    @Test("Thermal downgrade switches the recorder to the lower preset and tells the user")
    func thermalDowngrade() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()
        #expect(model.phase == .recording)
        #expect(model.activePreset == QualityPreset(resolution: .hd1080, frameRate: .fps30))
        #expect(model.recorder.currentConfiguration.videoBitrate == 10_000_000)
        #expect(model.thermalMessage == nil)

        h.thermal.set(.serious)
        await model.waitForPipeline()
        #expect(model.activePreset == QualityPreset(resolution: .hd720, frameRate: .fps30))
        #expect(model.recorder.currentConfiguration.videoBitrate == 5_000_000)
        #expect(model.thermalMessage?.contains("720p") == true)
        #expect(model.settings.resolution == .hd1080, "the user's own choice is not overwritten")
        #expect(model.phase == .recording)

        h.thermal.set(.critical)
        await model.waitForPipeline()
        #expect(model.activePreset == .lowest)

        h.thermal.set(.nominal)
        await model.waitForPipeline()
        #expect(model.activePreset == QualityPreset(resolution: .hd1080, frameRate: .fps30))
        #expect(model.thermalMessage == nil)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Settings persist across launches")
    func settingsPersist() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let first = h.makeModel()
        first.updateSettings {
            $0.bufferSeconds = 90
            $0.postRollSeconds = 10
            $0.resolution = .hd720
            $0.frameRate = .fps60
            $0.audioEnabled = false
            $0.camera = .front
        }
        let second = h.makeModel()
        #expect(second.settings.bufferSeconds == 90)
        #expect(second.settings.postRollSeconds == 10)
        #expect(second.settings.resolution == .hd720)
        #expect(second.settings.frameRate == .fps60)
        #expect(second.settings.audioEnabled == false)
        #expect(second.settings.camera == .front)
        #expect(second.settings == first.settings)
    }

    @Test("Buffer-length change applies to the running recorder in place")
    func bufferChangeAppliesInPlace() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()
        model.updateSettings { $0.bufferSeconds = 60 }
        await model.waitForPipeline()
        #expect(model.recorder.currentConfiguration.bufferDuration == 60)
        #expect(model.phase == .recording)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Save from the model lands in the (fake) photo library with a toast and haptic")
    func saveThroughModel() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()
        h.source.generate(seconds: 5)
        let task = try #require(model.save())
        h.source.generate(seconds: 2)
        await task.value
        #expect(h.library.clips().count == 1)
        #expect(model.toast?.message.hasPrefix("Saved") == true, "toast: \(String(describing: model.toast))")
        #expect(h.haptics.successes == 1)
        #expect(model.savedClipCount == 1)
        // Temp files are cleaned up after the save.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: h.storage.clipsDirectory.path)) ?? []
        #expect(leftovers.isEmpty, "leftovers: \(leftovers)")
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Backgrounding pauses, clears the buffer and explains why; foreground resumes")
    func backgroundingPausesAndResumes() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.scenePhaseChanged(.active)
        await model.waitForPipeline()
        h.source.generate(seconds: 4)
        model.scenePhaseChanged(.background)
        await model.waitForPipeline()
        guard case .paused(let message) = model.phase else {
            Issue.record("expected paused, got \(model.phase)")
            return
        }
        #expect(message.contains("background"))
        #expect(model.status.bufferedSeconds == 0)
        #expect(h.screen.idleTimerDisabled == false)

        model.scenePhaseChanged(.active)
        await model.waitForPipeline()
        #expect(model.phase == .recording)
        #expect(h.screen.idleTimerDisabled)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Dim mode lowers brightness and restores it on wake")
    func dimMode() {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        h.screen.brightness = 0.7
        model.setDimmed(true)
        #expect(model.isDimmed)
        #expect(h.screen.brightness < 0.1)
        model.setDimmed(false)
        #expect(!model.isDimmed)
        #expect(h.screen.brightness == 0.7)
    }

    @Test("Interruption events from the source pause and resume recording")
    func sourceInterruption() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()
        h.source.generate(seconds: 4)
        h.source.simulate(.interrupted(.cameraInUseByAnotherApp))
        try await waitUntil { model.phase != .recording }
        #expect(model.phase == .paused(InterruptionReason.cameraInUseByAnotherApp.message))
        #expect(model.recorder.status().bufferedSeconds == 0)
        h.source.simulate(.interruptionEnded)
        try await waitUntil { model.phase == .recording }
        model.stop()
        await model.waitForPipeline()
    }

    @Test func modelCleansOrphansWhenStarting() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let gen = h.storage.bufferDirectory.appendingPathComponent("gen-99")
        try FileManager.default.createDirectory(at: gen, withIntermediateDirectories: true)
        try Data(count: 100).write(to: gen.appendingPathComponent("seg-000000.m4s"))
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()
        #expect(model.orphansRemoved == 1)
        #expect(!FileManager.default.fileExists(atPath: gen.path))
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
