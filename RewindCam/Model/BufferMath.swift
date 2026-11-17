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
