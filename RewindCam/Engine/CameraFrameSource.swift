import AVFoundation
import CoreMedia

/// Real capture via AVCaptureSession. Video and audio are delivered on one serial queue,
/// so the recorder sees them in arrival order. Not exercised in CI (the Simulator has no camera).
final class CameraFrameSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    // @unchecked: the session graph is only mutated on `sessionQueue`; samples arrive on
    // `sampleQueue`; the sink and event handler are behind locks.

    private struct WeakSink { weak var sink: (any SampleSink)? }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "RewindCam.Camera.session")
    private let sampleQueue = DispatchQueue(label: "RewindCam.Camera.samples", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sinkBox = Locked(WeakSink())
    private let eventBox = Locked<(@Sendable (FrameSourceEvent) -> Void)?>(nil)
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            self?.emit(.interrupted(Self.map(reason)))
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            self?.emit(.interruptionEnded)
        })
        // A runtime error is only reported here. Recovery is driven by `AppModel` (issue #4): it calls
        // `resumeRunning()` from its pipeline on a bounded backoff, so a restart can't race a stop or a
        // reconfigure, and it gives up visibly instead of saying "Restarting…" forever.
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.emit(.interrupted(.runtimeError(error?.localizedDescription ?? "unknown")))
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: FrameSource

    var captureSession: AVCaptureSession? { session }

    func setSink(_ sink: SampleSink?) { sinkBox.withLock { $0.sink = sink } }
    func setEventHandler(_ handler: (@Sendable (FrameSourceEvent) -> Void)?) { eventBox.withLock { $0 = handler } }

    func supportedResolutions(for camera: CameraPosition) -> [VideoResolution] {
        guard let device = Self.device(for: camera) else { return [.hd720, .hd1080] }
        return VideoResolution.allCases.filter { Self.format(for: device, resolution: $0, fps: 30) != nil }
    }

    func start(_ configuration: CaptureConfiguration) async throws -> ActiveCapture {
        guard await Self.requestAccess(for: .video) else { throw FrameSourceError.cameraAccessDenied }
        // A denied microphone is not an error: capture runs video-only and says so in the result.
        var micGranted = false
        if configuration.audioEnabled { micGranted = await Self.requestAccess(for: .audio) }
        let addMicrophone = micGranted
        let deniedByUser = configuration.audioEnabled && !micGranted
        let micProblem = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<AudioUnavailableReason?, Error>) in
            sessionQueue.async { [self] in
                do {
                    let problem = try configure(configuration, audio: addMicrophone)
                    if !session.isRunning { session.startRunning() }
                    cont.resume(returning: problem)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        if deniedByUser {
            return ActiveCapture(audioCaptured: false, audioUnavailable: .microphoneDenied)
        }
        if let micProblem {
            return ActiveCapture(audioCaptured: false, audioUnavailable: micProblem)
        }
        return ActiveCapture(audioCaptured: configuration.audioEnabled, audioUnavailable: nil)
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                if session.isRunning { session.stopRunning() }
                cont.resume()
            }
        }
    }

    /// `isRunning` and `isInterrupted` are key-value observable session properties, read here from
    /// the main actor by the status loop.
    var runState: CaptureRunState {
        if session.isInterrupted { return .interrupted }
        return session.isRunning ? .running : .stopped
    }

    /// Closes both gaps of the old one-shot recovery (issue #4): (a) a session that is still, or
    /// already again, running now reports `.interruptionEnded`, so the recorder is resumed; (b) a
    /// session that doesn't start returns false, and `AppModel` tries again on its backoff.
    func resumeRunning() async -> Bool {
        let running = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            sessionQueue.async { [self] in
                // An interrupted session is resumed by iOS, which then posts `interruptionEnded`.
                if !session.isRunning, !session.isInterrupted { session.startRunning() }
                cont.resume(returning: session.isRunning && !session.isInterrupted)
            }
        }
        if running { emit(.interruptionEnded) }
        return running
    }

    // MARK: Sample delegates

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let kind: MediaKind = output is AVCaptureVideoDataOutput ? .video : .audio
        sinkBox.current.sink?.consume(sampleBuffer, kind: kind)
    }

    // MARK: - Private

    private func emit(_ event: FrameSourceEvent) { eventBox.current?(event) }

    private static func requestAccess(for type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    private static func device(for camera: CameraPosition) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: camera == .back ? .back : .front)
    }

    private static func format(for device: AVCaptureDevice, resolution: VideoResolution, fps: Int) -> AVCaptureDevice.Format? {
        let want = resolution.dimensions
        let candidates = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let yuv = sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return yuv && d.width == want.width && d.height == want.height
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) }
        }
        return candidates.first {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        } ?? candidates.first
    }

    /// Picks the requested preset, falling back to 30 fps and then lower resolutions.
    private static func bestFormat(for device: AVCaptureDevice, preset: QualityPreset) -> (AVCaptureDevice.Format, Int)? {
        var resolution: VideoResolution? = preset.resolution
        while let r = resolution {
            for fps in Set([preset.frameRate.rawValue, 30]).sorted(by: >) {
                if let f = format(for: device, resolution: r, fps: fps) { return (f, fps) }
            }
            resolution = r.lower
        }
        return nil
    }

    /// Rebuilds the session graph. Throws if video can't be captured; returns why the microphone
    /// couldn't be added when `audio` is true (nil when it was added, or not asked for).
    private func configure(_ configuration: CaptureConfiguration, audio: Bool) throws -> AudioUnavailableReason? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .inputPriority
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        guard let device = Self.device(for: configuration.camera) else { throw FrameSourceError.noCamera }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw FrameSourceError.configurationFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else { throw FrameSourceError.configurationFailed("can't add camera input") }
        session.addInput(input)

        if let best = Self.bestFormat(for: device, preset: configuration.preset) {
            let (format, fps) = best
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            } catch {
                throw FrameSourceError.configurationFailed(error.localizedDescription)
            }
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(videoOutput) else { throw FrameSourceError.configurationFailed("can't add video output") }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video) {
            // The app is portrait-only: rotate in the capture pipeline so the file is upright.
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if configuration.camera == .front, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }

        return audio ? addMicrophone() : nil
    }

    /// Adds the microphone input and audio output. Returns why it couldn't, leaving the session
    /// video-only (never an input without an output, which would deliver nothing).
    private func addMicrophone() -> AudioUnavailableReason? {
        guard let mic = AVCaptureDevice.default(for: .audio) else { return .microphoneUnavailable("no microphone") }
        let micInput: AVCaptureDeviceInput
        do {
            micInput = try AVCaptureDeviceInput(device: mic)
        } catch {
            return .microphoneUnavailable(error.localizedDescription)
        }
        guard session.canAddInput(micInput) else { return .microphoneUnavailable("can't add microphone input") }
        session.addInput(micInput)
        audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(audioOutput) else {
            session.removeInput(micInput)
            return .microphoneUnavailable("can't add audio output")
        }
        session.addOutput(audioOutput)
        return nil
    }

    private static func map(_ reason: AVCaptureSession.InterruptionReason?) -> InterruptionReason {
        switch reason {
        case .videoDeviceNotAvailableInBackground: .backgrounded
        case .videoDeviceInUseByAnotherClient: .cameraInUseByAnotherApp
        case .audioDeviceInUseByAnotherClient: .audioInUseByAnotherApp
        case .videoDeviceNotAvailableDueToSystemPressure: .systemPressure
        case .videoDeviceNotAvailableWithMultipleForegroundApps: .other("the camera is unavailable in Split View")
        default: .other("the camera was interrupted")
        }
    }
}
