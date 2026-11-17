import Foundation
import Testing
@testable import RewindCam

/// Issue #9: the frame watchdog. Pure policy tests for `FrameWatchdog`, recorder tests for settling a
/// pending post-roll, and model tests driven by the harness's `FakeDelayScheduler` (which is also the
/// model's monotonic clock), so "5 s without video" passes without sleeping.
@Suite("Frame watchdog policy")
struct FrameWatchdogPolicyTests {

    private func status(_ generation: Int, video: Double?, segment: Double?) -> RecorderStatus {
        var s = RecorderStatus()
        s.generation = generation
        s.latestMediaTime = video
        s.lastSegmentEnd = segment
        return s
    }

    @Test("Advancing video and segments never stall")
    func progressNeverStalls() {
        var dog = FrameWatchdog()
        dog.arm(at: 0, status: status(1, video: 10, segment: 9))
        var t = 0.0
        while t < 120 {
            t += 0.5
            #expect(dog.observe(status(1, video: 10 + t, segment: 9 + t.rounded(.down)), at: t) == nil)
        }
        #expect(dog.isArmed)
    }

    @Test("Frozen video: nothing at 4.9 s, a stall at 5 s, reported once")
    func frozenVideoStallsAtTimeout() {
        var dog = FrameWatchdog()
        dog.arm(at: 100, status: status(1, video: 10, segment: 9))
        let frozen = status(1, video: 10, segment: 9)
        #expect(dog.observe(frozen, at: 102) == nil)
        #expect(dog.observe(frozen, at: 104.9) == nil)
        #expect(dog.observe(frozen, at: 105) == .noVideo)
        #expect(!dog.isArmed, "disarms itself: one report per arming")
        #expect(dog.observe(frozen, at: 106) == nil)
        #expect(dog.observe(frozen, at: 200) == nil)
    }

    @Test("The timeout counts from the last new frame, not from arming")
    func timeoutCountsFromLastProgress() {
        var dog = FrameWatchdog()
        dog.arm(at: 0, status: status(1, video: 10, segment: 9))
        #expect(dog.observe(status(1, video: 13, segment: 12), at: 3) == nil)
        #expect(dog.observe(status(1, video: 13, segment: 12), at: 7.9) == nil)
        #expect(dog.observe(status(1, video: 13, segment: 12), at: 8) == .noVideo)
    }

    @Test("No video yet (nil media time) after arming: the grace period is the full timeout")
    func nilMediaTimeDuringGrace() {
        var dog = FrameWatchdog()
        dog.arm(at: 0, status: status(0, video: nil, segment: nil))
        #expect(dog.observe(status(0, video: nil, segment: nil), at: 4.9) == nil)
        #expect(dog.observe(status(0, video: nil, segment: nil), at: 5) == .noVideo)

        // A writer that appears and gets frames in time is progress.
        dog.arm(at: 10, status: status(0, video: nil, segment: nil))
        #expect(dog.observe(status(3, video: nil, segment: nil), at: 11) == nil, "a new writer, no frame yet")
        #expect(dog.observe(status(3, video: 20, segment: nil), at: 12) == nil)
        #expect(dog.observe(status(3, video: 21, segment: 20.5), at: 14) == nil)
        #expect(dog.observe(status(3, video: 25, segment: 24), at: 16.9) == nil)
        #expect(dog.observe(status(3, video: 25, segment: 24), at: 21.9) == .noVideo)
    }

    @Test("Audio can't mask it: only the video time counts, so frozen video stalls even with segments")
    func segmentsWithoutVideoStillStall() {
        // A writer can still emit segments (audio, or a last flush) while no new video frame arrives.
        var dog = FrameWatchdog()
        dog.arm(at: 0, status: status(1, video: 10, segment: 9))
        var t = 0.0
        var result: FrameWatchdog.Stall?
        while result == nil, t < 10 {
            t += 0.5
            result = dog.observe(status(1, video: 10, segment: 9 + t), at: t)
        }
        #expect(result == .noVideo)
        #expect(t == 5)
    }

    @Test("Video arrives but no segment for 5 s: a writer stall")
    func writerStall() {
        var dog = FrameWatchdog()
        dog.arm(at: 0, status: status(1, video: 10, segment: 9))
        #expect(dog.observe(status(1, video: 12, segment: 9), at: 2) == nil)
        #expect(dog.observe(status(1, video: 14.9, segment: 9), at: 4.9) == nil)
        #expect(dog.observe(status(1, video: 15, segment: 9), at: 5) == .noSegments)

        // A writer that keeps failing and restarting (a new generation each second) gets frames but
        // never a segment: still a writer stall.
        dog.arm(at: 10, status: status(1, video: 15, segment: 9))
        var t = 10.0
        var generation = 1
        var result: FrameWatchdog.Stall?
        while result == nil, t < 30 {
            t += 1
            generation += 1
            result = dog.observe(status(generation, video: 20 + t, segment: nil), at: t)
        }
        #expect(result == .noSegments)
        #expect(t == 15)
    }

    @Test("Stale generations are ignored")
    func staleGenerationsIgnored() {
        var dog = FrameWatchdog()
        dog.arm(at: 0, status: status(5, video: 10, segment: 9))
        // A snapshot from an older writer, however new its times look, is not progress.
        #expect(dog.observe(status(4, video: 50, segment: 49), at: 2) == nil)
        #expect(dog.observe(status(4, video: 60, segment: 59), at: 5) == .noVideo)

        // Armed after a suspend (no writer): the writer from before the restart is stale too.
        dog.arm(at: 10, status: status(0, video: nil, segment: nil))
        #expect(dog.observe(status(5, video: 70, segment: 69), at: 12) == nil)
        #expect(dog.observe(status(5, video: 80, segment: 79), at: 15) == .noVideo)

        // The next writer counts.
        dog.arm(at: 20, status: status(0, video: nil, segment: nil))
        #expect(dog.observe(status(6, video: 90, segment: 89), at: 24) == nil)
        #expect(dog.observe(status(6, video: 90, segment: 89), at: 28.9) == nil)
        #expect(dog.observe(status(6, video: 90, segment: 89), at: 29) == .noVideo)
    }

    @Test("Disarm and re-arm restart the timeout; a disarmed watchdog reports nothing")
    func rearmResets() {
        var dog = FrameWatchdog()
        dog.arm(at: 0, status: status(1, video: 10, segment: 9))
        #expect(dog.observe(status(1, video: 10, segment: 9), at: 4) == nil)
        dog.disarm()
        #expect(dog.observe(status(1, video: 10, segment: 9), at: 9) == nil)
        dog.arm(at: 9, status: status(1, video: 10, segment: 9))
        #expect(dog.observe(status(1, video: 10, segment: 9), at: 13.9) == nil)
        #expect(dog.observe(status(1, video: 10, segment: 9), at: 14) == .noVideo)
    }

    @Test("Budget: one automatic restart per stall episode; an episode ends after 30 s without a stall")
    func restartBudget() {
        var dog = FrameWatchdog()
        let frozen = status(1, video: 10, segment: 9)
        dog.arm(at: 0, status: frozen)
        #expect(dog.observe(frozen, at: 5) == .noVideo)
        #expect(dog.mayRestartAutomatically, "the first stall restarts")

        // The restart "worked" but nothing arrives: the second stall in the episode gives up.
        dog.arm(at: 6, status: status(0, video: nil, segment: nil))
        #expect(dog.observe(status(0, video: nil, segment: nil), at: 11) == .noVideo)
        #expect(!dog.mayRestartAutomatically)

        // A user-initiated start (Try Again) begins a new episode.
        dog.forgetStalls()
        #expect(dog.mayRestartAutomatically)

        // A camera that delivers for a while after each restart: the episode only ends after 30 s.
        dog.arm(at: 20, status: status(0, video: nil, segment: nil))
        #expect(dog.observe(status(2, video: 1, segment: nil), at: 21) == nil)
        #expect(dog.observe(status(2, video: 5, segment: nil), at: 25) == .noSegments)
        #expect(dog.mayRestartAutomatically)
        dog.arm(at: 27, status: status(0, video: nil, segment: nil))
        var t = 27.0
        while t < 27 + FrameWatchdog.recoveredAfter - 1 {
            t += 0.5
            #expect(dog.observe(status(3, video: t, segment: t - 1), at: t) == nil)
        }
        dog.disarm()
        dog.arm(at: t, status: status(3, video: t, segment: t - 1))
        #expect(dog.observe(status(3, video: t, segment: t - 1), at: t + 5) == .noVideo)
        #expect(!dog.mayRestartAutomatically, "29 s of video weren't enough to end the episode")

        dog.forgetStalls()
        dog.arm(at: 100, status: status(0, video: nil, segment: nil))
        #expect(dog.observe(status(4, video: 1, segment: nil), at: 101) == nil)
        #expect(dog.observe(status(4, video: 5, segment: nil), at: 105) == .noSegments)
        dog.arm(at: 107, status: status(0, video: nil, segment: nil))
        t = 107
        while t < 107 + FrameWatchdog.recoveredAfter {
            t += 0.5
            #expect(dog.observe(status(5, video: t, segment: t - 1), at: t) == nil)
        }
        #expect(dog.stallsInEpisode == 0, "30 s of healthy recording ended the episode")
        #expect(dog.observe(status(5, video: t, segment: t - 1), at: t + 5) == .noVideo)
        #expect(dog.mayRestartAutomatically)
    }
}

@Suite("Recorder: settling a pending save when video stops")
struct SettlePendingSaveTests {

    @Test("A pending post-roll settles at once with the footage already buffered, exactly once")
    func settlesWithAvailableFootage() async throws {
        let h = RecorderHarness(buffer: 30, audio: true)
        h.source.generate(seconds: 6)
        try await h.waitForSegments(through: h.now - 2) // the timeline starts at the first frame
        let tap = h.now
        let ticket = h.recorder.beginSave(postRoll: 10)
        #expect(!ticket.isFulfilled)
        #expect(h.recorder.status().isSaving)

        // Frames stop; the post-roll can never arrive. Settling hands over what is there.
        h.recorder.settlePendingSave()
        #expect(ticket.isFulfilled)
        #expect(!h.recorder.status().isSaving)
        h.recorder.settlePendingSave() // nothing pending: no-op
        let bundle = try await h.awaitBundle(ticket)
        defer { bundle.discard() }
        #expect(!bundle.segments.isEmpty)
        #expect(bundle.clipEnd < tap + 10 - 1, "ends where the footage ends, before the post-roll")
        let clip = try await ClipExporter.export(bundle)
        let info = try await inspectClip(clip.url)
        #expect(info.duration > 3 && info.duration <= 6.5, "duration \(info.duration)")
        expectHealthyClip(info, frameRate: h.frameRate, audio: true)

        // Recording itself carries on: the recorder wasn't suspended, and another save works.
        #expect(!h.recorder.status().isSuspended)
        h.source.generate(seconds: 3)
        let again = try await h.saveClip(thenRecord: 2)
        #expect(again.duration > 5)
    }

    @Test("With nothing buffered for it, the pending save fails with an actionable message")
    func settlesWithActionableError() async throws {
        let h = RecorderHarness(buffer: 30, audio: false)
        h.source.generate(seconds: 3)
        try await h.waitForSegments(through: h.now - 1.1) // the segment ending 1 s before the end
        let status = h.recorder.status()
        let tap = try #require(status.latestMediaTime)
        let lastEnd = try #require(status.lastSegmentEnd)
        // The newest segment ends before the newest frame (the segment holding it isn't closed yet).
        // A buffer shorter than that gap means no finished segment falls inside the clip.
        try #require(lastEnd < tap - 0.1, "last segment \(lastEnd), newest frame \(tap)")
        var configuration = h.recorder.currentConfiguration
        configuration.bufferDuration = (tap - lastEnd) / 2
        h.recorder.reconfigure(configuration)
        let ticket = h.recorder.beginSave(postRoll: 5)
        #expect(!ticket.isFulfilled)

        h.recorder.settlePendingSave()
        #expect(ticket.isFulfilled)
        await #expect(throws: RecorderError.videoStopped) { _ = try await ticket.bundle() }
        let message = try #require(RecorderError.videoStopped.errorDescription)
        #expect(message.contains("video stopped"))
        #expect(message.contains("Save again"), "says what to do")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: h.storage.clipsDirectory.path)) ?? []
        #expect(leftovers.isEmpty, "the empty job folder is removed: \(leftovers)")
    }
}

/// Model tests: in the `AppModelTests` suite so they share its serialization and time limit.
@MainActor
extension AppModelTests {

    /// Lets `seconds` pass on the status loop, one tick at a time, with pipeline work and source
    /// events settling after each tick. With `deliver`, the camera produces `statusInterval` of frames
    /// (and audio) before each tick; since #9 an idle camera is a stall, so "nothing happens while
    /// recording" needs frames.
    func passTime(_ seconds: TimeInterval, _ model: AppModel, _ h: ModelHarness, deliver: Bool = false) async {
        let ticks = Int((seconds / AppModel.statusInterval).rounded())
        for _ in 0..<ticks {
            if deliver { h.source.generate(seconds: AppModel.statusInterval) }
            h.scheduler.advance(by: AppModel.statusInterval)
            await model.waitForCapture()
        }
    }

    private static let noVideoPaused = CaptureRecoveryReason.stalled(.noVideo).pausedMessage
    private static let stallFailure = "The camera stopped (no new video arrived for 5 s) and couldn't be restarted."

    @Test("Frame stall: one automatic restart, then Not recording with Try Again, screen woken")
    func frameStallRestartsOnceThenGivesUp() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        h.screen.brightness = 0.7
        model.setDimmed(true)
        await passTime(2, model, h, deliver: true)
        let starts = h.source.startCount

        // The camera "runs" but stops delivering video. The last new frame was seen on the last tick.
        h.source.withholdVideo(true)
        await passTime(4.5, model, h)
        #expect(model.phase == .recording, "4.5 s since the last new frame was seen")
        #expect(model.recovery == nil)

        h.scheduler.advance(by: AppModel.statusInterval)
        #expect(model.phase == .paused(Self.noVideoPaused), "says so while it restarts")
        #expect(model.recovery?.reason == .stalled(.noVideo))
        #expect(model.recorder.status().isSuspended)
        #expect(model.saveUnavailableReason != nil)
        await model.waitForCapture()
        #expect(h.source.startCount == starts + 1, "one restart: a full stop and start")
        #expect(h.source.resumeCount == 0, "not resumeRunning(): a stalled source already 'runs'")
        #expect(model.phase == .recording)
        #expect(model.recovery == nil)
        #expect(model.isDimmed, "a restart that works doesn't wake the screen")
        #expect(model.stallNotice?.id == "stallBanner")
        #expect(h.haptics.failures == 0)

        // Still no video after the restart: the next stall gives up instead of restarting again.
        // (Re-armed on the first tick after the restart, with the full 5 s.)
        await passTime(5, model, h)
        #expect(model.phase == .recording, "4.5 s since the watchdog was re-armed")
        h.scheduler.advance(by: AppModel.statusInterval)
        await model.waitForCapture()
        #expect(h.source.startCount == starts + 1, "no second automatic restart")
        #expect(model.phase == .failed(Self.stallFailure))
        let notice = try #require(model.startFailureNotice)
        #expect(notice.title == "Not recording")
        #expect(notice.action == .tryAgain)
        #expect(model.stallNotice == nil)
        #expect(!model.isDimmed, "woken so the notice can be seen")
        #expect(h.screen.brightness == 0.7)
        #expect(h.haptics.failures == 1)
        #expect(!h.screen.idleTimerDisabled)
        #expect(h.source.runState == .stopped)

        // Bounded: nothing more happens however long it waits.
        h.scheduler.advance(by: 600)
        await model.waitForCapture()
        #expect(h.source.startCount == starts + 1)
        #expect(h.source.resumeCount == 0)
        #expect(model.phase == .failed(Self.stallFailure))

        // Try Again, with a camera that delivers again: recording, and it stays up.
        h.source.withholdVideo(false)
        model.retryStart()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        await passTime(8, model, h, deliver: true)
        #expect(model.phase == .recording)
        #expect(model.recovery == nil)
        #expect(h.source.startCount == starts + 2)
        #expect(model.recorder.status().bufferedSeconds > 0)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Frame stall recovered: recording resumes, the user is told, and a later stall gets its own restart")
    func frameStallRecovers() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.updateSettings { $0.bufferSeconds = 15 }
        model.start()
        await model.waitForCapture()
        await passTime(2, model, h, deliver: true)
        let starts = h.source.startCount

        h.source.withholdVideo(true)
        await passTime(5.5, model, h)
        #expect(model.phase == .recording)
        #expect(h.source.startCount == starts + 1)
        let notice = try #require(model.stallNotice)
        #expect(notice.title == "The camera was restarted")
        #expect(notice.message.contains("No new video arrived for 5 s"))
        #expect(notice.message.contains("Footage from before then is gone"))
        #expect(notice.severity == .warning)
        #expect(notice.action == nil)

        // The camera delivers again after the restart.
        h.source.withholdVideo(false)
        await passTime(17, model, h, deliver: true)
        #expect(model.phase == .recording)
        #expect(h.source.startCount == starts + 1, "no further restart while frames flow")
        try await waitUntil { model.recorder.status().bufferedSeconds >= 15 }
        model.refreshStatus()
        #expect(model.stallNotice == nil, "cleared once the buffer is full again")

        // 30 s of healthy recording end the episode: a new stall gets an automatic restart again.
        await passTime(15, model, h, deliver: true)
        h.source.withholdVideo(true)
        await passTime(5.5, model, h)
        #expect(h.source.startCount == starts + 2)
        #expect(model.phase == .recording)
        #expect(model.stallNotice != nil)
        model.stop()
        await model.waitForPipeline()
        #expect(model.stallNotice == nil)
    }

    @Test("Audio that keeps arriving doesn't hide a video stall")
    func audioDoesNotMaskVideoStall() async throws {
        // Real-time recorder: audio fed without video is never held back waiting for interleaving.
        let h = ModelHarness(realTime: true)
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.updateSettings { $0.voiceTriggerEnabled = true } // its tap counts the audio samples
        model.start()
        await model.waitForCapture()
        try await waitUntil { h.voice.isRunning }
        await passTime(2, model, h, deliver: true)
        #expect(model.recorder.status().latestMediaTime != nil)
        let starts = h.source.startCount

        h.source.withholdVideo(true)
        let audioBefore = h.voice.audioSamplesSeen
        // Audio only, tick by tick, until the watchdog reacts. (The real-time writer may have dropped
        // some of the last video frames, so the last new frame may be a tick or two older.)
        var stalledAfter: TimeInterval?
        for tick in 1...20 {
            h.source.generate(seconds: AppModel.statusInterval)
            h.scheduler.advance(by: AppModel.statusInterval)
            if let recovery = model.recovery {
                #expect(recovery.reason == .stalled(.noVideo))
                stalledAfter = Double(tick) * AppModel.statusInterval
                break
            }
            #expect(model.phase == .recording)
            await model.waitForCapture()
        }
        let after = try #require(stalledAfter, "audio kept the stall hidden")
        #expect(after <= FrameWatchdog.timeout + AppModel.statusInterval, "stalled after \(after) s")
        #expect(h.voice.audioSamplesSeen > audioBefore + 100, "the microphone kept delivering")
        await model.waitForCapture()
        #expect(h.source.startCount == starts + 1)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("A save waiting for its post-roll when video stops settles once, with the footage there is")
    func pendingPostRollSettlesOnStall() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.updateSettings { $0.postRollSeconds = 10 }
        model.start()
        await model.waitForCapture()
        await passTime(4, model, h, deliver: true)
        try await waitUntil { model.recorder.status().bufferedSeconds >= 2 }

        let task = try #require(model.save())
        #expect(model.isSaving)
        #expect(model.recorder.status().isSaving, "waiting for the post-roll")
        h.source.withholdVideo(true)
        await passTime(5.5, model, h)
        #expect(h.source.startCount == 2, "the stall restarted the camera")

        await task.value // never hangs: settled by the watchdog, not by the post-roll
        #expect(!model.isSaving)
        #expect(h.library.clips().count == 1)
        #expect(h.haptics.successes == 1)
        #expect(h.haptics.failures == 0)
        let toast = try #require(model.toast?.message)
        #expect(toast.hasPrefix("Saved"), "toast: \(toast)")
        #expect(toast.contains("ends early"), "toast: \(toast)")
        let clip = try #require(h.library.clips().first)
        let info = try await inspectClip(clip)
        #expect(info.duration >= 1 && info.duration <= 5, "the footage there was: \(info.duration) s")
        #expect(h.backgroundTasks.ended == 1)

        // Exactly once: nothing else arrives later.
        h.source.withholdVideo(false)
        await passTime(3, model, h, deliver: true)
        #expect(h.library.clips().count == 1)
        #expect(h.haptics.successes == 1)
        #expect(h.backgroundTasks.begun == 1)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("No false stall: launch, settings and thermal restarts, background, interruptions")
    func frameWatchdogNoFalsePositives() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        var starts = h.source.startCount

        // No frame ever arrives. Each step lets 4.5 s pass (4 s since the watchdog is re-armed on the
        // first tick); together they are far beyond 5 s, so a step that failed to reset it would stall.
        func quietly(_ step: String) async {
            await passTime(4.5, model, h)
            #expect(model.phase == .recording, "\(step)")
            #expect(model.recovery == nil, "\(step)")
            #expect(h.source.resumeCount == 0, "\(step)")
        }

        await quietly("the first seconds after launch")
        #expect(h.source.startCount == starts)

        h.thermal.set(.serious) // step-down restarts capture
        await model.waitForCapture()
        #expect(h.source.startCount == starts + 1)
        starts += 1
        await quietly("after a thermal step-down")

        h.thermal.set(.nominal)
        await model.waitForCapture()
        starts += 1
        model.updateSettings { $0.resolution = .hd720 } // a settings change that restarts capture
        await model.waitForCapture()
        #expect(h.source.startCount == starts + 1)
        starts += 1
        await quietly("after a settings change")

        model.updateSettings { $0.bufferSeconds = 60 } // applied in place
        await quietly("after a buffer-length change")

        model.scenePhaseChanged(.background)
        await model.waitForCapture()
        await passTime(30, model, h)
        #expect(model.phase == .paused(InterruptionReason.backgrounded.message))
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        #expect(h.source.startCount == starts + 1)
        starts += 1
        await quietly("after returning from the background")

        h.source.simulate(.interrupted(.cameraInUseByAnotherApp))
        await model.waitForCapture()
        await passTime(30, model, h)
        #expect(model.phase == .paused(InterruptionReason.cameraInUseByAnotherApp.message))
        h.source.simulate(.interruptionEnded)
        await model.waitForCapture()
        await quietly("after an interruption")
        #expect(h.source.startCount == starts, "no restart for an interruption")

        // It is armed: the 5 s mark since the interruption ended is a stall.
        await passTime(0.5, model, h)
        #expect(model.phase == .recording)
        h.scheduler.advance(by: AppModel.statusInterval)
        #expect(model.recovery?.reason == .stalled(.noVideo))
        await model.waitForCapture()
        model.stop()
        await model.waitForPipeline()
        #expect(model.recovery == nil)
    }

    @Test("A stop during stall recovery supersedes it")
    func stopDuringStallRecovery() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        h.source.withholdVideo(true)
        await passTime(5, model, h)
        h.scheduler.advance(by: AppModel.statusInterval)
        #expect(model.recovery?.reason == .stalled(.noVideo))
        model.scenePhaseChanged(.background) // queued behind the restart attempt
        await model.waitForCapture()
        #expect(model.recovery == nil)
        #expect(model.phase == .paused(InterruptionReason.backgrounded.message))
        #expect(model.stallNotice == nil)
        let starts = h.source.startCount
        await passTime(30, model, h)
        #expect(h.source.startCount == starts, "nothing restarts in the background")
        #expect(model.phase == .paused(InterruptionReason.backgrounded.message))
    }
}
