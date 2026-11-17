import Foundation
import Testing
@testable import RewindCam

/// Issue #11: VoiceOver announcements. The harness's `FakeAccessibilityAnnouncer` records what would have
/// been spoken. Every save result is announced once (the toast's words), and every state change once
/// (`AppModel.announceChanges()`), however many 0.5 s status ticks pass while it lasts. Time is the
/// harness's `FakeDelayScheduler` (`passTime`), so no test sleeps. In the `AppModelTests` suite so it
/// shares its serialization and time limit.
@MainActor
extension AppModelTests {

    private func startedModel(_ h: ModelHarness) async -> AppModel {
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        return model
    }

    @Test("Announcements: recording normally for 30 s says nothing after the start")
    func noAnnouncementStormWhileRecording() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startedModel(h)
        #expect(h.announcer.announcements == [.init(message: "Recording.", priority: .normal)])
        h.announcer.removeAll()
        await passTime(30, model, h, deliver: true)
        #expect(model.phase == .recording)
        #expect(model.readySeconds > 0)
        #expect(h.announcer.announcements.isEmpty, "announced: \(h.announcer.messages)")
        model.stop()
        await model.waitForPipeline()
        #expect(h.announcer.messages == ["Recording stopped."])
    }

    @Test("Announcements: a successful save is announced once, with the toast's words")
    func saveResultIsAnnounced() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startedModel(h)
        h.announcer.removeAll()
        h.source.generate(seconds: 5)
        let task = try #require(model.save())
        h.source.generate(seconds: 2)
        await task.value
        let toast = try #require(model.toast)
        #expect(toast.message.hasPrefix("Saved"))
        #expect(h.announcer.announcements == [.init(message: toast.message, priority: .normal)])
        await passTime(5, model, h, deliver: true)
        #expect(h.announcer.announcements.count == 1, "announced: \(h.announcer.messages)")
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Announcements: a failed save is announced at high priority; the Retry that works is announced too")
    func failedSaveIsAnnounced() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startedModel(h)
        h.announcer.removeAll()
        h.library.failNextSaves(["Simulated Photos failure."])
        h.source.generate(seconds: 5)
        let task = try #require(model.save())
        h.source.generate(seconds: 2)
        await task.value
        #expect(model.unsavedClips.count == 1)
        #expect(h.announcer.announcements == [
            .init(message: "Not added to Photos. The clip is kept in RewindCam — tap Retry.", priority: .high),
        ])

        h.announcer.removeAll()
        let retry = try #require(model.retryUnsavedClips())
        await retry.value
        #expect(model.unsavedClips.isEmpty)
        #expect(h.announcer.announcements == [.init(message: "Saved 1 clip to Photos", priority: .normal)])
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Announcements: Save refused (nothing recorded) says why, at high priority")
    func refusedSaveIsAnnounced() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.source.setStartError(.noCamera)
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        h.announcer.removeAll()
        #expect(model.save(trigger: .volumeButton) == nil)
        let reason = try #require(model.saveUnavailableReason)
        #expect(h.announcer.announcements == [.init(message: "Can't save. \(reason)", priority: .high)])
    }

    @Test("Announcements: an interruption and its end are announced once each, not on every tick")
    func interruptionAndResumeAreAnnounced() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startedModel(h)
        await passTime(2, model, h, deliver: true)
        h.announcer.removeAll()

        h.source.simulate(.interrupted(.cameraInUseByAnotherApp))
        await model.waitForCapture()
        let paused = InterruptionReason.cameraInUseByAnotherApp.message
        #expect(model.phase == .paused(paused))
        #expect(h.announcer.announcements == [.init(message: paused, priority: .normal)])
        await passTime(10, model, h)
        #expect(h.announcer.messages == [paused], "nothing more while it lasts")

        h.source.simulate(.interruptionEnded)
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(h.announcer.messages == [paused, "Recording resumed."])
        await passTime(10, model, h, deliver: true)
        #expect(h.announcer.messages == [paused, "Recording resumed."])
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Announcements: Pause and Resume (issue #15)")
    func userPauseAndResumeAreAnnounced() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startedModel(h)
        h.announcer.removeAll()

        model.pauseCapture()
        await model.waitForCapture()
        #expect(model.phase == .userPaused)
        #expect(h.announcer.messages == ["Paused. The camera is off until you tap Resume."])
        await passTime(10, model, h)
        #expect(h.announcer.messages.count == 1)

        model.resumeCapture()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(h.announcer.messages == ["Paused. The camera is off until you tap Resume.", "Recording resumed."])
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Announcements: camera denied at high priority; a Try Again that fails again says so again")
    func cameraDeniedIsAnnounced() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.source.setStartError(.cameraAccessDenied)
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        #expect(model.phase == .cameraDenied)
        let denied = FakeAccessibilityAnnouncer.Announcement(message: "Not recording: camera access is off.", priority: .high)
        #expect(h.announcer.announcements == [denied])
        h.scheduler.advance(by: 10)
        await model.waitForCapture()
        #expect(h.announcer.announcements == [denied])

        model.retryStart()
        await model.waitForCapture()
        #expect(model.phase == .cameraDenied)
        #expect(h.announcer.announcements == [denied, denied])

        h.source.setStartError(nil)
        model.retryStart()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(h.announcer.messages == [denied.message, denied.message, "Recording."])
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Announcements: microphone denied is said with the start, once")
    func microphoneNoticeIsAnnounced() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.source.setAudioUnavailable(.microphoneDenied)
        let model = await startedModel(h)
        let notice = try #require(model.microphoneNotice)
        #expect(h.announcer.messages == ["Recording. \(notice.title). \(notice.message)"])
        await passTime(10, model, h, deliver: true)
        #expect(h.announcer.messages.count == 1)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Announcements: thermal step-down and recovery, once each")
    func thermalChangesAreAnnounced() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startedModel(h)
        h.announcer.removeAll()

        h.thermal.set(.serious)
        await model.waitForCapture()
        let hot = try #require(model.thermalMessage)
        #expect(hot.contains("720p"))
        #expect(model.phase == .recording)
        #expect(h.announcer.messages == [hot], "the restart behind it is not announced as a stop and start")
        await passTime(5, model, h, deliver: true)
        #expect(h.announcer.messages == [hot])

        h.thermal.set(.nominal)
        await model.waitForCapture()
        #expect(h.announcer.messages == [hot, "The phone has cooled down. Quality is back to 1080p 30 fps."])
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Announcements: low storage once while it lasts, again after it cleared; out of space at high priority")
    func lowDiskIsAnnouncedOnce() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.disk.set(5_000_000_000)
        let model = await startedModel(h)
        await passTime(1, model, h, deliver: true)
        h.announcer.removeAll()

        h.disk.set(150_000_000) // between the reserve and room for buffer + save
        await passTime(30, model, h, deliver: true)
        let warning = try #require(model.diskSpaceNotice)
        #expect(model.phase == .recording)
        #expect(h.announcer.messages == [warning.announcement], "once, not on every free-space check")
        #expect(warning.announcement.hasPrefix("Storage is low."))

        h.disk.set(5_000_000_000)
        await passTime(5.5, model, h, deliver: true)
        #expect(model.diskSpaceNotice == nil)
        h.disk.set(150_000_000)
        await passTime(5.5, model, h, deliver: true)
        #expect(h.announcer.messages == [warning.announcement, warning.announcement])

        h.disk.set(50_000_000) // below the reserve: recording stops
        await passTime(5.5, model, h, deliver: true)
        guard case .outOfSpace = model.phase else {
            Issue.record("expected outOfSpace, got \(model.phase)")
            return
        }
        #expect(h.announcer.announcements.last == .init(message: "Not recording: not enough free space.", priority: .high))
        #expect(h.announcer.announcements.count == 3)
        await passTime(10, model, h)
        #expect(h.announcer.announcements.count == 3)
    }

    @Test("Announcements: a frame stall, and the restart that cured it, once each")
    func stallRestartIsAnnounced() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.updateSettings { $0.bufferSeconds = 15 }
        model.start()
        await model.waitForCapture()
        await passTime(2, model, h, deliver: true)
        h.announcer.removeAll()

        h.source.withholdVideo(true)
        await passTime(5.5, model, h)
        #expect(model.phase == .recording)
        let notice = try #require(model.stallNotice)
        #expect(h.announcer.messages == [
            CaptureRecoveryReason.stalled(.noVideo).pausedMessage,
            "Recording resumed. \(notice.announcement)",
        ])
        #expect(notice.announcement.contains("The camera was restarted"))

        h.source.withholdVideo(false)
        await passTime(10, model, h, deliver: true)
        #expect(h.announcer.messages.count == 2, "announced: \(h.announcer.messages)")
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Announcements: phase wording")
    func phaseWording() {
        #expect(AppModel.phaseAnnouncement(.starting, after: .idle) == nil)
        #expect(AppModel.phaseAnnouncement(.recording, after: .idle) == "Recording.")
        #expect(AppModel.phaseAnnouncement(.recording, after: .paused("x")) == "Recording resumed.")
        #expect(AppModel.phaseAnnouncement(.recording, after: .userPaused) == "Recording resumed.")
        #expect(AppModel.phaseAnnouncement(.idle, after: .recording) == "Recording stopped.")
        #expect(AppModel.phaseAnnouncement(.idle, after: .starting) == nil)
        #expect(AppModel.phaseAnnouncement(.failed("No camera is available."), after: .starting)
                == "Not recording. No camera is available.")
    }
}

