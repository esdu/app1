import CoreMedia
import Foundation

/// The time source for frame timestamps. Real capture and the real-time synthetic
/// source use the host clock (same timeline as AVCaptureSession); tests use `ManualMediaClock`.
protocol MediaClock: Sendable {
    func now() -> CMTime
}

struct HostMediaClock: MediaClock {
    func now() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
}

final class ManualMediaClock: MediaClock, @unchecked Sendable {
    // @unchecked: state guarded by `Locked`.
    private let time: Locked<CMTime>

    init(start: CMTime = CMTime(seconds: 1_000, preferredTimescale: 600)) {
        time = Locked(start)
    }

    func now() -> CMTime { time.current }

    func advance(to t: CMTime) { time.withLock { $0 = max($0, t) } }
    func advance(by seconds: Double) {
        time.withLock { $0 = $0 + CMTime(seconds: seconds, preferredTimescale: 90_000) }
    }
}
