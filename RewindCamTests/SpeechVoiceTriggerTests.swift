import AVFoundation
import Foundation
import Speech
import Testing
@testable import RewindCam

/// Stands in for `SFSpeechRecognizer`: records every session it starts and lets the test
/// deliver that session's callbacks (partials, final results, the error that follows `cancel()`).
final class FakeRecognitionEngine: RecognitionEngine, @unchecked Sendable {
    // @unchecked: `sessionsBox` is Locked; the other properties are immutable.
    final class Session: RecognitionSession, @unchecked Sendable {
        // @unchecked: `flags` is Locked; the other properties are immutable.
        private let onUpdate: @Sendable (RecognitionUpdate) -> Void
        private let errorOnCancel: Bool
        private let flags = Locked((appended: 0, endedAudio: false, cancelled: false))

        init(errorOnCancel: Bool, onUpdate: @escaping @Sendable (RecognitionUpdate) -> Void) {
            self.errorOnCancel = errorOnCancel
            self.onUpdate = onUpdate
        }

        var appended: Int { flags.current.appended }
        var endedAudio: Bool { flags.current.endedAudio }
        var cancelled: Bool { flags.current.cancelled }

        func append(_ sampleBuffer: CMSampleBuffer) { flags.withLock { $0.appended += 1 } }
        func endAudio() { flags.withLock { $0.endedAudio = true } }
        func cancel() {
            flags.withLock { $0.cancelled = true }
            // Like the real task, a cancelled session reports a cancellation error,
            // here synchronously, from inside cancel().
            if errorOnCancel { onUpdate(RecognitionUpdate(failed: true)) }
        }

        func deliver(_ update: RecognitionUpdate) { onUpdate(update) }
        func say(_ text: String, isFinal: Bool = false) { onUpdate(RecognitionUpdate(transcript: text, isFinal: isFinal)) }
    }

    let isAvailable: Bool
    private let errorOnCancel: Bool
    private let sessionsBox = Locked<[Session]>([])

    init(isAvailable: Bool = true, errorOnCancel: Bool = false) {
        self.isAvailable = isAvailable
        self.errorOnCancel = errorOnCancel
    }

    var sessions: [Session] { sessionsBox.current }

    func startSession(onUpdate: @escaping @Sendable (RecognitionUpdate) -> Void) -> (any RecognitionSession)? {
        guard isAvailable else { return nil }
        let session = Session(errorOnCancel: errorOnCancel, onUpdate: onUpdate)
        sessionsBox.withLock { $0.append(session) }
        return session
    }
}

@Suite("Speech voice trigger: one recognition task at a time")
struct SpeechVoiceTriggerTests {
    private func makeTrigger(_ engine: FakeRecognitionEngine, clock: FakeWallClock = FakeWallClock())
        -> (SpeechVoiceTrigger, Locked<Int>) {
        let trigger = SpeechVoiceTrigger(engine: engine, clock: clock)
        let fired = Locked(0)
        trigger.start { fired.withLock { $0 += 1 } }
        return (trigger, fired)
    }

    @Test("Late callbacks from a cancelled task don't cancel or replace the current task")
    func staleCallbacksAreIgnored() {
        let engine = FakeRecognitionEngine()
        let (trigger, fired) = makeTrigger(engine)
        #expect(engine.sessions.count == 1)
        let a = engine.sessions[0]

        // A legitimate reason to recycle: the current task reports an error.
        a.deliver(RecognitionUpdate(failed: true))
        #expect(engine.sessions.count == 2)
        #expect(a.endedAudio && a.cancelled)
        let b = engine.sessions[1]

        // A's cancellation error and the final result from endAudio() arrive afterwards.
        a.deliver(RecognitionUpdate(failed: true))
        a.say("something else", isFinal: true)
        a.deliver(RecognitionUpdate(transcript: "something else", isFinal: true, failed: true))
        #expect(engine.sessions.count == 2, "a stale callback must not start another task")
        #expect(!b.cancelled && !b.endedAudio, "a stale callback must not touch the current task")

        // B's own final result still recycles it, exactly once.
        b.say("hello", isFinal: true)
        #expect(engine.sessions.count == 3)
        #expect(b.cancelled)
        #expect(!engine.sessions[2].cancelled)
        #expect(fired.current == 0)
        trigger.stop()
    }

    @Test("A cancellation error delivered from inside cancel() doesn't start a restart loop")
    func synchronousCancellationErrorDoesNotLoop() {
        let engine = FakeRecognitionEngine(errorOnCancel: true)
        let (trigger, fired) = makeTrigger(engine)
        engine.sessions[0].deliver(RecognitionUpdate(failed: true))
        #expect(engine.sessions.count == 2)
        #expect(engine.sessions[0].cancelled)
        #expect(!engine.sessions[1].cancelled)

        trigger.stop()
        #expect(engine.sessions.count == 2, "stop doesn't start a new task")
        #expect(engine.sessions[1].cancelled)
        engine.sessions[1].say("save that", isFinal: true)
        #expect(engine.sessions.count == 2)
        #expect(fired.current == 0)
    }

    @Test("The phrase fires once; late partials from the replaced task neither fire nor restart")
    func phraseFiresOnce() {
        let clock = FakeWallClock()
        let engine = FakeRecognitionEngine()
        let (trigger, fired) = makeTrigger(engine, clock: clock)
        let a = engine.sessions[0]

        a.say("ok save")
        #expect(fired.current == 0)
        #expect(engine.sessions.count == 1, "partials without the phrase don't recycle")

        a.say("ok save that")
        #expect(fired.current == 1)
        #expect(a.cancelled, "the transcript is cleared after a trigger")
        #expect(engine.sessions.count == 2)
        let b = engine.sessions[1]

        // The old task keeps reporting the phrase for a while after it was cancelled.
        a.say("ok save that now")
        clock.advance(by: 10) // past the cooldown: still stale, so still ignored
        a.say("ok save that now", isFinal: true)
        a.deliver(RecognitionUpdate(failed: true))
        #expect(fired.current == 1)
        #expect(engine.sessions.count == 2)
        #expect(!b.cancelled)

        // The current task hearing the phrase fires again.
        b.say("save this")
        #expect(fired.current == 2)
        #expect(engine.sessions.count == 3)

        // Within the cooldown the phrase doesn't fire, but the transcript is still cleared.
        clock.advance(by: 1)
        engine.sessions[2].say("save that")
        #expect(fired.current == 2)
        #expect(engine.sessions.count == 4)
        trigger.stop()
    }

    @Test("The 50 s recycle creates exactly one new task")
    func periodicRecycleCreatesOneTask() throws {
        let clock = FakeWallClock()
        let engine = FakeRecognitionEngine()
        let (trigger, fired) = makeTrigger(engine, clock: clock)
        let sample = try #require(makeSilentAudioSample())
        let a = engine.sessions[0]

        for _ in 0..<3 { trigger.consume(sample, kind: .audio) }
        trigger.consume(sample, kind: .video)
        #expect(a.appended == 3, "only audio reaches the recogniser")

        clock.advance(by: 49)
        trigger.consume(sample, kind: .audio)
        #expect(engine.sessions.count == 1)

        clock.advance(by: 2)
        trigger.consume(sample, kind: .audio)
        #expect(a.appended == 5)
        #expect(a.endedAudio && a.cancelled)
        #expect(engine.sessions.count == 2)
        let b = engine.sessions[1]

        // The recycled task reports its final result and cancellation afterwards.
        a.say("", isFinal: true)
        a.deliver(RecognitionUpdate(failed: true))
        #expect(engine.sessions.count == 2)
        #expect(!b.cancelled)

        trigger.consume(sample, kind: .audio)
        trigger.consume(sample, kind: .audio)
        #expect(b.appended == 2)
        #expect(a.appended == 5)
        #expect(engine.sessions.count == 2)

        // The new task's 50 s are counted from its own start.
        clock.advance(by: 49)
        trigger.consume(sample, kind: .audio)
        #expect(engine.sessions.count == 2)
        clock.advance(by: 2)
        trigger.consume(sample, kind: .audio)
        #expect(engine.sessions.count == 3)
        #expect(b.cancelled)
        #expect(fired.current == 0)
        trigger.stop()
    }

    @Test("After stop, the old task's callbacks and audio are ignored")
    func stopIgnoresLateCallbacks() throws {
        let engine = FakeRecognitionEngine()
        let (trigger, fired) = makeTrigger(engine)
        let sample = try #require(makeSilentAudioSample())
        let a = engine.sessions[0]
        trigger.stop()
        #expect(a.endedAudio && a.cancelled)

        a.say("save that")
        a.deliver(RecognitionUpdate(failed: true))
        trigger.consume(sample, kind: .audio)
        #expect(fired.current == 0)
        #expect(engine.sessions.count == 1)
        #expect(a.appended == 0)

        // Starting again works normally.
        trigger.start { fired.withLock { $0 += 1 } }
        #expect(engine.sessions.count == 2)
        engine.sessions[1].say("save that")
        #expect(fired.current == 1)
        trigger.stop()
    }

    @Test("Without on-device recognition nothing starts")
    func unavailableEngine() throws {
        let engine = FakeRecognitionEngine(isAvailable: false)
        let (trigger, fired) = makeTrigger(engine)
        let sample = try #require(makeSilentAudioSample())
        #expect(!trigger.isAvailable)
        trigger.consume(sample, kind: .audio)
        #expect(engine.sessions.isEmpty)
        #expect(fired.current == 0)
        trigger.stop()
    }

    @Test("Recognition requests are on-device only")
    func requestIsOnDevice() {
        let request = SpeechRecognitionEngine.makeRequest()
        #expect(request.requiresOnDeviceRecognition)
        #expect(request.shouldReportPartialResults)
        #expect(request.contextualStrings == VoicePhrase.phrases)
    }
}

/// A short buffer of 16 kHz mono silence.
private func makeSilentAudioSample() -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
        mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                   magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                   formatDescriptionOut: &format)
    guard let format else { return nil }
    let frames = 160
    let length = frames * 2
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                       blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                       offsetToData: 0, dataLength: length,
                                       flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    guard let block else { return nil }
    CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    var sample: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample)
    return sample
}
