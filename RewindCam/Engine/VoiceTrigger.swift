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

final class SpeechVoiceTrigger: VoiceTrigger, @unchecked Sendable {
    // @unchecked: mutable state lives in `state` (Locked); SFSpeech objects are used under it.
    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var onTrigger: (@Sendable () -> Void)?
        var startedAt = Date.distantPast
        var lastTrigger = Date.distantPast
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let state = Locked(State())
    /// Recognition requests are recycled periodically to keep memory flat in long sessions.
    private let maxTaskDuration: TimeInterval = 50
    private let cooldown: TimeInterval = 3

    var isAvailable: Bool { recognizer?.supportsOnDeviceRecognition == true }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    func start(onTrigger: @escaping @Sendable () -> Void) {
        state.withLock { $0.onTrigger = onTrigger }
        beginTask()
    }

    func stop() {
        let old = state.withLock { s -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            defer { s = State() }
            return (s.request, s.task)
        }
        old.0?.endAudio()
        old.1?.cancel()
    }

    func consume(_ sampleBuffer: CMSampleBuffer, kind: MediaKind) {
        guard kind == .audio else { return }
        let (request, expired) = state.withLock { s in
            (s.request, Date().timeIntervalSince(s.startedAt) > maxTaskDuration)
        }
        request?.appendAudioSampleBuffer(sampleBuffer)
        if expired, request != nil { restart() }
    }

    // MARK: - Private

    private func beginTask() {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true // never leaves the phone
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.contextualStrings = VoicePhrase.phrases
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result, VoicePhrase.matches(result.bestTranscription.formattedString) {
                self.fire()
            } else if error != nil || result?.isFinal == true {
                self.restart()
            }
        }
        state.withLock { s in
            s.request = request
            s.task = task
            s.startedAt = Date()
        }
    }

    private func fire() {
        let callback: (@Sendable () -> Void)? = state.withLock { s in
            guard Date().timeIntervalSince(s.lastTrigger) > cooldown else { return nil }
            s.lastTrigger = Date()
            return s.onTrigger
        }
        restart() // clear the transcript so the phrase can't fire twice
        callback?()
    }

    private func restart() {
        let (request, task, running) = state.withLock { s in
            defer { s.request = nil; s.task = nil }
            return (s.request, s.task, s.onTrigger != nil)
        }
        request?.endAudio()
        task?.cancel()
        if running { beginTask() }
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
