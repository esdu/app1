import Foundation

/// One ~1 s fMP4 media segment on disk. Times are media-timeline seconds.
struct BufferedSegment: Equatable, Sendable {
    let index: Int
    let url: URL
    let start: Double
    let duration: Double
    let bytes: Int64
    var end: Double { start + duration }

    func relocated(to url: URL) -> BufferedSegment {
        BufferedSegment(index: index, url: url, start: start, duration: duration, bytes: bytes)
    }
}

/// Pure eviction policy for the rolling buffer (no I/O; the caller deletes evicted files).
///
/// Keeps the minimal suffix of segments that still covers `bufferDuration`, and never
/// holds more than `byteCap` bytes (the newest segment is always kept).
struct SegmentRing: Sendable {
    var bufferDuration: Double
    var byteCap: Int64
    private(set) var segments: [BufferedSegment] = []

    init(bufferDuration: Double, byteCap: Int64) {
        self.bufferDuration = bufferDuration
        self.byteCap = byteCap
    }

    var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }
    var totalBytes: Int64 { segments.reduce(0) { $0 + $1.bytes } }
    var isEmpty: Bool { segments.isEmpty }

    /// Adds the newest segment and returns the ones that fell out of the window.
    mutating func append(_ segment: BufferedSegment) -> [BufferedSegment] {
        segments.append(segment)
        return evict()
    }

    /// Re-applies the policy, e.g. after the buffer length was shortened.
    mutating func evict() -> [BufferedSegment] {
        var evicted: [BufferedSegment] = []
        var duration = totalDuration
        var bytes = totalBytes
        while segments.count > 1 {
            let oldest = segments[0]
            let stillCovers = duration - oldest.duration >= bufferDuration
            guard stillCovers || bytes > byteCap else { break }
            evicted.append(segments.removeFirst())
            duration -= oldest.duration
            bytes -= oldest.bytes
        }
        return evicted
    }

    mutating func removeAll() -> [BufferedSegment] {
        defer { segments.removeAll() }
        return segments
    }
}
