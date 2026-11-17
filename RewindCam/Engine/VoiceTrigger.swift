import AVFoundation
import Speech

/// Phrase matching, kept pure so it is unit-testable.
enum VoicePhrase {
    static let phrases = ["save that", "save this"]

    static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func matches(_ transcript: String) -> Bool {
        let t = " " + normalized(transcript) + " "
        return phrases.contains { t.contains(" \($0) ") }
    }
}

/// Listens for "save that". Fed with the capture session's own audio samples (no second mic session).
protocol VoiceTrigger: SampleSink {
    /// True only when on-device recognition is supported; we never fall back to the server.
    var isAvailable: Bool { get }
    func requestAuthorization() async -> Bool
    /// Starts listening. `onTrigger` runs when the phrase is heard. `onGiveUp` runs once if the trigger
    /// stops itself because recognition keeps failing (issue #36); it doesn't run after `stop()`.
    /// Either may run on any thread. A later `start` tries again from a fresh budget.
    func start(onTrigger: @escaping @Sendable () -> Void, onGiveUp: @escaping @Sendable () -> Void)
    func stop()
}

extension VoiceTrigger {
    func start(onTrigger: @escaping @Sendable () -> Void) { start(onTrigger: onTrigger, onGiveUp: {}) }
}

// MARK: - Recognition engine

/// One callback of a recognition task, reduced to what the trigger uses.
struct RecognitionUpdate: Sendable, Equatable {
    /// Best transcription so far (partial or final), if the callback carried a result.
    var transcript: String?
    var isFinal = false
    /// The callback carried an error (including the cancellation error that follows `cancel()`).
    var failed = false
}

/// One recognition request and its task. The task's callbacks belong to this session only.
protocol RecognitionSession: AnyObject, Sendable {
    func append(_ sampleBuffer: CMSampleBuffer)
    func endAudio()
    func cancel()
}

/// Creates recognition sessions. Behind a protocol so tests can deliver callbacks by hand.
protocol RecognitionEngine: Sendable {
    /// True only when on-device recognition is supported; we never fall back to the server.
    var isAvailable: Bool { get }
    /// True when the recogniser can take a request right now (`SFSpeechRecognizer.isAvailable`). It can
    /// be false for a while on a device that supports recognition; the trigger then backs off (#36).
    var isReady: Bool { get }
    /// Starts a new request and task; `onUpdate` receives every callback of that task.
    func startSession(onUpdate: @escaping @Sendable (RecognitionUpdate) -> Void) -> (any RecognitionSession)?
}

/// `SFSpeechRecognizer`-backed engine (en-US, on-device only).
final class SpeechRecognitionEngine: RecognitionEngine, @unchecked Sendable {
    // @unchecked: `recognizer` is immutable after init and is only asked to create tasks.
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    var isAvailable: Bool { recognizer?.supportsOnDeviceRecognition == true }
    var isReady: Bool { recognizer?.isAvailable == true }

    /// The request every session uses.
    static func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true // never leaves the phone
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.contextualStrings = VoicePhrase.phrases
        return request
    }

    func startSession(onUpdate: @escaping @Sendable (RecognitionUpdate) -> Void) -> (any RecognitionSession)? {
        guard let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { return nil }
        let request = Self.makeRequest()
        let task = recognizer.recognitionTask(with: request) { result, error in
            onUpdate(RecognitionUpdate(transcript: result?.bestTranscription.formattedString,
                                       isFinal: result?.isFinal == true,
                                       failed: error != nil))
        }
        return SpeechRecognitionSession(request: request, task: task)
    }
}

private final class SpeechRecognitionSession: RecognitionSession, @unchecked Sendable {
    // @unchecked: both references are immutable; the Speech objects are only messaged
    // (append / endAudio / cancel), exactly as the trigger did before this wrapper existed.
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let task: SFSpeechRecognitionTask

    init(request: SFSpeechAudioBufferRecognitionRequest, task: SFSpeechRecognitionTask) {
        self.request = request
        self.task = task
    }

    func append(_ sampleBuffer: CMSampleBuffer) { request.appendAudioSampleBuffer(sampleBuffer) }
    func endAudio() { request.endAudio() }
    func cancel() { task.cancel() }
}

// MARK: - Speech trigger

/// Listens for the phrase with on-device speech recognition.
///
/// Every recognition session gets a generation number, and its callbacks carry that number.
/// Only callbacks from the *current* generation may fire the trigger or recycle the session.
/// Late callbacks from a session that was already replaced (its cancellation error, the final
/// result produced by `endAudio()`, or partials still containing the phrase) are ignored.
/// Without this, a stale callback cancels the fresh session, whose own cancellation callback
/// then cancels the next one, in an endless loop.
///
/// **Sessions that keep failing (issue #36).** A session *fails* when it ends (an error or a final
/// callback) without having produced any transcript, less than `healthyRunTime` after it was
/// requested. A session that can't be started (the recogniser isn't ready, or `startSession` returns
/// nil) fails too, and so does one whose task ends before `beginSession` has stored it. Consecutive
/// failures are restarted on the `RestartBackoff` schedule: at once, then after 1, 2, 4, 8 and 15 s,
/// through the injected `DelayScheduler`. The failure after that gives up: the trigger stops, as after
/// `stop()`, and calls `onGiveUp` once. Any transcript refills the budget. Every other end (a final
/// result, an error after a transcript or after `healthyRunTime`, the 50 s recycle, a trigger) is
/// healthy and restarts at once, as before.
final class SpeechVoiceTrigger: VoiceTrigger, @unchecked Sendable {
    // @unchecked: mutable state lives in `state` (Locked); `engine`, `clock` and `scheduler` are
    // immutable, and `scheduler` is only used on the main actor.
    private struct State {
        /// Bumped whenever the current session is replaced or dropped.
        var generation: UInt64 = 0
        var session: (any RecognitionSession)?
        var onTrigger: (@Sendable () -> Void)?
        var onGiveUp: (@Sendable () -> Void)?
        /// When the current session was requested.
        var startedAt = Date.distantPast
        var lastTrigger = Date.distantPast
        /// True while `beginSession` waits for the engine, before the new session is stored.
        var starting = false
        /// The session being started already reported an error or final result (from inside
        /// `startSession`, or from another thread before it was stored).
        var endedWhileStarting = false
        /// The current session produced a transcript: the recogniser works.
        var heardSomething = false
        /// Restarts left for consecutive failed sessions.
        var backoff = RestartBackoff()
    }

    /// What follows the end of the current session.
    private enum Next {
        case nothing
        case restartNow
        /// Wait, then restart if `generation` is still current and has no session.
        case restart(after: TimeInterval, generation: UInt64)
        case giveUp((@Sendable () -> Void)?)
    }

    /// Recognition requests are recycled periodically to keep memory flat in long sessions.
    static let maxTaskDuration: TimeInterval = 50
    static let cooldown: TimeInterval = 3
    /// A session that ran this long isn't a failure, even without a transcript (a quiet room): only
    /// sessions that end quickly can loop (#36).
    static let healthyRunTime: TimeInterval = 10

    private let engine: any RecognitionEngine
    private let clock: any WallClock
    /// Backoff timers. nil: a `SystemDelayScheduler`, made on the main actor when needed.
    private let scheduler: UncheckedSendable<(any DelayScheduler)?>
    private let state = Locked(State())

    init(engine: any RecognitionEngine = SpeechRecognitionEngine(), clock: any WallClock = SystemWallClock(),
         scheduler: (any DelayScheduler)? = nil) {
        self.engine = engine
        self.clock = clock
        self.scheduler = UncheckedSendable(scheduler)
    }

    var isAvailable: Bool { engine.isAvailable }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// Without on-device recognition (`isAvailable` false) nothing starts and it gives up at once.
    func start(onTrigger: @escaping @Sendable () -> Void, onGiveUp: @escaping @Sendable () -> Void) {
        let supported = engine.isAvailable
        let old = state.withLock { s -> (any RecognitionSession)? in
            let old = s.session
            // A full budget. A pending backoff timer and any earlier session are stale from here on.
            s = supported ? State(generation: s.generation &+ 1, onTrigger: onTrigger, onGiveUp: onGiveUp)
                          : State(generation: s.generation &+ 1)
            return old
        }
        old?.endAudio()
        old?.cancel()
        if supported { beginSession() } else { onGiveUp() }
    }

    func stop() {
        let old = state.withLock { s -> (any RecognitionSession)? in
            let old = s.session
            // Keep the generation moving so the dropped session's callbacks (and timers) stay stale.
            s = State(generation: s.generation &+ 1)
            return old
        }
        old?.endAudio()
        old?.cancel()
    }

    func consume(_ sampleBuffer: CMSampleBuffer, kind: MediaKind) {
        guard kind == .audio else { return }
        let now = clock.now()
        let (current, generation, expired) = state.withLock { s in
            (s.session, s.generation, now.timeIntervalSince(s.startedAt) > Self.maxTaskDuration)
        }
        guard let session = current else { return }
        session.append(sampleBuffer)
        if expired { end(ifCurrent: generation) }
    }

    // MARK: - Private

    private func beginSession() {
        let now = clock.now()
        let next = state.withLock { s -> UInt64? in
            guard s.onTrigger != nil else { return nil }
            s.generation &+= 1
            s.session = nil
            s.startedAt = now
            s.starting = true
            s.endedWhileStarting = false
            s.heardSomething = false
            return s.generation
        }
        guard let generation = next else { return }
        // Not ready: don't ask for a session that can only fail; it counts as a failed one.
        let started: (any RecognitionSession)?
        if engine.isReady {
            started = engine.startSession { [weak self] update in self?.handle(update, generation: generation) }
        } else {
            started = nil
        }
        enum Outcome { case kept, stale, ended(Next) }
        let outcome = state.withLock { s -> Outcome in
            // stop() or another restart got in first: this session is already stale.
            guard s.generation == generation else { return .stale }
            s.starting = false
            guard started != nil, !s.endedWhileStarting else {
                return .ended(Self.sessionEnded(&s, at: now))
            }
            s.session = started
            return .kept
        }
        switch outcome {
        case .kept:
            return
        case .stale:
            started?.endAudio()
            started?.cancel()
        case .ended(let next):
            started?.endAudio()
            started?.cancel()
            proceed(next)
        }
    }

    private func handle(_ update: RecognitionUpdate, generation: UInt64) {
        if update.transcript != nil {
            // The recogniser works: this session's end isn't a failure, and the budget is full again.
            state.withLock { s in
                guard s.generation == generation else { return }
                s.heardSomething = true
                s.backoff = RestartBackoff()
            }
        }
        if let transcript = update.transcript, VoicePhrase.matches(transcript) {
            fire(generation: generation)
        } else if update.failed || update.isFinal {
            end(ifCurrent: generation)
        }
    }

    private func fire(generation: UInt64) {
        let now = clock.now()
        let outcome = state.withLock { s -> (current: Bool, callback: (@Sendable () -> Void)?) in
            guard s.generation == generation, s.session != nil else { return (false, nil) }
            guard now.timeIntervalSince(s.lastTrigger) > Self.cooldown else { return (true, nil) }
            s.lastTrigger = now
            return (true, s.onTrigger)
        }
        guard outcome.current else { return } // a late partial from a replaced session
        end(ifCurrent: generation) // clear the transcript so the phrase can't fire twice
        outcome.callback?()
    }

    /// Ends the session of `generation` and starts what follows, but only if it is still the current one.
    private func end(ifCurrent generation: UInt64) {
        let now = clock.now()
        let ended = state.withLock { s -> (session: any RecognitionSession, next: Next)? in
            guard s.generation == generation else { return nil }
            if s.starting {
                // Before `beginSession` stored it: that session ends there instead of receiving audio.
                s.endedWhileStarting = true
                return nil
            }
            guard let old = s.session else { return nil }
            return (old, Self.sessionEnded(&s, at: now))
        }
        guard let ended else { return }
        ended.session.endAudio()
        ended.session.cancel()
        proceed(ended.next)
    }

    /// Drops the current session (its callbacks are stale from here on) and decides what follows.
    /// A failure takes the next delay from the budget, or gives up once it is spent.
    private static func sessionEnded(_ s: inout State, at now: Date) -> Next {
        let failed = !s.heardSomething && now.timeIntervalSince(s.startedAt) < healthyRunTime
        s.session = nil
        s.starting = false
        s.endedWhileStarting = false
        s.generation &+= 1
        guard s.onTrigger != nil else { return .nothing }
        guard failed else {
            s.backoff = RestartBackoff()
            return .restartNow
        }
        guard let delay = s.backoff.nextDelay() else {
            let report = s.onGiveUp
            s = State(generation: s.generation) // stopped, as after stop()
            return .giveUp(report)
        }
        return delay <= 0 ? .restartNow : .restart(after: delay, generation: s.generation)
    }

    private func proceed(_ next: Next) {
        switch next {
        case .nothing: break
        case .restartNow: beginSession()
        case let .restart(delay, generation): scheduleRestart(after: delay, generation: generation)
        case .giveUp(let report): report?()
        }
    }

    private func scheduleRestart(after delay: TimeInterval, generation: UInt64) {
        let action: @MainActor @Sendable () -> Void = { [weak self] in self?.restart(ifWaiting: generation) }
        let scheduler = self.scheduler
        if Thread.isMainThread {
            // Recognition callbacks arrive on the main queue: schedule at once (tests rely on it).
            MainActor.assumeIsolated { Self.schedule(action, after: delay, on: scheduler.value) }
        } else {
            Task { @MainActor in Self.schedule(action, after: delay, on: scheduler.value) }
        }
    }

    @MainActor
    private static func schedule(_ action: @escaping @MainActor @Sendable () -> Void, after delay: TimeInterval,
                                 on scheduler: (any DelayScheduler)?) {
        (scheduler ?? SystemDelayScheduler()).schedule(after: delay, action)
    }

    /// A backoff timer fired: start the next session, unless `stop()` or `start` came first.
    private func restart(ifWaiting generation: UInt64) {
        let waiting = state.withLock { s in
            s.generation == generation && s.session == nil && !s.starting && s.onTrigger != nil
        }
        if waiting { beginSession() }
    }
}

/// Test double.
final class FakeVoiceTrigger: VoiceTrigger, @unchecked Sendable {
    private let state = Locked<(running: Bool, onTrigger: (@Sendable () -> Void)?, onGiveUp: (@Sendable () -> Void)?,
                                audioSamples: Int)>((false, nil, nil, 0))
    let isAvailable: Bool
    init(isAvailable: Bool = true) { self.isAvailable = isAvailable }
    var isRunning: Bool { state.current.running }
    var audioSamplesSeen: Int { state.current.audioSamples }
    func requestAuthorization() async -> Bool { true }
    func start(onTrigger: @escaping @Sendable () -> Void, onGiveUp: @escaping @Sendable () -> Void) {
        state.withLock { s in
            s.running = true
            s.onTrigger = onTrigger
            s.onGiveUp = onGiveUp
        }
    }
    func stop() { state.withLock { $0.running = false; $0.onTrigger = nil; $0.onGiveUp = nil } }
    func consume(_ sampleBuffer: CMSampleBuffer, kind: MediaKind) {
        if kind == .audio { state.withLock { $0.audioSamples += 1 } }
    }
    /// Simulates hearing "save that".
    func hear() { state.current.onTrigger?() }
    /// Simulates recognition failing until the trigger's budget is spent (#36): it stops and reports it.
    func giveUp() {
        let report = state.withLock { s -> (@Sendable () -> Void)? in
            let report = s.onGiveUp
            s.running = false
            s.onTrigger = nil
            s.onGiveUp = nil
            return report
        }
        report?()
    }
}

/// Fans one source out to the recorder and (optionally) the voice trigger.
final class SampleFanOut: SampleSink, @unchecked Sendable {
    // @unchecked: `tap` is behind a lock; `primary` is immutable.
    private struct WeakTap { weak var sink: (any SampleSink)? }
    let primary: SampleSink
    private let tapBox = Locked(WeakTap())

    init(primary: SampleSink) { self.primary = primary }

    func setTap(_ sink: SampleSink?) { tapBox.withLock { $0.sink = sink } }

    func consume(_ sampleBuffer: CMSampleBuffer, kind: MediaKind) {
        primary.consume(sampleBuffer, kind: kind)
        tapBox.current.sink?.consume(sampleBuffer, kind: kind)
    }
}
