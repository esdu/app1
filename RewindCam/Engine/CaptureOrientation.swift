import AVFoundation
import CoreGraphics
import Foundation

// Issue #37: clips recorded with the phone held sideways must play upright.
//
// The capture pipeline stays fixed (DESIGN.md §2, "Orientation"): every buffer is rotated for the
// portrait interface, as before, so turning the phone never changes the frame size and never restarts
// the writer or clears the buffer. Instead the way the phone is held at the save tap is turned into
// the exported track's `preferredTransform`. Everything here is pure, so it is unit tested.

/// How the phone is held, as seen from its screen. The names follow `UIDeviceOrientation`.
enum DeviceOrientation: String, CaseIterable, Sendable {
    /// Upright, the top of the phone up.
    case portrait
    /// Turned a quarter anticlockwise: the top of the phone points left (side buttons up).
    case landscapeLeft
    /// Turned a quarter clockwise: the top of the phone points right.
    case landscapeRight
    /// Upside down.
    case portraitUpsideDown

    /// Clockwise quarter turns from portrait, seen from the screen side.
    var clockwiseQuarterTurns: Int {
        switch self {
        case .portrait: 0
        case .landscapeRight: 1
        case .portraitUpsideDown: 2
        case .landscapeLeft: 3
        }
    }

    /// Where gravity points in this orientation, in degrees: `atan2(x, -y)` of the accelerometer's
    /// gravity vector (Core Motion's device frame: x to the right of the portrait screen, y to its top).
    /// Portrait 0, landscape right 90, upside down 180, landscape left −90.
    var gravityAngle: Double { Double(clockwiseQuarterTurns) * 90 }

    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
}

/// Gravity in Core Motion's device frame, in g (`CMAccelerometerData.acceleration`).
struct Gravity: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    /// The phone held still in `orientation`, tilted back `tiltBack` degrees from vertical.
    static func held(_ orientation: DeviceOrientation, tiltBack: Double = 0) -> Gravity {
        let inPlane = cos(tiltBack * .pi / 180)
        let angle = orientation.gravityAngle * .pi / 180
        return Gravity(x: inPlane * sin(angle), y: -inPlane * cos(angle), z: -sin(tiltBack * .pi / 180))
    }
}

/// Turns a gravity sample into an orientation, with hysteresis so a phone held near 45° doesn't flicker.
enum OrientationClassifier {
    /// Below this in-plane gravity (the phone within about 20° of lying flat), the screen's direction says
    /// nothing about which way is up: no decision, the current orientation stays.
    static let minimumInPlaneGravity = 0.35
    /// The current orientation is kept until the phone is turned this far past the 45° midpoint
    /// (so 60° away from it).
    static let hysteresisDegrees = 15.0

    /// The orientation for `gravity`, given the one in effect. nil: lying (nearly) flat, keep `current`.
    static func classify(_ gravity: Gravity, current: DeviceOrientation) -> DeviceOrientation? {
        guard (gravity.x * gravity.x + gravity.y * gravity.y).squareRoot() >= minimumInPlaneGravity else { return nil }
        let angle = atan2(gravity.x, -gravity.y) * 180 / .pi
        if distance(angle, current.gravityAngle) <= 45 + hysteresisDegrees { return current }
        return DeviceOrientation.allCases.min { distance(angle, $0.gravityAngle) < distance(angle, $1.gravityAngle) }
    }

    /// Angular distance in degrees, 0...180.
    static func distance(_ a: Double, _ b: Double) -> Double {
        abs(remainder(a - b, 360))
    }
}

/// The settled orientation: a new orientation counts only once it has been held for `settleSeconds`, so a
/// brief tilt (picking the phone up to tap Save, a bump on a propped phone) doesn't turn the clip.
/// Times are seconds on a monotonic clock; only differences matter.
struct OrientationTracker: Equatable, Sendable {
    static let settleSeconds: TimeInterval = 0.5

    /// What the classifier says now (with hysteresis), settled or not.
    private(set) var latest: DeviceOrientation
    private var latestSince: TimeInterval?
    private var settledOrientation: DeviceOrientation

    init(_ initial: DeviceOrientation = .portrait) {
        latest = initial
        settledOrientation = initial
    }

    /// Feeds one accelerometer sample taken at `time`.
    mutating func receive(_ gravity: Gravity, at time: TimeInterval) {
        guard let classified = OrientationClassifier.classify(gravity, current: latest) else { return }
        receive(classified, at: time)
    }

    /// Feeds one classified sample taken at `time`.
    mutating func receive(_ orientation: DeviceOrientation, at time: TimeInterval) {
        settledOrientation = settled(at: time)
        guard orientation != latest else { return }
        latest = orientation
        latestSince = time
        // Back to the settled orientation: nothing is pending any more.
        if orientation == settledOrientation { latestSince = nil }
    }

    /// The orientation in effect at `time` (not earlier than the last sample).
    func settled(at time: TimeInterval) -> DeviceOrientation {
        if let since = latestSince, latest != settledOrientation, time - since >= Self.settleSeconds { return latest }
        return settledOrientation
    }
}

/// How the capture pipeline orients and mirrors buffers. `CameraFrameSource` and the preview apply it;
/// `ClipOrientation` relies on it.
enum CaptureGeometry {
    /// `videoRotationAngle` for the video data output and the preview: upright in the portrait interface
    /// (the only one the app supports, project.yml). Fixed, so turning the phone never changes the
    /// frame size (which would start a new writer generation and clear the buffer).
    static let portraitRotationAngle: CGFloat = 90

    /// The front camera's buffers are mirrored, like its preview (and the system Camera app's default):
    /// the user sees themselves as in a mirror. The back camera's are not.
    static func isMirrored(_ camera: CameraPosition) -> Bool { camera == .front }

    /// True when a buffer from `camera`, mirrored or not, shows the scene as the screen does: as through a
    /// window (back camera, not mirrored) or as in a mirror (front camera, mirrored). Its x axis then runs
    /// along the phone's own x axis, so a turn of the phone turns the scene in the buffer the other way.
    /// The other two cases see the scene flipped left to right relative to the screen.
    static func bufferMatchesScreen(camera: CameraPosition, mirrored: Bool) -> Bool {
        (camera == .front) == mirrored
    }

    /// Sets a connection to `portraitRotationAngle` (no-op if it is already there or unsupported).
    static func applyPortraitRotation(to connection: AVCaptureConnection?) {
        guard let connection, connection.videoRotationAngle != portraitRotationAngle,
              connection.isVideoRotationAngleSupported(portraitRotationAngle) else { return }
        connection.videoRotationAngle = portraitRotationAngle
    }
}

/// How a saved clip is turned for display: from the way the phone was held at the save tap and the camera.
/// The buffer itself is always the portrait one (`CaptureGeometry`); this becomes the exported video
/// track's `preferredTransform`, which Photos and every player honour, without re-encoding.
struct ClipOrientation: Equatable, Sendable {
    var device: DeviceOrientation
    var camera: CameraPosition
    /// Whether the buffers were mirrored (`CaptureGeometry.isMirrored(camera)` in the app).
    var bufferMirrored: Bool

    init(device: DeviceOrientation, camera: CameraPosition, bufferMirrored: Bool? = nil) {
        self.device = device
        self.camera = camera
        self.bufferMirrored = bufferMirrored ?? CaptureGeometry.isMirrored(camera)
    }

    /// Portrait, back camera: the identity transform (what every clip got before issue #37).
    static let upright = ClipOrientation(device: .portrait, camera: .back)

    /// Clockwise quarter turns that bring the buffer upright. A phone turned clockwise by k quarters sees
    /// the scene turned anticlockwise by k in a screen-like buffer (back camera, or the mirrored front
    /// camera), so the clip is turned clockwise by k. A buffer flipped left to right relative to the
    /// screen (an unmirrored front camera) turns the other way.
    var clockwiseQuarterTurns: Int {
        let k = device.clockwiseQuarterTurns
        return CaptureGeometry.bufferMatchesScreen(camera: camera, mirrored: bufferMirrored) ? k : (4 - k) % 4
    }

    /// The size players show for a track of `naturalSize`.
    func displaySize(naturalSize: CGSize) -> CGSize {
        clockwiseQuarterTurns % 2 == 0 ? naturalSize : CGSize(width: naturalSize.height, height: naturalSize.width)
    }

    /// The track's `preferredTransform` for buffers of `naturalSize`: a rotation in the video's y-down
    /// coordinates that maps the frame onto `(0, 0, displaySize)`.
    func transform(naturalSize: CGSize) -> CGAffineTransform {
        let w = naturalSize.width
        let h = naturalSize.height
        switch clockwiseQuarterTurns {
        case 1: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: return .identity
        }
    }
}
