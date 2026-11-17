import AVFoundation
import Foundation
import Testing
@testable import RewindCam

// TEMPORARY (reproduction of the stress-run flake; removed before merge).
// The control phase of `writerAudioInputWithoutSamples(realTime: true)` under induced CPU load:
// `burst` is the old harness (back-to-back frames into a real-time writer), `paced` the new one.

private final class CPUBurners: @unchecked Sendable {
    private let stop = Locked(false)
    init(_ count: Int) {
        for _ in 0..<count {
            let thread = Thread { [stop] in
                var x = 0.0
                while !stop.current { for i in 0..<10_000 { x += sin(Double(i)) } }
                _ = x
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
    func end() { stop.withLock { $0 = true } }
}

@Suite("TEMP flake repro", .serialized, .timeLimit(.minutes(10)))
struct TempFlakeRepro {

    @Test("burst into a real-time writer under load", arguments: [0, 4, 8, 16])
    func burst(burners: Int) async throws {
        let load = CPUBurners(burners)
        defer { load.end() }
        let h = RecorderHarness(buffer: 30, audio: false, realTime: true)
        let start = h.now
        h.source.generate(seconds: 6)
        print("TEMPDIAG burst burners=\(burners) after generate: \(h.diagnostics)")
        try await h.waitForSegments(through: start + 2)
    }

    @Test("paced into a real-time writer under load", arguments: [0, 4, 8, 16])
    func paced(burners: Int) async throws {
        let load = CPUBurners(burners)
        defer { load.end() }
        let h = RecorderHarness(buffer: 30, audio: false, realTime: true)
        let start = h.now
        try await h.generatePaced(seconds: 6)
        print("TEMPDIAG paced burners=\(burners) after generate: \(h.diagnostics)")
        #expect(abs((h.recorder.status().latestMediaTime ?? -1) - (h.now - 1 / Double(h.frameRate))) < 1e-6,
                "\(h.diagnostics)")
        try await h.waitForSegments(through: start + 2)
        try await h.waitForSegments(through: h.now - 2)
        let clip = try await h.saveClip(thenRecord: 2, paced: true)
        let info = try await inspectClip(clip.url)
        #expect(info.duration >= 3, "duration \(info.duration)")
        expectHealthyClip(info, frameRate: h.frameRate, audio: false)
    }
}
