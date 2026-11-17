import Foundation

/// Disk-budget arithmetic. All sizes in bytes, rates in bits per second.
enum BufferMath {
    static let audioBitrate = 64_000
    /// Extra seconds the ring may hold: one retained-over segment + one in flight + slack.
    static let marginSeconds = 3.0
    /// Headroom for VBR peaks and fMP4 box overhead.
    static let overheadFactor = 1.5

    static func totalBitrate(videoBitrate: Int, audioEnabled: Bool) -> Int {
        videoBitrate + (audioEnabled ? audioBitrate : 0)
    }

    /// Nominal size of `seconds` of media at the given preset.
    static func estimatedBytes(preset: QualityPreset, audioEnabled: Bool, seconds: Double) -> Int64 {
        Int64(Double(totalBitrate(videoBitrate: preset.videoBitrate, audioEnabled: audioEnabled)) / 8 * seconds)
    }

    /// Hard cap on bytes held by the rolling ring for a buffer of `bufferSeconds`.
    static func ringCapBytes(videoBitrate: Int, audioEnabled: Bool, bufferSeconds: Double) -> Int64 {
        let bytesPerSecond = Double(totalBitrate(videoBitrate: videoBitrate, audioEnabled: audioEnabled)) / 8
        return Int64(bytesPerSecond * (bufferSeconds + marginSeconds) * overheadFactor)
    }

    static func formatted(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Free-space thresholds (issue #10; DESIGN.md §2 "Bounded disk" → "Free space")

    /// Free space always left alone: capture refuses to start without it on top of the ring cap, and
    /// stops when free space falls below it. 64 MB is more than the ring can grow between two checks
    /// (4K60 at the 1.5 overhead: 6.26 MB/s × 1.5 × `DiskSpacePolicy.checkInterval` 5 s ≈ 47 MB).
    static let reserveBytes: Int64 = 64_000_000

    /// Free space needed before buffering starts: the ring cap plus `reserveBytes`.
    static func requiredBytesToBuffer(_ configuration: RollingRecorder.Configuration) -> Int64 {
        configuration.byteCap + reserveBytes
    }

    /// Extra space a save needs on top of the ring, per the save path after issue #1:
    /// * post-roll segments: the save's hard links keep up to `postRoll` s of segments the ring has
    ///   meanwhile evicted (they are part of the ring cap while the ring holds them);
    /// * `RewindClips/save-*/source.mp4`: init + segments concatenated, ≤ the clip;
    /// * `UnsavedClips/*.partial.mov`: the passthrough export, ≤ the clip.
    /// The clip is `bufferSeconds + postRoll` at the nominal rate. The Photos staging link adds nothing.
    /// It is an estimate (nominal bitrate, no overhead factor), used to warn, never to refuse a save.
    static func requiredBytesToSave(_ configuration: RollingRecorder.Configuration, postRollSeconds: Double) -> Int64 {
        let bytesPerSecond = Double(totalBitrate(videoBitrate: configuration.videoBitrate,
                                                 audioEnabled: configuration.audioEnabled)) / 8
        let postRoll = max(0, postRollSeconds)
        let clip = bytesPerSecond * (configuration.bufferDuration + postRoll)
        return Int64(bytesPerSecond * postRoll + 2 * clip)
    }
}

/// **The free-space policy** (issue #10): every threshold for "is there room to record and save" in one
/// pure value, built from the settings that size the ring (`BufferMath`). `AppModel` reads free space
/// through `DiskCapacityProvider` and asks this what to do; issue #14 reuses both instead of adding its
/// own thresholds. Documented in DESIGN.md §2, "Bounded disk" → "Free space".
///
/// | When | Free space (`available`) | Outcome |
/// |---|---|---|
/// | before buffering (start, restart, Try Again) | `< requiredBytesToBuffer` | `.tooLow`: don't start |
/// | | `< requiredBytesToBuffer + requiredBytesToSave` | `.saveMayNotFit`: start, warn |
/// | while recording, every `checkInterval` | `< reserveBytes` | `.tooLow`: stop cleanly |
/// | | `+ ringBytes < requiredBytesToBuffer + requiredBytesToSave` | `.saveMayNotFit`: keep recording, warn |
/// | before a save | `< requiredBytesToSave` | `.saveMayNotFit`: save anyway, warn |
///
/// Unknown free space (`nil`) is always `.enough`. While recording, the ring's own bytes are already on
/// disk, so they count as available for the ring (`ringBytes`): a full ring doesn't trigger a warning
/// that the same free space before it filled wouldn't have.
struct DiskSpacePolicy: Equatable, Sendable {
    /// How often the status loop checks free space while recording (every 10th tick of 0.5 s).
    static let checkInterval: TimeInterval = 5
    static var reserveBytes: Int64 { BufferMath.reserveBytes }

    /// The ring being sized: buffer length, bitrate and whether audio is written.
    let configuration: RollingRecorder.Configuration
    let postRollSeconds: Int

    init(configuration: RollingRecorder.Configuration, postRollSeconds: Int) {
        self.configuration = configuration
        self.postRollSeconds = postRollSeconds
    }

    init(bufferSeconds: Int, preset: QualityPreset, audioEnabled: Bool, postRollSeconds: Int) {
        self.init(configuration: RollingRecorder.Configuration(bufferSeconds: bufferSeconds, preset: preset,
                                                               audioEnabled: audioEnabled),
                  postRollSeconds: postRollSeconds)
    }

    var requiredBytesToBuffer: Int64 { BufferMath.requiredBytesToBuffer(configuration) }
    var requiredBytesToSave: Int64 {
        BufferMath.requiredBytesToSave(configuration, postRollSeconds: Double(postRollSeconds))
    }
    /// Room for the buffer, the reserve and one save: below this, a warning.
    var requiredBytesToBufferAndSave: Int64 { requiredBytesToBuffer + requiredBytesToSave }

    /// Before capture starts (the ring is empty).
    func beforeBuffering(availableBytes: Int64?) -> DiskSpaceCheck {
        guard let available = availableBytes else { return .unknown }
        let level: DiskSpaceCheck.Level = available < requiredBytesToBuffer ? .tooLow
            : available < requiredBytesToBufferAndSave ? .saveMayNotFit : .enough
        return DiskSpaceCheck(level: level, availableBytes: available,
                              bytesToFree: max(0, requiredBytesToBufferAndSave - available))
    }

    /// While recording, with `ringBytes` (`RecorderStatus.bytes`) of the ring already on disk.
    func whileRecording(availableBytes: Int64?, ringBytes: Int64) -> DiskSpaceCheck {
        guard let available = availableBytes else { return .unknown }
        // Stopping deletes the ring, so what has to be freed to record and save again is measured
        // against the free space plus the ring.
        let afterRing = available + max(0, ringBytes)
        let level: DiskSpaceCheck.Level = available < BufferMath.reserveBytes ? .tooLow
            : afterRing < requiredBytesToBufferAndSave ? .saveMayNotFit : .enough
        return DiskSpaceCheck(level: level, availableBytes: available,
                              bytesToFree: max(0, requiredBytesToBufferAndSave - afterRing))
    }

    /// When Save is tapped (the ring is already on disk). Never `.tooLow`: a save is never refused for
    /// space; a shorter clip, or an export that fails with a message, is better than none.
    func beforeSave(availableBytes: Int64?) -> DiskSpaceCheck {
        guard let available = availableBytes else { return .unknown }
        return DiskSpaceCheck(level: available < requiredBytesToSave ? .saveMayNotFit : .enough,
                              availableBytes: available,
                              bytesToFree: max(0, requiredBytesToSave - available))
    }
}

/// The answer of one `DiskSpacePolicy` check.
struct DiskSpaceCheck: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        /// Room for the buffer and a save, or free space is unknown.
        case enough
        /// Recording can run, but a save may run out of space.
        case saveMayNotFit
        /// Not enough to buffer: don't start, or stop.
        case tooLow
    }

    let level: Level
    /// What the volume reported; nil when unknown.
    let availableBytes: Int64?
    /// About how much to free so there is no warning: room for the buffer, the reserve and one save
    /// (`beforeBuffering`, `whileRecording`), or for the save (`beforeSave`). 0 when it fits.
    let bytesToFree: Int64

    static let unknown = DiskSpaceCheck(level: .enough, availableBytes: nil, bytesToFree: 0)
}

// MARK: - Working-set budgets (issue #14; DESIGN.md §2 "Bounded disk")
//
// Two separate budgets, both derived from the same settings as the ring cap:
// * **Queued fragment payloads** (memory): fragment `Data` the writer handed over that hasn't been
//   written to disk yet. `RollingRecorder` admits each fragment against `FragmentQueueLimit` before it
//   retains it; at the bound it stops the generation (`RecorderHalt.backlog`) instead of queueing more.
// * **Temporary media on disk**: ring + one save job + its concatenated source + its export output.
//   `temporaryMediaCapBytes` is the most these can hold at once; each part is enforced where it is
//   written (ring cap, save bundle cap, export admission against free space).

/// The admission bound on fragment data waiting for the recorder queue (issue #14).
struct FragmentQueueLimit: Equatable, Sendable {
    /// Fragments (init or media) admitted and not yet written or dropped.
    let count: Int
    /// Bytes of those fragments.
    let bytes: Int64
    /// Largest single fragment admitted: never more than the queue bound or the ring cap, so the ring
    /// can always hold a fragment it admitted.
    let fragmentBytes: Int64
}

extension BufferMath {
    /// About 1 s per fragment: 8 fragments is ~8 s of writes the disk hasn't kept up with. Healthy
    /// storage keeps the queue at 0–1.
    static let maxQueuedFragments = 8
    /// Seconds of media (at the ring's overhead factor) the queue may hold in bytes…
    static let queuedFragmentSeconds = 4.0
    /// …but never less than this, so low presets and a large init/keyframe fragment aren't refused.
    static let minQueuedFragmentBytes: Int64 = 16_000_000

    static func bytesPerSecond(_ configuration: RollingRecorder.Configuration) -> Double {
        Double(totalBitrate(videoBitrate: configuration.videoBitrate, audioEnabled: configuration.audioEnabled)) / 8
    }

    /// The queued-fragment bound for a configuration: 8 fragments, max(16 MB, 4 s × rate × 1.5) bytes,
    /// and no single fragment larger than that or the ring cap. 4K60: 37.5 MB; 1080p30: 16 MB.
    static func fragmentQueueLimit(_ configuration: RollingRecorder.Configuration) -> FragmentQueueLimit {
        let bytes = max(minQueuedFragmentBytes,
                        Int64(bytesPerSecond(configuration) * queuedFragmentSeconds * overheadFactor))
        return FragmentQueueLimit(count: maxQueuedFragments, bytes: bytes,
                                  fragmentBytes: min(bytes, configuration.byteCap))
    }

    /// The most one save's job folder may hold (`init.mp4` + linked or copied segments): the ring cap
    /// for a buffer of `buffer + postRoll` seconds. The recorder settles a save early rather than
    /// exceed it (`SaveLimit.workingSetCap`).
    static func saveBundleCapBytes(_ configuration: RollingRecorder.Configuration, postRollSeconds: Double) -> Int64 {
        ringCapBytes(videoBitrate: configuration.videoBitrate, audioEnabled: configuration.audioEnabled,
                     bufferSeconds: configuration.bufferDuration + max(0, postRollSeconds))
    }

    /// A passthrough export's output is the trimmed samples of its source plus a new `moov`: at most
    /// the source plus 5 % (`exportOutputPercent`) and 256 kB. `AVAssetExportSession` is given that as its
    /// `fileLengthLimit`, which it documents as approximate: it can write slightly past it. That
    /// overshoot is the one part of the working set bounded only by the free-space reserve.
    static let exportOutputPercent: Int64 = 5
    static let exportOutputSlackBytes: Int64 = 256_000

    static func exportOutputBytes(sourceBytes: Int64) -> Int64 {
        let source = max(0, sourceBytes)
        return source + (source * exportOutputPercent + 99) / 100 + exportOutputSlackBytes
    }

    /// What an export adds to the disk on top of the job folder: the concatenated `source.mp4` (as big
    /// as the bundle it is made of) and the `.partial.mov` output, which exist together while
    /// the export runs. (The job folder's segment links are deleted once `source.mp4` is complete.)
    static func exportPeakBytes(sourceBytes: Int64) -> Int64 {
        max(0, sourceBytes) + exportOutputBytes(sourceBytes: sourceBytes)
    }

    /// Hard bound on RewindCam's temporary media on disk at any moment (issue #14): ring cap + one save's
    /// job folder (`saveBundleCapBytes`) + its export output. While `source.mp4` is written the job
    /// folder's segments still exist (ring + bundle + source ≤ ring + 2 × bundle); then they are deleted
    /// and the output is written (ring + source + output). Both are within ring + bundle + output.
    /// Only one save runs at a time (`AppModel.isSaving`). Kept clips waiting for Photos are durable, not
    /// temporary, and are reported separately; a Photos staging hard link adds nothing (a copy, only if
    /// linking fails, is admitted against free space like the rest).
    static func temporaryMediaCapBytes(_ configuration: RollingRecorder.Configuration, postRollSeconds: Double) -> Int64 {
        let bundle = saveBundleCapBytes(configuration, postRollSeconds: postRollSeconds)
        return configuration.byteCap + bundle + exportOutputBytes(sourceBytes: bundle)
    }
}

/// How much of a save's footage the free space can take (issue #14), decided before the export
/// writes anything. See `DiskSpacePolicy.exportAdmission`.
enum ExportAdmission: Equatable, Sendable {
    /// Everything fits (or free space is unknown).
    case all
    /// Only the newest `segments` fit: export those, a shorter clip that still ends where asked.
    case newest(segments: Int)
    /// Not even the newest segment fits; free about `bytesToFree` more and save again.
    case none(bytesToFree: Int64)
}

// MARK: - Save headroom (issue #14)
//
// #10's checks above are estimates that warn; these decide, from actual file sizes, how much of a save
// the free space can really take. They reuse #10's one threshold, `reserveBytes`, and add none.
extension DiskSpacePolicy {
    /// Free space a save's temporary files (copied segments, `source.mp4`, the export, a Photos staging
    /// copy) must leave alone. While capture writes, the reserve: the ring grows into it between two
    /// free-space checks, so a save may not take it. Once capture has stopped nothing else of RewindCam's
    /// writes, so a save may use what is free, best effort, but never more than that.
    static func saveFloorBytes(captureRunning: Bool) -> Int64 {
        captureRunning ? reserveBytes : 0
    }

    /// How much of a save the free space can take before the export writes anything: the newest
    /// segments whose export peak (`BufferMath.exportPeakBytes`: concatenated source + output) fits in
    /// `availableBytes - floorBytes`. `initBytes` and `segmentBytes` (oldest first) are the sizes of the
    /// save's files on disk. Unknown free space is `.all`, as everywhere in this policy. A save is
    /// never refused before this point (#10); here it gets shorter, or fails with how much to free,
    /// instead of filling the disk.
    static func exportAdmission(initBytes: Int64, segmentBytes: [Int64], availableBytes: Int64?,
                                floorBytes: Int64) -> ExportAdmission {
        guard let available = availableBytes, !segmentBytes.isEmpty else { return .all }
        let room = available - floorBytes
        var source = max(0, initBytes)
        var kept = 0
        for bytes in segmentBytes.reversed() {
            let next = source + max(0, bytes)
            guard BufferMath.exportPeakBytes(sourceBytes: next) <= room else { break }
            source = next
            kept += 1
        }
        if kept == segmentBytes.count { return .all }
        if kept > 0 { return .newest(segments: kept) }
        let newest = BufferMath.exportPeakBytes(sourceBytes: max(0, initBytes) + max(0, segmentBytes.last ?? 0))
        return .none(bytesToFree: max(1, newest - room))
    }
}
