import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo

/// Generates timestamped test-pattern video frames and silent PCM audio.
///
/// * `.realTime`: a timer emits frames at the configured rate on the host clock (Simulator, `-UITestMode`).
/// * `.manual`: nothing runs by itself; tests call `generate(seconds:)`, which emits frames
///   back-to-back with synthetic timestamps, as fast as the sink accepts them.
final class SyntheticFrameSource: FrameSource, @unchecked Sendable {
    // @unchecked: mutable state is only touched on `queue`; handlers live in `Locked` boxes.

    struct Format: Equatable, Sendable {
        var width: Int
        var height: Int
        var frameRate: Int
        var audioEnabled: Bool

        /// Small portrait frames: the CI Simulator has no hardware encoder.
        static let uiTest = Format(width: 360, height: 640, frameRate: 30, audioEnabled: true)
    }

    enum Mode: Sendable { case realTime, manual }

    private struct WeakSink { weak var sink: (any SampleSink)? }

    let mode: Mode
    /// When true, `start(_:)` takes frame rate and audio from the capture configuration.
    let followsConfiguration: Bool
    private let clock: MediaClock
    private let queue = DispatchQueue(label: "RewindCam.SyntheticFrameSource", qos: .userInitiated)
    private let sinkBox = Locked(WeakSink())
    private let eventBox = Locked<(@Sendable (FrameSourceEvent) -> Void)?>(nil)
    private let previewBox = Locked<(@Sendable (UncheckedSendable<CGImage>) -> Void)?>(nil)

    // Queue-confined state.
    private var format: Format
    private var pool: CVPixelBufferPool?
    private var poolSize: (Int, Int) = (0, 0)
    private var audioFormat: CMAudioFormatDescription?
    private var timer: DispatchSourceTimer?
    private var timelineStarted = false
    private var videoBase = CMTime.zero
    private var videoCount: Int64 = 0
    private var audioBase = CMTime.zero
    private var audioCount: Int64 = 0
    private var framesDrawn: Int64 = 0
    private var font: CTFont?
    /// Set by `start(_:)`. True before any start, so a source fed straight into a recorder (the
    /// recorder tests) emits audio whenever its format has it.
    private var emitsAudio = true
    private var audioFailure: AudioUnavailableReason?
    private var startError: FrameSourceError?
    private var starts = 0
    /// What `runState` reports; follows start/stop and the simulated events (issue #4).
    private let stateBox = Locked(CaptureRunState.stopped) // a lock, so the main actor never waits on `queue`
    private var resumeFailuresLeft = 0
    private var resumes = 0
    /// Video frames are produced on the timeline but never reach the sink (issue #9); audio still does.
    private var videoWithheld = false
    /// The next successful `start(_:)` lets video through again (`stallVideoOnce`).
    private var videoReleasedOnStart = false
    private var stallAfterFirstStart: TimeInterval?
    /// `holdNextStart()`: a start waiting like one behind a permission prompt (issue #15).
    private let startGate = Locked(StartGate())

    private struct StartGate {
        var holdNext = false
        /// A held start is waiting (or about to wait) for `releaseHeldStart()`.
        var held = false
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
        var arrivals: [CheckedContinuation<Void, Never>] = []
    }

    static let audioSampleRate: Int32 = 48_000
    static let audioChunk = 1_024

    init(format: Format, mode: Mode, clock: MediaClock = HostMediaClock(), followsConfiguration: Bool = false) {
        self.format = format
        self.mode = mode
        self.clock = clock
        self.followsConfiguration = followsConfiguration
    }

    // MARK: FrameSource

    func setSink(_ sink: SampleSink?) { sinkBox.withLock { $0.sink = sink } }
    func setEventHandler(_ handler: (@Sendable (FrameSourceEvent) -> Void)?) { eventBox.withLock { $0 = handler } }
    func setPreviewHandler(_ handler: (@Sendable (UncheckedSendable<CGImage>) -> Void)?) {
        previewBox.withLock { $0 = handler }
    }

    var captureSession: AVCaptureSession? { nil }

    func supportedResolutions(for camera: CameraPosition) -> [VideoResolution] { VideoResolution.allCases }

    /// Like `CameraFrameSource`, audio is delivered only when the configuration asks for it and the
    /// (simulated) microphone is usable; the result says which.
    func start(_ configuration: CaptureConfiguration) async throws -> ActiveCapture {
        await passStartGate()
        return try queue.sync { () throws -> ActiveCapture in
            starts += 1
            if let startError {
                // Like a camera that can't start: nothing runs afterwards.
                timer?.cancel()
                timer = nil
                timelineStarted = false
                stateBox.withLock { $0 = .stopped }
                throw startError
            }
            if followsConfiguration {
                format.frameRate = configuration.preset.frameRate.rawValue
                format.audioEnabled = configuration.audioEnabled
            }
            let capture = activeCapture(for: configuration)
            if videoReleasedOnStart {
                videoWithheld = false
                videoReleasedOnStart = false
            }
            if let delay = stallAfterFirstStart {
                stallAfterFirstStart = nil
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.videoWithheld = true
                    self?.videoReleasedOnStart = true
                }
            }
            emitsAudio = capture.audioCaptured
            timelineStarted = false
            stateBox.withLock { $0 = .running }
            startTimerIfRealTime()
            return capture
        }
    }

    var runState: CaptureRunState { stateBox.current }

    /// Like `CameraFrameSource.resumeRunning()`: running already → true (case (a) of issue #4);
    /// interrupted → false; stopped → runs again unless `setResumeFailures` says this attempt fails.
    func resumeRunning() async -> Bool {
        let running = queue.sync { () -> Bool in
            resumes += 1
            switch stateBox.current {
            case .running:
                return true
            case .interrupted:
                return false
            case .stopped:
                if resumeFailuresLeft > 0 {
                    resumeFailuresLeft -= 1
                    return false
                }
                stateBox.withLock { $0 = .running }
                startTimerIfRealTime()
                return true
            }
        }
        if running { eventBox.current?(.interruptionEnded) }
        return running
    }

    /// Makes the next `count` `resumeRunning()` calls fail, like a session that won't start while media
    /// services are still resetting (issue #4, case (b)).
    func setResumeFailures(_ count: Int) {
        queue.sync { resumeFailuresLeft = count }
    }

    /// How many times `resumeRunning()` was called (tests).
    var resumeCount: Int { queue.sync { resumes } }

    /// Simulates a denied or broken microphone (nil: usable). Applies from the next `start(_:)`, like a
    /// permission change on a device. Tests and `-UITestDenyMicrophone` use it.
    func setAudioUnavailable(_ reason: AudioUnavailableReason?) {
        queue.sync { audioFailure = reason }
    }

    /// Makes the next `start(_:)` calls throw `error` (nil: start normally), like a denied camera
    /// (`.cameraAccessDenied`) or one that can't be configured. Tests and `-UITestDenyCamera` use it.
    func setStartError(_ error: FrameSourceError?) {
        queue.sync { startError = error }
    }

    /// How many times `start(_:)` was called, including failed starts (tests).
    var startCount: Int { queue.sync { starts } }

    /// Makes the next `start(_:)` wait, before it does anything, until `releaseHeldStart()`: a camera
    /// permission prompt the user hasn't answered, or a slow session start (issue #15). What it does
    /// once released follows `setStartError` at that moment (a denial answered late, for example).
    func holdNextStart() {
        startGate.withLock { $0.holdNext = true }
    }

    /// Returns once a start held by `holdNextStart()` is waiting.
    func waitForHeldStart() async {
        await withCheckedContinuation { (arrived: CheckedContinuation<Void, Never>) in
            let now = startGate.withLock { gate -> Bool in
                if gate.held { return true }
                gate.arrivals.append(arrived)
                return false
            }
            if now { arrived.resume() }
        }
    }

    /// Lets the held start go on (no effect if none is held).
    func releaseHeldStart() {
        let waiter = startGate.withLock { gate -> CheckedContinuation<Void, Never>? in
            guard gate.held else { return nil }
            gate.held = false
            if let waiter = gate.waiter {
                gate.waiter = nil
                return waiter
            }
            gate.released = true // it hasn't reached `withCheckedContinuation` yet
            return nil
        }
        waiter?.resume()
    }

    /// True while a held start waits for `releaseHeldStart()`.
    var isHoldingStart: Bool { startGate.current.held }

    private func passStartGate() async {
        let arrivals = startGate.withLock { gate -> [CheckedContinuation<Void, Never>]? in
            guard gate.holdNext else { return nil }
            gate.holdNext = false
            gate.held = true
            gate.released = false
            defer { gate.arrivals = [] }
            return gate.arrivals
        }
        guard let arrivals else { return }
        for arrived in arrivals { arrived.resume() }
        await withCheckedContinuation { (go: CheckedContinuation<Void, Never>) in
            let now = startGate.withLock { gate -> Bool in
                if gate.released {
                    gate.released = false
                    return true
                }
                gate.waiter = go
                return false
            }
            if now { go.resume() }
        }
    }

    func stop() async {
        queue.sync {
            timer?.cancel()
            timer = nil
            timelineStarted = false
            stateBox.withLock { $0 = .stopped }
        }
    }

    // MARK: Manual driving (tests)

    /// Emits `seconds` of interleaved video/audio continuing from the current timeline.
    func generate(seconds: Double) {
        queue.sync {
            startTimelineIfNeeded()
            let end = nextVideoTime + CMTime(seconds: seconds, preferredTimescale: 90_000)
            emit(until: end)
        }
    }

    /// Leaves a gap in the timeline (e.g. time spent interrupted).
    func skip(seconds: Double) {
        queue.sync {
            startTimelineIfNeeded()
            let gap = CMTime(seconds: seconds, preferredTimescale: 90_000)
            videoBase = nextVideoTime + gap
            videoCount = 0
            audioBase = nextAudioTime + gap
            audioCount = 0
        }
    }

    /// Timestamp of the next video frame to be emitted.
    var nextVideoPTS: CMTime { queue.sync { nextVideoTime } }

    /// Emits `event` as a real session would, and updates `runState` to match: an interruption leaves
    /// the source `.interrupted`, its end `.running`. A runtime error doesn't change `runState`; use
    /// `simulateRuntimeError(_:sessionStops:)` for that.
    func simulate(_ event: FrameSourceEvent) {
        queue.sync {
            switch event {
            case .interrupted(.runtimeError): break
            case .interrupted: stateBox.withLock { $0 = .interrupted }
            case .interruptionEnded: stateBox.withLock { $0 = .running }
            }
        }
        eventBox.current?(event)
    }

    /// A capture-session runtime error (issue #4). `sessionStops: false` is case (a): the session keeps
    /// running. `true`: it stops (no more frames in real-time mode) until `resumeRunning()` restarts it.
    func simulateRuntimeError(_ why: String = "simulated runtime error", sessionStops: Bool) {
        queue.sync {
            guard sessionStops else { return }
            stateBox.withLock { $0 = .stopped }
            timer?.cancel()
            timer = nil
        }
        eventBox.current?(.interrupted(.runtimeError(why)))
    }

    /// Changes what `runState` reports without emitting anything: a session whose notification never
    /// arrived (the status-loop safety net's case, issue #4).
    func setRunStateSilently(_ newState: CaptureRunState) {
        queue.sync { stateBox.withLock { $0 = newState } }
    }

    /// A camera that still "runs" but stops delivering video (issue #9, the frame watchdog's case):
    /// while `withheld`, video frames keep their place on the timeline but never reach the sink, while
    /// audio (if any) still does. `runState` is unchanged and no event is emitted. Survives restarts,
    /// like a broken capture pipeline; pass `false` to let frames through again.
    func withholdVideo(_ withheld: Bool) {
        queue.sync { videoWithheld = withheld }
    }

    /// `-UITestStallVideo`: `seconds` after the next successful start, video stops reaching the sink
    /// (as with `withholdVideo(true)`) until the start after that, which is what the frame watchdog's
    /// restart does. A stall that one restart cures.
    func stallVideoOnce(afterStartBy seconds: TimeInterval) {
        queue.sync { stallAfterFirstStart = seconds }
    }

    // MARK: - Private (on `queue`)

    private var frameDuration: CMTime { CMTime(value: 1, timescale: CMTimeScale(format.frameRate)) }
    private var nextVideoTime: CMTime { videoBase + CMTime(value: videoCount, timescale: CMTimeScale(format.frameRate)) }
    private var nextAudioTime: CMTime {
        audioBase + CMTime(value: audioCount * Int64(Self.audioChunk), timescale: Self.audioSampleRate)
    }

    private func activeCapture(for configuration: CaptureConfiguration) -> ActiveCapture {
        guard configuration.audioEnabled else { return ActiveCapture(audioCaptured: false, audioUnavailable: nil) }
        if let audioFailure { return ActiveCapture(audioCaptured: false, audioUnavailable: audioFailure) }
        guard format.audioEnabled else {
            return ActiveCapture(audioCaptured: false, audioUnavailable: .microphoneUnavailable("this source has no audio"))
        }
        return ActiveCapture(audioCaptured: true, audioUnavailable: nil)
    }

    private func startTimerIfRealTime() {
        guard mode == .realTime else { return }
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(format.frameRate)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func startTimelineIfNeeded() {
        guard !timelineStarted else { return }
        timelineStarted = true
        var now = clock.now()
        // Never go backwards after a stop/start (a manual clock may not have moved).
        let resumeAt = nextVideoTime
        if (videoCount > 0 || videoBase != .zero), resumeAt > now { now = resumeAt }
        videoBase = now
        audioBase = now
        videoCount = 0
        audioCount = 0
    }

    private func tick() {
        startTimelineIfNeeded()
        let now = clock.now()
        // If we fell far behind (debugger, app stall), jump instead of bursting.
        if (now - nextVideoTime).seconds > 0.5 {
            videoBase = now
            videoCount = 0
            audioBase = now
            audioCount = 0
        }
        emit(until: now + CMTime(value: 1, timescale: 1_000))
    }

    /// Emits all samples with PTS < `end`, in timestamp order.
    private func emit(until end: CMTime) {
        while true {
            let v = nextVideoTime
            let a = nextAudioTime
            let audioDue = format.audioEnabled && emitsAudio && a < end
            let videoDue = v < end
            if !audioDue && !videoDue { break }
            if videoDue && (!audioDue || v <= a) {
                if !videoWithheld, let sb = makeVideoSample(pts: v) {
                    sinkBox.current.sink?.consume(sb, kind: .video)
                }
                videoCount += 1
            } else {
                if let sb = makeAudioSample(pts: a) {
                    sinkBox.current.sink?.consume(sb, kind: .audio)
                }
                audioCount += 1
            }
        }
    }

    private func makePool() -> CVPixelBufferPool? {
        if let pool, poolSize == (format.width, format.height) { return pool }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: format.width,
            kCVPixelBufferHeightKey as String: format.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
        pool = newPool
        poolSize = (format.width, format.height)
        return newPool
    }

    private func makeVideoSample(pts: CMTime) -> CMSampleBuffer? {
        guard let pool = makePool() else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: format.width, height: format.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            drawPattern(in: ctx, pts: pts)
            let previewEvery = Int64(max(1, format.frameRate / 4))
            if mode == .realTime, framesDrawn % previewEvery == 0,
               let handler = previewBox.current, let image = ctx.makeImage() {
                handler(UncheckedSendable(image))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        framesDrawn += 1

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &formatDescription)
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: formatDescription, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        return sample
    }

    private func drawPattern(in ctx: CGContext, pts: CMTime) {
        let w = CGFloat(format.width)
        let h = CGFloat(format.height)
        // Layout (CG origin is bottom-left): colour bars on top, a dark band below holding
        // the moving box and the timestamp, kept in the middle so on-screen controls don't cover it.
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
            (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75), (0.1, 0.1, 0.1),
        ]
        let barWidth = w / CGFloat(bars.count)
        let bandTop = h * 0.55
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i) * barWidth, y: bandTop, width: barWidth + 1, height: h - bandTop))
        }
        ctx.setFillColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: bandTop))

        // Motion: a box sweeping once per second, so dropped frames are visible.
        let fps = Int64(format.frameRate)
        let phase = CGFloat(videoCount % fps) / CGFloat(fps)
        let box = min(w, h) * 0.08
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: w * 0.15 + phase * (w * 0.7 - box), y: h * 0.42, width: box, height: box))

        // Timestamp text.
        let size = max(8, min(w, h) * 0.06)
        if font == nil || CTFontGetSize(font!) != size {
            font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        }
        let seconds = pts.seconds
        let text = String(format: "SYNTHETIC %.2f s", seconds.truncatingRemainder(dividingBy: 100_000))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font!,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.85, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (w - CGFloat(textWidth)) / 2, y: h * 0.34)
        CTLineDraw(line, ctx)
    }

    private func makeAudioSample(pts: CMTime) -> CMSampleBuffer? {
        if audioFormat == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(Self.audioSampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &audioFormat)
        }
        guard let audioFormat else { return nil }
        let frames = Self.audioChunk
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
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }
}
