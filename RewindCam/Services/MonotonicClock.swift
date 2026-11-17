import CoreMedia
import Foundation

/// Seconds on a clock that only moves forward at a steady rate, for measuring intervals such as the
/// frame watchdog's "no new video for 5 s" (issue #9). Unlike `WallClock` it never jumps when the user
/// or the network changes the time. Live: `HostMonotonicClock`. Tests: `FakeDelayScheduler`, so the
/// status loop and the time it measures advance together.
@MainActor
protocol MonotonicClock: AnyObject {
    /// Seconds since an arbitrary fixed origin; only differences mean anything.
    var seconds: TimeInterval { get }
}

/// The Core Media host time clock: the timeline `AVCaptureSession` stamps frames with
/// (`HostMediaClock` reads the same clock). It is not one of the "system boot time" required-reason
/// APIs (`ProcessInfo.systemUptime`, `mach_absolute_time()`), so it needs no privacy-manifest entry.
final class HostMonotonicClock: MonotonicClock, Sendable {
    nonisolated init() {}
    nonisolated var seconds: TimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}
