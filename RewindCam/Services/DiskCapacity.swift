import Foundation

/// How much free space the volume holding RewindCam's media has (issue #10). The only way the app reads
/// free space: `AppModel` asks it at start, every `DiskSpacePolicy.checkInterval` while recording, before
/// a save, and for the Settings sheet; `DiskSpacePolicy` decides what the answer means.
///
/// `nil` means the value is unavailable (some Simulator and odd volumes); the policy treats that as
/// "enough", so it never blocks recording. Issue #14's reservations (`TemporarySpace`) read it too.
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

/// Free space net of what running work has promised itself but not written yet (issue #14).
///
/// A reservation is taken before temporary media is written whose size is known up front: a segment
/// copy when a hard link fails (`RollingRecorder.linkOrCopy`), a save's export peak (`AppModel`), a Photos
/// staging copy. It is granted only if the bytes fit above a floor (`DiskSpacePolicy.saveFloorBytes`),
/// and released once the bytes are on disk (then free space itself shows them) or the work ended.
/// `AppModel`'s free-space reads (#10's checks) go through `unreservedBytes()`, so a start or the periodic
/// check during an export already counts the export's remaining bytes. Unknown free space (`nil`)
/// grants everything, as in `DiskSpacePolicy`.
final class TemporarySpace: Sendable {
    let capacity: (any DiskCapacityProvider)?
    private let reserved = Locked<Int64>(0)

    init(capacity: (any DiskCapacityProvider)?) {
        self.capacity = capacity
    }

    /// Bytes reserved and not yet released.
    var reservedBytes: Int64 { reserved.current }

    /// Free space minus outstanding reservations; nil if unknown.
    func unreservedBytes() -> Int64? {
        guard let available = capacity?.availableBytes() else { return nil }
        return available - reserved.current
    }

    /// Reserves `bytes` if, after all outstanding reservations, they leave at least `floor` free.
    /// Returns nil (nothing reserved) otherwise.
    func reserve(_ bytes: Int64, floor: Int64) -> SpaceReservation? {
        let available = capacity?.availableBytes()
        let granted: Bool = reserved.withLock { total in
            if let available, available - total - bytes < floor { return false }
            total += bytes
            return true
        }
        return granted ? SpaceReservation(space: self, bytes: bytes) : nil
    }

    fileprivate func giveBack(_ bytes: Int64) {
        reserved.withLock { $0 -= bytes }
    }
}

/// One `TemporarySpace` reservation. Released once (explicitly, or when it goes away).
final class SpaceReservation: Sendable {
    let bytes: Int64
    private let space: TemporarySpace
    private let released = Locked(false)

    fileprivate init(space: TemporarySpace, bytes: Int64) {
        self.space = space
        self.bytes = bytes
    }

    deinit { release() }

    func release() {
        let first: Bool = released.withLock { done in
            defer { done = true }
            return !done
        }
        if first { space.giveBack(bytes) }
    }
}

/// Temporary media that couldn't be given room above the floor (issue #14). Never thrown for a kept clip.
enum StorageSpaceError: LocalizedError, Equatable {
    /// A hard link failed and the copy that replaces it doesn't fit.
    case noRoomToCopy(bytes: Int64)
    /// Not even the newest second of a save fits as an export; free about `bytesToFree`.
    case noRoomToExport(bytesToFree: Int64)

    var errorDescription: String? {
        switch self {
        case .noRoomToCopy(let bytes):
            "Not enough free space to copy \(BufferMath.formatted(bytes: bytes)) of footage for this save."
        case .noRoomToExport(let bytes):
            "Nothing was saved: there isn't enough free space to export even the last second. "
                + "Free up about \(BufferMath.formatted(bytes: bytes)) (Settings › General › iPhone Storage) "
                + "and save again."
        }
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
