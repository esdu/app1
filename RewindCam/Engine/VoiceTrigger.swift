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
    func start(onTrigger: @escaping @Sendable () -> Void)
    func stop()
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
    /// Starts a new request and task; `onUpdate` receives every callback of that task.
    func startSession(onUpdate: @escaping @Sendable (RecognitionUpdate) -> Void) -> (any RecognitionSession)?
}

/// `SFSpeechRecognizer`-backed engine (en-US, on-device only).
final class SpeechRecognitionEngine: RecognitionEngine, @unchecked Sendable {
    // @unchecked: `recognizer` is immutable after init and is only asked to create tasks.
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    var isAvailable: Bool { recognizer?.supportsOnDeviceRecognition == true }

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
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { return nil }
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
final class SpeechVoiceTrigger: VoiceTrigger, @unchecked Sendable {
    // @unchecked: mutable state lives in `state` (Locked); `engine` and `clock` are immutable.
    private struct State {
        /// Bumped whenever the current session is replaced or dropped.
        var generation: UInt64 = 0
        var session: (any RecognitionSession)?
        var onTrigger: (@Sendable () -> Void)?
        var startedAt = Date.distantPast
        var lastTrigger = Date.distantPast
    }

    /// Recognition requests are recycled periodically to keep memory flat in long sessions.
    static let maxTaskDuration: TimeInterval = 50
    static let cooldown: TimeInterval = 3

    private let engine: any RecognitionEngine
    private let clock: any WallClock
    private let state = Locked(State())

    init(engine: any RecognitionEngine = SpeechRecognitionEngine(), clock: any WallClock = SystemWallClock()) {
        self.engine = engine
        self.clock = clock
    }

    var isAvailable: Bool { engine.isAvailable }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    func start(onTrigger: @escaping @Sendable () -> Void) {
        state.withLock { $0.onTrigger = onTrigger }
        beginSession()
    }

    func stop() {
        let old = state.withLock { s -> (any RecognitionSession)? in
            let old = s.session
            // Keep the generation moving so the dropped session's callbacks stay stale.
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
        if expired { recycle(ifCurrent: generation) }
    }

    // MARK: - Private

    private func beginSession() {
        let next = state.withLock { s -> UInt64? in
            guard s.onTrigger != nil else { return nil }
            s.generation &+= 1
            s.session = nil
            return s.generation
        }
        guard let generation = next else { return }
        let started = engine.startSession { [weak self] update in
            self?.handle(update, generation: generation)
        }
        guard let session = started else { return }
        let now = clock.now()
        let kept = state.withLock { s -> Bool in
            // stop() or another restart got in first: this session is already stale.
            guard s.generation == generation else { return false }
            s.session = session
            s.startedAt = now
            return true
        }
        if !kept {
            session.endAudio()
            session.cancel()
        }
    }

    private func handle(_ update: RecognitionUpdate, generation: UInt64) {
        if let transcript = update.transcript, VoicePhrase.matches(transcript) {
            fire(generation: generation)
        } else if update.failed || update.isFinal {
            recycle(ifCurrent: generation)
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
        recycle(ifCurrent: generation) // clear the transcript so the phrase can't fire twice
        outcome.callback?()
    }

    /// Replaces the session, but only if `generation` is still the current one.
    private func recycle(ifCurrent generation: UInt64) {
        let replaced = state.withLock { s -> (session: any RecognitionSession, running: Bool)? in
            guard s.generation == generation, let old = s.session else { return nil }
            s.session = nil
            s.generation &+= 1 // from here on, `old`'s callbacks are stale
            return (old, s.onTrigger != nil)
        }
        guard case let (old, running)? = replaced else { return }
        old.endAudio()
        old.cancel()
        if running { beginSession() }
    }
}

/// Test double.
final class FakeVoiceTrigger: VoiceTrigger, @unchecked Sendable {
    private let state = Locked<(running: Bool, onTrigger: (@Sendable () -> Void)?, audioSamples: Int)>((false, nil, 0))
    let isAvailable: Bool
    init(isAvailable: Bool = true) { self.isAvailable = isAvailable }
    var isRunning: Bool { state.current.running }
    var audioSamplesSeen: Int { state.current.audioSamples }
    func requestAuthorization() async -> Bool { true }
    func start(onTrigger: @escaping @Sendable () -> Void) {
        state.withLock { s in
            s.running = true
            s.onTrigger = onTrigger
        }
    }
    func stop() { state.withLock { $0.running = false; $0.onTrigger = nil } }
    func consume(_ sampleBuffer: CMSampleBuffer, kind: MediaKind) {
        if kind == .audio { state.withLock { $0.audioSamples += 1 } }
    }
    /// Simulates hearing "save that".
    func hear() { state.current.onTrigger?() }
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
