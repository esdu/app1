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
}
