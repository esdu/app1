import CoreMotion
import Foundation

/// Which way the phone is held (issue #37). `AppModel.save` reads it at the tap and the clip is turned
/// to match (`ClipOrientation`). Live: `MotionOrientationSensor`; tests: `FakeOrientationSensor`.
@MainActor
protocol DeviceOrientationSensor: AnyObject {
    /// The settled orientation now; portrait until anything else is known.
    var orientation: DeviceOrientation { get }
    /// Starts following the phone (idempotent). `AppModel.init` calls it.
    func start()
}

/// Reads gravity from the accelerometer (10 Hz) and settles it with `OrientationTracker`.
///
/// Gravity rather than `UIDevice.orientation`: the latter stops changing when the user turns on Portrait
/// Orientation Lock, the usual setting for anyone who props a phone up to film. The accelerometer needs
/// no permission, reports the same for either camera, and is cheap at this rate. Where there is none
/// (the Simulator), the orientation stays portrait.
@MainActor
final class MotionOrientationSensor: DeviceOrientationSensor {
    static let updateInterval: TimeInterval = 0.1

    private let manager = CMMotionManager()
    // Sendable (both clocks are), so the nonisolated init may store it.
    private let clock: any MonotonicClock & Sendable
    private let usesAccelerometer: Bool
    private var tracker = OrientationTracker()

    /// `usesAccelerometer: false` (tests) never turns the accelerometer on; feed `receive(_:)` instead.
    /// Nonisolated so it can be `AppEnvironment`'s default; nothing runs until `start()`.
    nonisolated init(clock: any MonotonicClock & Sendable = HostMonotonicClock(), usesAccelerometer: Bool = true) {
        self.clock = clock
        self.usesAccelerometer = usesAccelerometer
    }

    func start() {
        guard usesAccelerometer, manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        manager.accelerometerUpdateInterval = Self.updateInterval
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let acceleration = data?.acceleration else { return }
            let gravity = Gravity(x: acceleration.x, y: acceleration.y, z: acceleration.z)
            MainActor.assumeIsolated { self?.receive(gravity) }
        }
    }

    var orientation: DeviceOrientation { tracker.settled(at: clock.seconds) }

    /// One accelerometer sample, stamped now.
    func receive(_ gravity: Gravity) {
        tracker.receive(gravity, at: clock.seconds)
    }
}

/// Tests and previews: an orientation set by hand, in effect at once.
@MainActor
final class FakeOrientationSensor: DeviceOrientationSensor {
    var orientation: DeviceOrientation
    nonisolated init(_ orientation: DeviceOrientation = .portrait) { self.orientation = orientation }
    func start() {}
}
