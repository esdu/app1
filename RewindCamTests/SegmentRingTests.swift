import Foundation
import Testing
@testable import RewindCam

@Suite("Segment ring policy")
struct SegmentRingTests {
    private func segment(_ i: Int, start: Double, duration: Double = 1, bytes: Int64 = 1_000) -> BufferedSegment {
        BufferedSegment(index: i, url: URL(fileURLWithPath: "/tmp/seg-\(i)"), start: start, duration: duration, bytes: bytes)
    }

    @Test func keepsMinimalSuffixCoveringBuffer() {
        var ring = SegmentRing(bufferDuration: 30, byteCap: .max)
        var evicted = 0
        for i in 0..<100 { evicted += ring.append(segment(i, start: Double(i))).count }
        #expect(ring.segments.count == 30)
        #expect(ring.totalDuration == 30)
        #expect(evicted == 70)
        #expect(ring.segments.first?.index == 70)
        #expect(ring.segments.last?.index == 99)
    }

    @Test func unevenSegmentsStayWithinOneSegmentOfBuffer() {
        var ring = SegmentRing(bufferDuration: 30, byteCap: .max)
        var t = 0.0
        for i in 0..<300 {
            let d = [0.9, 1.0, 1.1, 0.95][i % 4]
            _ = ring.append(segment(i, start: t, duration: d))
            t += d
            if t > 31.2 {
                #expect(ring.totalDuration >= 30)
                #expect(ring.totalDuration < 30 + 1.1)
            }
        }
    }

    @Test func byteCapWinsOverDuration() {
        var ring = SegmentRing(bufferDuration: 30, byteCap: 10_000_000)
        for i in 0..<50 { _ = ring.append(segment(i, start: Double(i), bytes: 1_000_000)) }
        #expect(ring.totalBytes <= 10_000_000)
        #expect(ring.segments.count == 10)
    }

    /// Issue #14: the cap holds even for one segment. A segment that alone is over the cap is evicted
    /// too (the recorder refuses such fragments before they reach the ring; this covers a cap that
    /// shrank in place), and the next one that fits starts a new contiguous run.
    @Test func capHoldsEvenForOneOversizedSegment() {
        var ring = SegmentRing(bufferDuration: 1, byteCap: 10)
        let evicted = ring.append(segment(0, start: 0, bytes: 500))
        #expect(ring.segments.isEmpty)
        #expect(evicted.map(\.index) == [0])
        #expect(ring.totalBytes <= 10)
        _ = ring.append(segment(1, start: 1, bytes: 8))
        #expect(ring.segments.map(\.index) == [1])

        var shrinking = SegmentRing(bufferDuration: 30, byteCap: 5_000)
        for i in 0..<5 { _ = shrinking.append(segment(i, start: Double(i), bytes: 1_000)) }
        shrinking.byteCap = 900
        #expect(shrinking.evict().count == 5)
        #expect(shrinking.totalBytes <= 900)
    }

    @Test func newestSegmentWithinCapIsKept() {
        var ring = SegmentRing(bufferDuration: 1, byteCap: 1_000)
        _ = ring.append(segment(0, start: 0, bytes: 500))
        _ = ring.append(segment(1, start: 1, bytes: 900))
        #expect(ring.segments.map(\.index) == [1])
    }

    @Test func shrinkingBufferEvictsInPlace() {
        var ring = SegmentRing(bufferDuration: 60, byteCap: .max)
        for i in 0..<60 { _ = ring.append(segment(i, start: Double(i))) }
        ring.bufferDuration = 15
        let evicted = ring.evict()
        #expect(evicted.count == 45)
        #expect(ring.totalDuration == 15)
    }
}
