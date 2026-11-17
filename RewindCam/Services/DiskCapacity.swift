import Foundation

/// How much free space the volume holding RewindCam's media has (issue #10). The only way the app reads
/// free space: `AppModel` asks it at start, every `DiskSpacePolicy.checkInterval` while recording, before
/// a save, and for the Settings sheet; `DiskSpacePolicy` decides what the answer means.
///
/// `nil` means the value is unavailable (some Simulator and odd volumes); the policy treats that as
/// "enough", so it never blocks recording. Issue #14's working-set accounting reuses this provider.
///
/// Live: `VolumeDiskCapacity`. Tests and `-UITestLowDisk`: `FakeDiskCapacity`.
protocol DiskCapacityProvider: Sendable {
    /// Bytes available for important (user-initiated) writes, or nil if unknown.
    func availableBytes() -> Int64?
}

/// `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` of the volume holding `volumeURL`: what
/// iOS would make available for a user-initiated write, including purgeable space it can reclaim.
/// Required-reason API "disk space", declared in `PrivacyInfo.xcprivacy` as `E174.1` (check there is
/// enough space to write files; the result is shown to the user and decides whether recording starts).
struct VolumeDiskCapacity: DiskCapacityProvider {
    /// Any URL on the volume; the app passes the Caches root that holds the buffer.
    let volumeURL: URL

    func availableBytes() -> Int64? {
        let values = try? volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// A settable free-space value for tests and `-UITestLowDisk`. Thread-safe, so a reader on any queue
/// (issue #14's admission checks) can use it too.
final class FakeDiskCapacity: DiskCapacityProvider {
    private let value: Locked<Int64?>
    private let reads = Locked(0)

    init(availableBytes: Int64?) {
        value = Locked(availableBytes)
    }

    func availableBytes() -> Int64? {
        reads.withLock { $0 += 1 }
        return value.current
    }

    func set(_ bytes: Int64?) {
        value.withLock { $0 = bytes }
    }

    /// How many times the free space was read (tests check the periodic check's interval).
    var readCount: Int { reads.current }
}
