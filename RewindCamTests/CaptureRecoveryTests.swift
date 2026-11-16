import Foundation
import Testing
@testable import RewindCam

/// Issue #4: source events are handled in order, a runtime error always ends in "recording again" or
/// in a truthful failure with Try Again, and the status-loop safety net repairs a missed event. Time
/// is the harness's `FakeDelayScheduler`: no test sleeps. In the `AppModelTests` suite so it shares
/// its serialization and time limit.
@MainActor
extension AppModelTests {

    private static let simulatedError = "simulated runtime error"
    private static let restartingMessage = InterruptionReason.runtimeError(simulatedError).message

    private func startRecording(_ h: ModelHarness) async -> AppModel {
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        return model
    }

    /// Frames reach the buffer again (a new generation after the suspend).
    private func expectBuffering(_ model: AppModel, _ h: ModelHarness) async throws {
        h.source.generate(seconds: 3)
        try await waitUntil { model.recorder.status().bufferedSeconds > 0 }
        #expect(!model.recorder.status().isSuspended)
    }

    @Test("Source events are handled in the order emitted, however many arrive back to back")
    func sourceEventsAreHandledInOrder() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startRecording(h)
        let source = h.source
        let before = model.handledSourceEvents
        var emitted = 0
        for round in 0..<20 {
            let endsInterrupted = round.isMultiple(of: 2)
            // From another thread, as the camera's notifications arrive.
            await Task.detached {
                for _ in 0..<50 {
                    source.simulate(.interrupted(.cameraInUseByAnotherApp))
                    source.simulate(.interruptionEnded)
                }
                if endsInterrupted { source.simulate(.interrupted(.audioInUseByAnotherApp)) }
            }.value
            emitted += 100 + (endsInterrupted ? 1 : 0)
            await model.waitForCaptureEvents()
            #expect(model.handledSourceEvents - before == emitted, "every event handled exactly once")
            if endsInterrupted {
                #expect(model.phase == .paused(InterruptionReason.audioInUseByAnotherApp.message))
                #expect(model.recorder.status().isSuspended)
            } else {
                #expect(model.phase == .recording, "round \(round)")
                #expect(!model.recorder.status().isSuspended, "round \(round)")
            }
        }
        try await expectBuffering(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Runtime error, session still running: recording resumes at once, without a restart")
    func runtimeErrorWithSessionStillRunning() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startRecording(h)
        h.source.generate(seconds: 3)
        let starts = h.source.startCount

        h.source.simulateRuntimeError(sessionStops: false)
        await model.waitForCapture()

        #expect(model.phase == .recording)
        #expect(model.recovery == nil)
        #expect(h.source.resumeCount == 1, "one immediate attempt found it running")
        #expect(h.source.startCount == starts, "no reconfigure")
        #expect(h.scheduler.pendingCount == 1, "nothing scheduled but the status loop")
        #expect(model.saveUnavailableReason == nil)
        try await expectBuffering(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Runtime error that stops the session: restarts on the backoff schedule until one works")
    func runtimeErrorRetriesWithBackoff() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startRecording(h)
        h.source.setResumeFailures(3)

        h.source.simulateRuntimeError(sessionStops: true)
        await model.waitForCapture()
        #expect(model.phase == .paused(Self.restartingMessage))
        #expect(model.recovery?.reason == .runtimeError(Self.simulatedError))
        #expect(model.recorder.status().isSuspended)
        #expect(model.saveUnavailableReason != nil)
        #expect(h.source.resumeCount == 1, "the first attempt is immediate")

        // Attempts 2, 3 and 4 come exactly after the next three delays (1 s, 2 s, 4 s); the 4th works.
        var attempts = 1
        for delay in RestartBackoff.delays.dropFirst().prefix(3) {
            #expect(model.phase == .paused(Self.restartingMessage))
            h.scheduler.advance(by: delay - 0.01)
            await model.waitForCapture()
            #expect(h.source.resumeCount == attempts, "no attempt before \(delay) s")
            h.scheduler.advance(by: 0.01)
            await model.waitForCapture()
            attempts += 1
            #expect(h.source.resumeCount == attempts, "an attempt after \(delay) s")
        }
        #expect(model.phase == .recording)
        #expect(model.recovery == nil)
        try await expectBuffering(model, h)

        // Nothing else is pending: no stray attempt later.
        h.scheduler.advance(by: 60)
        await model.waitForCapture()
        #expect(h.source.resumeCount == attempts)
        #expect(model.phase == .recording)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Restarts that keep failing give up: Not recording with Try Again, screen woken, later events ignored")
    func runtimeErrorRecoveryGivesUp() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startRecording(h)
        h.screen.brightness = 0.7
        model.setDimmed(true)
        h.source.setResumeFailures(1_000)
        let why = "media services were reset"

        h.source.simulateRuntimeError(why, sessionStops: true)
        await model.waitForCapture()
        let id = try #require(model.recovery?.id)
        for (index, delay) in RestartBackoff.delays.dropFirst().enumerated() {
            #expect(model.phase == .paused(InterruptionReason.runtimeError(why).message))
            #expect(model.startFailureNotice == nil)
            if index == 1 {
                // The same error reported again doesn't restart the budget.
                h.source.simulateRuntimeError(why, sessionStops: true)
                await model.waitForCapture()
                #expect(model.recovery?.id == id)
            }
            h.scheduler.advance(by: delay)
            await model.waitForCapture()
        }

        let message = "The camera stopped (\(why)) and couldn't be restarted."
        #expect(h.source.resumeCount == RestartBackoff.delays.count)
        #expect(model.phase == .failed(message))
        #expect(model.recovery == nil)
        let notice = try #require(model.startFailureNotice)
        #expect(notice.title == "Not recording")
        #expect(notice.message == message)
        #expect(notice.action == .tryAgain)
        #expect(!model.isDimmed, "woken so the notice can be seen")
        #expect(h.screen.brightness == 0.7)
        #expect(h.haptics.failures == 1)
        #expect(!h.screen.idleTimerDisabled, "nothing is recorded, so the screen may lock")
        #expect(h.source.runState == .stopped)
        #expect(model.saveUnavailableReason != nil)

        // Bounded: no more attempts however long it waits, and the safety net leaves the failure alone.
        h.scheduler.advance(by: 600)
        await model.waitForCapture()
        #expect(h.source.resumeCount == RestartBackoff.delays.count)
        #expect(model.phase == .failed(message))

        // A late "running again" is stale (the source was stopped): the failure notice stays.
        h.source.simulate(.interruptionEnded)
        await model.waitForCapture()
        h.scheduler.advance(by: AppModel.statusInterval)
        await model.waitForCapture()
        #expect(model.phase == .failed(message))
        #expect(model.recorder.status().isSuspended)

        // Try Again is a normal start through the pipeline.
        model.retryStart()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(model.startFailureNotice == nil)
        #expect(h.screen.idleTimerDisabled)
        try await expectBuffering(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Backgrounding during recovery cancels it; returning starts normally")
    func backgroundCancelsRecovery() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startRecording(h)
        h.source.setResumeFailures(1_000)
        h.source.simulateRuntimeError(sessionStops: true)
        await model.waitForCapture()
        #expect(model.recovery != nil)

        model.scenePhaseChanged(.background)
        await model.waitForCapture()
        #expect(model.recovery == nil)
        #expect(model.phase == .paused(InterruptionReason.backgrounded.message))
        let resumes = h.source.resumeCount
        h.scheduler.advance(by: 60)
        await model.waitForCapture()
        #expect(h.source.resumeCount == resumes, "no restart attempt in the background")
        #expect(model.phase == .paused(InterruptionReason.backgrounded.message))

        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        #expect(model.phase == .recording)
        try await expectBuffering(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("An ordinary interruption during recovery takes over: no give-up, and its end resumes recording")
    func interruptionDuringRecovery() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startRecording(h)
        h.source.setResumeFailures(1_000)
        h.source.simulateRuntimeError(sessionStops: true)
        await model.waitForCapture()
        #expect(model.recovery != nil)

        h.source.simulate(.interrupted(.cameraInUseByAnotherApp))
        await model.waitForCapture()
        #expect(model.recovery == nil)
        #expect(model.phase == .paused(InterruptionReason.cameraInUseByAnotherApp.message))
        let resumes = h.source.resumeCount
        h.scheduler.advance(by: 60)
        await model.waitForCapture()
        #expect(h.source.resumeCount == resumes, "iOS ends this interruption; no restarts meanwhile")
        #expect(model.phase == .paused(InterruptionReason.cameraInUseByAnotherApp.message))

        h.source.simulate(.interruptionEnded)
        await model.waitForCapture()
        #expect(model.phase == .recording)
        try await expectBuffering(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Safety net: a missed 'running again' or a suspended recorder is repaired on the next status tick")
    func safetyNetResumesSuspendedRecorder() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startRecording(h)

        h.source.simulate(.interrupted(.cameraInUseByAnotherApp))
        await model.waitForCapture()
        h.scheduler.advance(by: AppModel.statusInterval)
        await model.waitForCapture()
        #expect(model.phase == .paused(InterruptionReason.cameraInUseByAnotherApp.message),
                "still interrupted: nothing to repair")

        // iOS resumed the session but the notification never arrived.
        h.source.setRunStateSilently(.running)
        h.scheduler.advance(by: AppModel.statusInterval)
        await model.waitForCapture()
        #expect(model.phase == .recording)
        try await expectBuffering(model, h)

        // Recording, but the recorder was left suspended (e.g. events handled out of order).
        model.recorder.suspend()
        h.scheduler.advance(by: AppModel.statusInterval)
        await model.waitForCapture()
        #expect(model.phase == .recording)
        try await expectBuffering(model, h)

        // The session came back by itself between two backoff attempts.
        h.source.setResumeFailures(1_000)
        h.source.simulateRuntimeError(sessionStops: true)
        await model.waitForCapture()
        #expect(model.recovery != nil)
        h.source.setRunStateSilently(.running)
        h.scheduler.advance(by: AppModel.statusInterval)
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(model.recovery == nil)
        let resumes = h.source.resumeCount
        h.scheduler.advance(by: 60)
        await model.waitForCapture()
        #expect(h.source.resumeCount == resumes, "the recovery's remaining attempts were dropped")
        #expect(model.phase == .recording)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Safety net: a source interrupted or stopped without telling us is paused, then restarted")
    func safetyNetPausesAndRestartsSilentStop() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startRecording(h)

        h.source.setRunStateSilently(.interrupted)
        h.scheduler.advance(by: AppModel.statusInterval)
        await model.waitForCapture()
        #expect(model.phase == .paused(InterruptionReason.other("the camera was interrupted").message))
        #expect(model.recorder.status().isSuspended)
        #expect(model.recovery == nil, "iOS ends interruptions itself")

        h.source.setRunStateSilently(.stopped)
        h.source.setResumeFailures(1)
        h.scheduler.advance(by: AppModel.statusInterval)
        await model.waitForCapture()
        #expect(model.phase == .paused(CaptureRecoveryReason.sourceStopped.pausedMessage))
        #expect(model.recovery?.reason == .sourceStopped)
        #expect(h.source.resumeCount == 1)

        h.scheduler.advance(by: RestartBackoff.delays[1])
        await model.waitForCapture()
        #expect(h.source.resumeCount == 2)
        #expect(model.phase == .recording)
        #expect(model.recovery == nil)
        try await expectBuffering(model, h)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("The safety net does nothing while stopped, failed, or recording normally")
    func safetyNetLeavesConsistentStatesAlone() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await startRecording(h)
        h.scheduler.advance(by: 10)
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(h.source.resumeCount == 0)

        model.scenePhaseChanged(.background)
        await model.waitForCapture()
        h.source.setRunStateSilently(.running) // even a source that claims to run
        h.scheduler.advance(by: 10)
        await model.waitForCapture()
        #expect(model.phase == .paused(InterruptionReason.backgrounded.message))
        #expect(model.recorder.status().isSuspended)
        #expect(h.source.resumeCount == 0)

        h.source.setStartError(.configurationFailed("busy"))
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        #expect(model.phase == .failed("Couldn't start the camera: busy"))
        h.scheduler.advance(by: 10)
        await model.waitForCapture()
        #expect(model.phase == .failed("Couldn't start the camera: busy"))
        #expect(h.source.resumeCount == 0)
        model.stop()
        await model.waitForPipeline()
    }
}

@Suite("Capture recovery policy")
struct CaptureRecoveryPolicyTests {

    @Test("Backoff: immediate first attempt, growing delays, then a spent budget")
    func backoffSchedule() {
        var backoff = RestartBackoff()
        var delays: [TimeInterval] = []
        while let delay = backoff.nextDelay() { delays.append(delay) }
        #expect(delays == RestartBackoff.delays)
        #expect(delays.first == 0)
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 < $1 }, "never shrinks")
        #expect(delays.reduce(0, +) <= 60, "gives up within a minute")
        #expect(backoff.isExhausted)
        #expect(backoff.nextDelay() == nil)
        #expect(backoff.attempts == RestartBackoff.delays.count)
    }

    @MainActor
    @Test("Fake scheduler runs due actions in time order, including ones they schedule")
    func fakeSchedulerOrder() {
        @MainActor final class Log { var entries: [String] = [] }
        let scheduler = FakeDelayScheduler()
        let log = Log()
        scheduler.schedule(after: 2) { log.entries.append("b") }
        scheduler.schedule(after: 1) {
            log.entries.append("a")
            scheduler.schedule(after: 0.5) { log.entries.append("a+0.5") }
        }
        scheduler.schedule(after: 5) { log.entries.append("late") }
        scheduler.advance(by: 0.99)
        #expect(log.entries.isEmpty)
        scheduler.advance(by: 1.01)
        #expect(log.entries == ["a", "a+0.5", "b"])
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(by: 3)
        #expect(log.entries == ["a", "a+0.5", "b", "late"])
    }

    @Test("resumeRunning: true and 'running again' whenever the source runs afterwards, else false and silent")
    func resumeRunningContract() async throws {
        let source = SyntheticFrameSource(format: .init(width: 64, height: 64, frameRate: 15, audioEnabled: false),
                                          mode: .manual)
        let events = Locked<[FrameSourceEvent]>([])
        source.setEventHandler { event in events.withLock { $0.append(event) } }
        #expect(source.runState == .stopped)
        _ = try await source.start(CaptureConfiguration(preset: .lowest, audioEnabled: false, camera: .back))
        #expect(source.runState == .running)

        // (a) still running after the error.
        source.simulateRuntimeError("e1", sessionStops: false)
        #expect(source.runState == .running)
        let stillRunning = await source.resumeRunning()
        #expect(stillRunning)

        // (b) stopped; the first restart fails, the second works.
        source.simulateRuntimeError("e2", sessionStops: true)
        #expect(source.runState == .stopped)
        source.setResumeFailures(1)
        let failed = await source.resumeRunning()
        #expect(!failed)
        let restarted = await source.resumeRunning()
        #expect(restarted)
        #expect(source.runState == .running)

        // Interrupted: iOS resumes it, not us.
        source.simulate(.interrupted(.cameraInUseByAnotherApp))
        #expect(source.runState == .interrupted)
        let whileInterrupted = await source.resumeRunning()
        #expect(!whileInterrupted)
        source.simulate(.interruptionEnded)
        #expect(source.runState == .running)

        #expect(events.current == [
            .interrupted(.runtimeError("e1")), .interruptionEnded,
            .interrupted(.runtimeError("e2")), .interruptionEnded,
            .interrupted(.cameraInUseByAnotherApp), .interruptionEnded,
        ])
        #expect(source.resumeCount == 4)
        await source.stop()
        #expect(source.runState == .stopped)
    }
}
