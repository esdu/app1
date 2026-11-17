import AVFoundation
import Foundation
import Testing
@testable import RewindCam

/// Issue #36: a recognition session that keeps failing is restarted on the `RestartBackoff` schedule,
/// not at once forever; once the budget is spent the trigger stops and reports it, and the app says
/// so. Callbacks are delivered by hand through `FakeRecognitionEngine`; the backoff timers run on a
/// `FakeDelayScheduler` and session ages on a `FakeWallClock`, so no test sleeps. MainActor: the
/// callbacks arrive on the main thread, as `SFSpeechRecognizer` delivers them.
@Suite("Voice trigger: sessions that keep failing back off, then stop (#36)")
@MainActor
struct VoiceTriggerFailureTests {
    @MainActor
    private struct Setup {
        let engine: FakeRecognitionEngine
        let scheduler = FakeDelayScheduler()
        let clock = FakeWallClock()
        let trigger: SpeechVoiceTrigger
        let fired = Locked(0)
        let gaveUp = Locked(0)

        init(_ engine: FakeRecognitionEngine = FakeRecognitionEngine()) {
            self.engine = engine
            trigger = SpeechVoiceTrigger(engine: engine, clock: clock, scheduler: scheduler)
        }

        func start() {
            let fired = fired, gaveUp = gaveUp
            trigger.start(onTrigger: { fired.withLock { $0 += 1 } }, onGiveUp: { gaveUp.withLock { $0 += 1 } })
        }

        /// The newest session reports an error without having produced a transcript.
        func failLatest() throws {
            let session = try #require(engine.sessions.last)
            session.deliver(RecognitionUpdate(failed: true))
        }
    }

    private static let failure = RecognitionUpdate(failed: true)
    /// Restarts per budget: the first at once, the rest after `RestartBackoff.delays.dropFirst()`.
    private static let restarts = RestartBackoff.delays.count

    /// From a full budget and a live session: fails every session as soon as it starts, checking each
    /// wait, until the trigger gives up.
    private func failEverySession(_ t: Setup) throws {
        let first = t.engine.sessions.count
        let startedAt = t.scheduler.now
        try t.failLatest()
        #expect(t.engine.sessions.count == first + 1, "the first failure is restarted at once")
        #expect(t.scheduler.pendingCount == 0)
        for delay in RestartBackoff.delays.dropFirst() {
            try t.failLatest()
            let count = t.engine.sessions.count
            #expect(t.scheduler.pendingCount == 1, "one restart waits")
            t.scheduler.advance(by: delay - 0.25)
            #expect(t.engine.sessions.count == count, "no new session before \(delay) s")
            t.scheduler.advance(by: 0.25)
            #expect(t.engine.sessions.count == count + 1, "a new session after \(delay) s")
        }
        #expect(t.gaveUp.current == 0, "still trying")
        try t.failLatest() // the budget is spent
        #expect(t.gaveUp.current == 1)
        #expect(t.engine.sessions.count == first + Self.restarts)
        #expect(t.scheduler.pendingCount == 0, "nothing more is scheduled")
        #expect(t.scheduler.now - startedAt == RestartBackoff.delays.reduce(0, +))
        #expect(t.engine.sessions.allSatisfy { $0.cancelled && $0.endedAudio })
    }

    @Test("Every session fails at once: a bounded number of sessions, on the backoff schedule, then one stop")
    func everySessionFails() throws {
        let t = Setup()
        t.start()
        #expect(t.engine.sessions.count == 1)
        try failEverySession(t)
        #expect(t.engine.sessions.count == 1 + Self.restarts, "7 sessions in about 30 s, not a loop")

        // Stopped: no more sessions, however long it waits; late callbacks and audio change nothing.
        let sample = try #require(makeSilentAudioSample())
        t.scheduler.advance(by: 3600)
        t.engine.sessions.last?.deliver(Self.failure)
        t.engine.sessions.last?.say("save that")
        t.trigger.consume(sample, kind: .audio)
        #expect(t.engine.sessions.count == 1 + Self.restarts)
        #expect(t.engine.sessions.allSatisfy { $0.appended == 0 })
        #expect(t.gaveUp.current == 1, "reported once")
        #expect(t.fired.current == 0)

        // Starting again (the next capture start, or the toggle) tries with a full budget.
        t.start()
        #expect(t.engine.sessions.count == 2 + Self.restarts)
        try failEverySession(t)
        #expect(t.gaveUp.current == 2)
        t.trigger.stop()
    }

    @Test("A session that produces a transcript refills the budget; healthy ends restart at once")
    func transcriptResetsTheCount() throws {
        let t = Setup()
        let sample = try #require(makeSilentAudioSample())
        t.start()
        try t.failLatest() // failure 1: at once
        try t.failLatest() // failure 2: waits 1 s
        #expect(t.scheduler.pendingCount == 1)
        t.scheduler.advance(by: 1)
        #expect(t.engine.sessions.count == 3)

        // This one works: a partial transcript. Its later error isn't a failure.
        t.engine.sessions[2].say("hello")
        try t.failLatest()
        #expect(t.engine.sessions.count == 4, "restarted at once")
        #expect(t.scheduler.pendingCount == 0)
        // The count was reset: the next failure is "failure 1" again (at once), then 1 s, not 2 s.
        try t.failLatest()
        #expect(t.engine.sessions.count == 5)
        #expect(t.scheduler.pendingCount == 0)
        try t.failLatest()
        #expect(t.scheduler.pendingCount == 1)
        t.scheduler.advance(by: 1)
        #expect(t.engine.sessions.count == 6)

        // A quiet room: no transcript, but the session ran `healthyRunTime` before its error.
        t.clock.advance(by: SpeechVoiceTrigger.healthyRunTime)
        try t.failLatest()
        #expect(t.engine.sessions.count == 7, "not a failure: restarted at once")
        #expect(t.scheduler.pendingCount == 0)
        try t.failLatest() // the budget is full again: failure 1 is at once
        #expect(t.engine.sessions.count == 8)
        #expect(t.scheduler.pendingCount == 0)

        // A normal final result (it carries a transcript) is healthy...
        t.engine.sessions[7].say("", isFinal: true)
        #expect(t.engine.sessions.count == 9)
        // ...but a session that ends at once without any transcript is a failure, final or not.
        t.engine.sessions[8].deliver(RecognitionUpdate(isFinal: true))
        #expect(t.engine.sessions.count == 10, "failure 1: at once")
        t.engine.sessions[9].deliver(RecognitionUpdate(isFinal: true))
        #expect(t.engine.sessions.count == 10, "failure 2 waits")
        #expect(t.scheduler.pendingCount == 1)
        t.scheduler.advance(by: 1)
        #expect(t.engine.sessions.count == 11)

        // The 50 s recycle of a session that ran normally is healthy and refills the budget too.
        t.clock.advance(by: SpeechVoiceTrigger.maxTaskDuration + 1)
        t.trigger.consume(sample, kind: .audio)
        #expect(t.engine.sessions.count == 12)
        #expect(t.engine.sessions[10].cancelled)
        try t.failLatest()
        #expect(t.engine.sessions.count == 13, "failure 1 after the recycle: at once")
        #expect(t.scheduler.pendingCount == 0)

        // Working again, then a run of failures: the whole schedule again.
        t.engine.sessions[12].say("hello")
        try t.failLatest()
        #expect(t.engine.sessions.count == 14, "healthy: at once")
        try failEverySession(t)
        #expect(t.fired.current == 0)
        t.trigger.stop()
    }

    @Test("A nil session counts as a failure: retried on the backoff schedule, then the trigger stops")
    func nilSessionIsAFailure() throws {
        let t = Setup()
        t.engine.behaviour = .returnsNil
        t.start()
        #expect(t.engine.startAttempts == 2, "the first failure is retried at once")
        #expect(t.engine.sessions.isEmpty)
        #expect(t.scheduler.pendingCount == 1)
        for delay in RestartBackoff.delays.dropFirst() {
            #expect(t.gaveUp.current == 0)
            let attempts = t.engine.startAttempts
            t.scheduler.advance(by: delay - 0.25)
            #expect(t.engine.startAttempts == attempts)
            t.scheduler.advance(by: 0.25)
            #expect(t.engine.startAttempts == attempts + 1)
        }
        #expect(t.engine.startAttempts == 1 + Self.restarts)
        #expect(t.gaveUp.current == 1)
        #expect(t.scheduler.pendingCount == 0)
        t.scheduler.advance(by: 3600)
        #expect(t.engine.startAttempts == 1 + Self.restarts)

        // Recognition comes back while a restart waits: that session is kept and works.
        t.start()
        #expect(t.scheduler.pendingCount == 1)
        t.engine.behaviour = .normal
        t.scheduler.advance(by: 1)
        #expect(t.engine.sessions.count == 1)
        t.engine.sessions[0].say("save that")
        #expect(t.fired.current == 1)
        #expect(t.gaveUp.current == 1)
        t.trigger.stop()
    }

    @Test("Recogniser not ready (SFSpeechRecognizer.isAvailable false): no session is requested; same backoff")
    func recogniserUnavailable() throws {
        let t = Setup()
        t.engine.isReady = false
        t.start()
        #expect(t.engine.readyChecks == 2)
        #expect(t.engine.startAttempts == 0, "no task is requested from a recogniser that isn't ready")
        for delay in RestartBackoff.delays.dropFirst() {
            #expect(t.gaveUp.current == 0)
            t.scheduler.advance(by: delay)
        }
        #expect(t.engine.readyChecks == 1 + Self.restarts)
        #expect(t.engine.startAttempts == 0)
        #expect(t.gaveUp.current == 1)
        #expect(t.scheduler.pendingCount == 0)

        // Ready again during a wait: the next restart starts a session that hears the phrase.
        t.start()
        t.scheduler.advance(by: 1)
        #expect(t.engine.readyChecks == 4 + Self.restarts)
        t.engine.isReady = true
        t.scheduler.advance(by: 2)
        #expect(t.engine.sessions.count == 1)
        t.engine.sessions[0].say("save that")
        #expect(t.fired.current == 1)
        #expect(t.gaveUp.current == 1)
        t.trigger.stop()
    }

    @Test("A failure delivered before the session is stored ends that session; it never receives audio")
    func failureBeforeSessionIsStored() throws {
        // errorOnCancel: each cancelled session reports its cancellation error too (stale by then).
        let t = Setup(FakeRecognitionEngine(errorOnCancel: true))
        let sample = try #require(makeSilentAudioSample())
        t.engine.behaviour = .failsWhileStarting
        t.start()
        #expect(t.engine.sessions.count == 2, "failure 1 is retried at once")
        #expect(t.scheduler.pendingCount == 1, "failure 2 waits")
        #expect(t.engine.sessions.allSatisfy { $0.cancelled && $0.endedAudio })
        t.trigger.consume(sample, kind: .audio)
        #expect(t.engine.sessions.allSatisfy { $0.appended == 0 }, "a failed session isn't fed")

        // A working session next: stored and fed. The early failures still count: its failure is the 3rd.
        t.engine.behaviour = .normal
        t.scheduler.advance(by: 1)
        #expect(t.engine.sessions.count == 3)
        let working = t.engine.sessions[2]
        #expect(!working.cancelled)
        t.trigger.consume(sample, kind: .audio)
        #expect(working.appended == 1)
        working.deliver(Self.failure)
        #expect(working.cancelled)
        t.scheduler.advance(by: 1.75)
        #expect(t.engine.sessions.count == 3, "failure 3 waits 2 s")
        t.scheduler.advance(by: 0.25)
        #expect(t.engine.sessions.count == 4)

        // Failing while starting all the way: the trigger stops after the same budget.
        t.engine.behaviour = .failsWhileStarting
        try t.failLatest() // failure 4: 4 s
        for delay in RestartBackoff.delays.dropFirst(3) {
            #expect(t.gaveUp.current == 0)
            t.scheduler.advance(by: delay)
        }
        #expect(t.gaveUp.current == 1)
        #expect(t.engine.sessions.count == 1 + Self.restarts)
        #expect(t.scheduler.pendingCount == 0)
        t.trigger.stop()
    }

    @Test("Stale callbacks (#2) are still ignored, also while a restart waits; stop and start cancel the wait")
    func staleCallbacksStillIgnored() throws {
        let t = Setup(FakeRecognitionEngine(errorOnCancel: true))
        t.start()
        try t.failLatest()
        try t.failLatest()
        #expect(t.engine.sessions.count == 2)
        #expect(t.scheduler.pendingCount == 1)
        let replaced = t.engine.sessions

        // Late callbacks from both replaced sessions while the restart waits.
        for old in replaced {
            old.deliver(Self.failure)
            old.say("save that")
            old.say("something", isFinal: true)
        }
        #expect(t.engine.sessions.count == 2, "a stale callback starts nothing")
        #expect(t.scheduler.pendingCount == 1, "nor schedules anything")
        #expect(t.fired.current == 0)

        t.scheduler.advance(by: 1)
        #expect(t.engine.sessions.count == 3)
        let current = t.engine.sessions[2]
        for old in replaced {
            old.deliver(Self.failure)
            old.say("save that")
        }
        #expect(!current.cancelled, "a stale callback doesn't touch the current session")
        #expect(t.engine.sessions.count == 3)
        // Their transcripts didn't refill the budget either: this is failure 3 (2 s).
        current.deliver(Self.failure)
        #expect(t.scheduler.pendingCount == 1)
        t.scheduler.advance(by: 1.75)
        #expect(t.engine.sessions.count == 3)

        // stop() during the wait: the timer starts nothing and nothing is reported.
        t.trigger.stop()
        t.scheduler.advance(by: 3600)
        #expect(t.engine.sessions.count == 3)
        #expect(t.gaveUp.current == 0)

        // start() during a wait: a session at once, and the old timer is stale.
        t.start()
        #expect(t.engine.sessions.count == 4)
        try t.failLatest() // fresh budget: at once
        try t.failLatest() // waits 1 s
        #expect(t.engine.sessions.count == 5)
        t.start()
        #expect(t.engine.sessions.count == 6)
        t.scheduler.advance(by: 60)
        #expect(t.engine.sessions.count == 6, "the earlier wait's timer starts nothing")
        #expect(!t.engine.sessions[5].cancelled)
        t.engine.sessions[5].say("save that")
        #expect(t.fired.current == 1)
        t.trigger.stop()
        #expect(t.gaveUp.current == 0, "stop() isn't a give-up")
    }
}

/// `SpeechVoiceTrigger` with authorization granted (the real request would show a system prompt).
private final class AuthorizedVoiceTrigger: VoiceTrigger, Sendable {
    let inner: SpeechVoiceTrigger
    init(_ inner: SpeechVoiceTrigger) { self.inner = inner }
    var isAvailable: Bool { inner.isAvailable }
    func requestAuthorization() async -> Bool { true }
    func start(onTrigger: @escaping @Sendable () -> Void, onGiveUp: @escaping @Sendable () -> Void) {
        inner.start(onTrigger: onTrigger, onGiveUp: onGiveUp)
    }
    func stop() { inner.stop() }
    func consume(_ sampleBuffer: CMSampleBuffer, kind: MediaKind) { inner.consume(sampleBuffer, kind: kind) }
}

/// The app's side of #36: listening state, the Settings row, one toast, and the retry. In the
/// `AppModelTests` suite so it shares its serialization and time limit.
@MainActor
extension AppModelTests {
    private static let voiceStoppedToast = "The voice trigger stopped: speech recognition isn't available."

    @Test("Voice trigger gives up: Listening says No and why, one toast; retried on toggle and on the next start")
    func voiceTriggerGivesUp() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let engine = FakeRecognitionEngine()
        var environment = h.makeEnvironment()
        environment.voice = AuthorizedVoiceTrigger(
            SpeechVoiceTrigger(engine: engine, clock: h.clock, scheduler: h.scheduler))
        let model = AppModel(environment: environment)
        model.updateSettings { $0.voiceTriggerEnabled = true }
        model.start()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        try await waitUntil { engine.sessions.count == 1 }
        #expect(model.isVoiceListening)
        #expect(model.voiceListeningLabel == "Yes")
        h.announcer.removeAll()

        // Recognition breaks: every new session fails at once.
        engine.behaviour = .failsWhileStarting
        try #require(engine.sessions.last).deliver(RecognitionUpdate(failed: true))
        #expect(engine.sessions.count == 2)
        #expect(model.isVoiceListening, "still trying, on the backoff schedule")
        await passTime(14.5, model, h, deliver: true) // waits of 1, 2 and 4 s; the 8 s wait runs
        #expect(model.isVoiceListening)
        #expect(engine.sessions.count == 5)
        await passTime(15.5, model, h, deliver: true) // the last wait (15 s), then the give-up
        try await waitUntil { !model.isVoiceListening }
        #expect(engine.sessions.count == 7)
        #expect(model.voiceRecognitionFailed)
        #expect(model.voiceListeningLabel == "No — speech recognition isn't available")
        #expect(model.toast?.message == Self.voiceStoppedToast)
        #expect(model.toast?.isError == true)
        #expect(h.announcer.announcements == [.init(message: Self.voiceStoppedToast, priority: .high)])
        // Recording and Save are unaffected.
        #expect(model.phase == .recording)
        #expect(model.saveUnavailableReason == nil)
        #expect(model.settings.voiceTriggerEnabled, "the setting is not silently changed")

        // No retry loop and no repeated announcement while it stays stopped.
        await passTime(60, model, h, deliver: true)
        #expect(engine.sessions.count == 7)
        #expect(h.announcer.messages == [Self.voiceStoppedToast])
        #expect(model.voiceListeningLabel == "No — speech recognition isn't available")

        // Toggling the trigger tries again.
        engine.behaviour = .normal
        model.updateSettings { $0.voiceTriggerEnabled = false }
        #expect(!model.voiceRecognitionFailed)
        model.updateSettings { $0.voiceTriggerEnabled = true }
        try await waitUntil { engine.sessions.count == 8 }
        #expect(model.isVoiceListening)
        #expect(model.voiceListeningLabel == "Yes")

        // It breaks again, then the next capture start tries again.
        engine.behaviour = .failsWhileStarting
        try #require(engine.sessions.last).deliver(RecognitionUpdate(failed: true))
        await passTime(30, model, h, deliver: true)
        try await waitUntil { !model.isVoiceListening }
        #expect(engine.sessions.count == 14)
        #expect(model.voiceListeningLabel == "No — speech recognition isn't available")
        #expect(h.announcer.messages == [Self.voiceStoppedToast, Self.voiceStoppedToast], "once per attempt")

        engine.behaviour = .normal
        model.stop()
        await model.waitForPipeline()
        model.start()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        try await waitUntil { engine.sessions.count == 15 && model.isVoiceListening }
        #expect(!model.voiceRecognitionFailed)
        #expect(model.voiceListeningLabel == "Yes")
        h.source.generate(seconds: 1)
        let listening = try #require(engine.sessions.last)
        #expect(listening.appended > 0, "the new session hears the capture audio")

        model.stop()
        await model.waitForPipeline()
    }

    @Test("Voice trigger gives up while recording: Pause and Resume try again; a report after a stop is ignored")
    func voiceGiveUpRetriedOnResume() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.updateSettings { $0.voiceTriggerEnabled = true }
        model.start()
        await model.waitForCapture()
        try await waitUntil { h.voice.isRunning }

        h.voice.giveUp()
        try await waitUntil { !model.isVoiceListening }
        #expect(model.voiceListeningLabel == "No — speech recognition isn't available")
        #expect(h.announcer.messages.filter { $0 == Self.voiceStoppedToast }.count == 1)

        model.pauseCapture()
        await model.waitForPipeline()
        model.resumeCapture()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        try await waitUntil { h.voice.isRunning && model.isVoiceListening }
        #expect(model.voiceListeningLabel == "Yes")

        // Paused before the report is handled: the pause owns the state; no toast, nothing stale.
        h.voice.giveUp()
        model.pauseCapture() // before the report's main-actor hop runs
        await model.waitForPipeline()
        #expect(!model.voiceRecognitionFailed)
        #expect(model.voiceListeningLabel == "No")
        model.resumeCapture()
        await model.waitForCapture()
        try await waitUntil { h.voice.isRunning && model.isVoiceListening }
        #expect(!model.voiceRecognitionFailed)
        #expect(h.announcer.messages.filter { $0 == Self.voiceStoppedToast }.count == 1, "the stale report said nothing")
        model.stop()
        await model.waitForPipeline()
    }
}
