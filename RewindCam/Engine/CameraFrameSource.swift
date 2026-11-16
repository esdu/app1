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
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.emit(.interrupted(.runtimeError(error?.localizedDescription ?? "unknown")))
            self?.recoverFromRuntimeError()
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

    func start(_ configuration: CaptureConfiguration) async throws {
        guard await Self.requestAccess(for: .video) else { throw FrameSourceError.cameraAccessDenied }
        var audio = false
        if configuration.audioEnabled { audio = await Self.requestAccess(for: .audio) }
        let audioGranted = audio
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try configure(configuration, audio: audioGranted)
                    if !session.isRunning { session.startRunning() }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                if session.isRunning { session.stopRunning() }
                cont.resume()
            }
        }
    }

    // MARK: Sample delegates

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let kind: MediaKind = output is AVCaptureVideoDataOutput ? .video : .audio
        sinkBox.current.sink?.consume(sampleBuffer, kind: kind)
    }

    // MARK: - Private

    private func emit(_ event: FrameSourceEvent) { eventBox.current?(event) }

    private func recoverFromRuntimeError() {
        sessionQueue.async { [self] in
            guard !session.isRunning else { return }
            session.startRunning()
            if session.isRunning { emit(.interruptionEnded) }
        }
    }

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

    private func configure(_ configuration: CaptureConfiguration, audio: Bool) throws {
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

        if audio, let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
            audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        }
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
