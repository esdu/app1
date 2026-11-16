import AVFoundation
import CoreMedia

enum MediaKind: Sendable { case video, audio }

/// Receives timestamped samples from a `FrameSource`. Called on the source's capture queue.
protocol SampleSink: AnyObject, Sendable {
    func consume(_ sampleBuffer: CMSampleBuffer, kind: MediaKind)
}

enum InterruptionReason: Equatable, Sendable {
    case backgrounded
    case cameraInUseByAnotherApp
    case audioInUseByAnotherApp
    case systemPressure
    case runtimeError(String)
    case other(String)

    var message: String {
        switch self {
        case .backgrounded: "Paused — iOS can't record while RewindCam is in the background."
        case .cameraInUseByAnotherApp: "Paused — another app is using the camera."
        case .audioInUseByAnotherApp: "Paused — a call or another app is using the microphone."
        case .systemPressure: "Paused — the phone is too hot to use the camera."
        case .runtimeError(let why): "Camera error: \(why). Restarting…"
        case .other(let why): "Paused — \(why)."
        }
    }
}

enum FrameSourceEvent: Equatable, Sendable {
    case interrupted(InterruptionReason)
    case interruptionEnded
}

/// What the caller asks a source to capture. `audioEnabled` is a request: the microphone may be
/// denied or unusable, and `FrameSource.start` reports what was actually set up (`ActiveCapture`).
struct CaptureConfiguration: Equatable, Sendable {
    var preset: QualityPreset
    var audioEnabled: Bool
    var camera: CameraPosition
}

/// Why audio was requested but isn't captured.
enum AudioUnavailableReason: Equatable, Sendable {
    /// The user denied microphone access (or it is restricted). Fixable in the Settings app.
    case microphoneDenied
    /// No microphone, or its input or output couldn't be added to the capture session.
    case microphoneUnavailable(String)
}

/// What a started source actually delivers to its sink (issue #3).
///
/// The recorder's writer gets an audio input only when `audioCaptured` is true: an input that is
/// never fed stalls the segmenting writer (see `RecorderTests.writerAudioInputWithoutSamples`).
struct ActiveCapture: Equatable, Sendable {
    /// True only if audio sample buffers will be passed to the sink.
    var audioCaptured: Bool
    /// Set when audio was requested but isn't captured; nil when it is captured or wasn't requested.
    var audioUnavailable: AudioUnavailableReason?
}

enum FrameSourceError: LocalizedError, Equatable {
    case cameraAccessDenied
    case noCamera
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .cameraAccessDenied: "Camera access is off. Allow it in Settings › RewindCam › Camera."
        case .noCamera: "No camera is available on this device."
        case .configurationFailed(let why): "Couldn't start the camera: \(why)"
        }
    }
}

/// Anything that produces video (and optionally audio) sample buffers.
/// `CameraFrameSource` wraps AVCaptureSession; `SyntheticFrameSource` drives tests and the Simulator.
protocol FrameSource: AnyObject, Sendable {
    func setSink(_ sink: SampleSink?)
    func setEventHandler(_ handler: (@Sendable (FrameSourceEvent) -> Void)?)
    /// Starts (or reconfigures and restarts) capture. Throws only when video can't be captured
    /// (`FrameSourceError`). Audio problems never throw: they are reported in the result, and the
    /// caller builds the recorder configuration from the result, never from what it requested.
    func start(_ configuration: CaptureConfiguration) async throws -> ActiveCapture
    func stop() async
    /// Resolutions this source can deliver for the given camera.
    func supportedResolutions(for camera: CameraPosition) -> [VideoResolution]
    /// Non-nil for a real camera, so the UI can show a live preview layer.
    var captureSession: AVCaptureSession? { get }
}
