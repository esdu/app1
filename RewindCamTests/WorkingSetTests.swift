import AVFoundation
import Foundation
import Testing
@testable import RewindCam

// Issue #14: bounded queued fragment data and the full temporary media working set.
//
// * `WorkingSetPolicyTests`: the pure budgets (`BufferMath`, `DiskSpacePolicy.exportAdmission`), the ring's
//   strict cap and `TemporarySpace` reservations.
// * `WorkingSetRecorderTests`: a real `RollingRecorder` (RecorderHarness) with slow, failing or link-less
//   storage, and fragment callbacks driven straight into its writer delegate (bursts, oversized fragments).
//   Disk use is checked by enumerating the folders (`BufferStorage.measureWorkingSet`), queued data by the
//   recorder's admission counters, not `RecorderStatus.bytes`.
// * Model tests (in `AppModelTests`): what the user sees when the recorder halts or a save doesn't fit.

@Suite("Working-set policy")
struct WorkingSetPolicyTests {

    private static let defaults = RollingRecorder.Configuration(
        bufferSeconds: 30, preset: QualityPreset(resolution: .hd1080, frameRate: .fps30), audioEnabled: true)
    private static let biggest = RollingRecorder.Configuration(
        bufferSeconds: 120, preset: QualityPreset(resolution: .uhd4K, frameRate: .fps60), audioEnabled: true)

    private static var everySetting: [RollingRecorder.Configuration] {
        VideoResolution.allCases.flatMap { resolution in
            FrameRate.allCases.flatMap { rate in
                RecordingSettings.bufferChoices.map { seconds in
                    RollingRecorder.Configuration(bufferSeconds: seconds,
                                                  preset: QualityPreset(resolution: resolution, frameRate: rate),
                                                  audioEnabled: true)
                }
            }
        }
    }

    @Test("Queued fragments: 8 fragments, max(16 MB, 4 s at 1.5×), never one larger than the ring cap")
    func fragmentQueueLimits() {
        let defaults = BufferMath.fragmentQueueLimit(Self.defaults)
        #expect(defaults == FragmentQueueLimit(count: 8, bytes: 16_000_000, fragmentBytes: 16_000_000))
        // 4K60: 6.258 MB/s × 4 s × 1.5.
        let biggest = BufferMath.fragmentQueueLimit(Self.biggest)
        #expect(biggest == FragmentQueueLimit(count: 8, bytes: 37_548_000, fragmentBytes: 37_548_000))
        for configuration in Self.everySetting {
            let limit = BufferMath.fragmentQueueLimit(configuration)
            #expect(limit.fragmentBytes <= configuration.byteCap, "the ring can hold any admitted fragment")
            #expect(limit.fragmentBytes <= limit.bytes)
            // At least 2.5 nominal seconds per fragment: a normal ~1 s fragment is never refused alone.
            #expect(Double(limit.fragmentBytes) >= 2.5 * BufferMath.bytesPerSecond(configuration))
        }
        // Tiny test configurations keep the 16 MB floor but are still capped by their small ring.
        let tiny = RollingRecorder.Configuration(bufferDuration: 15, videoBitrate: 1_000_000, frameRate: 15, audioEnabled: false)
        #expect(BufferMath.fragmentQueueLimit(tiny).fragmentBytes == tiny.byteCap)
    }

    @Test("Temporary media cap: defaults ≈ 190 MB, 4K60 120 s +30 s ≈ 4.1 GB, as in DESIGN.md")
    func temporaryMediaCap() {
        // Defaults: ring 62.271 MB, save job (30 s + 0 s) 62.271 MB, export output 62.271 × 1.05 + 0.256 MB.
        #expect(BufferMath.saveBundleCapBytes(Self.defaults, postRollSeconds: 0) == 62_271_000)
        #expect(BufferMath.exportOutputBytes(sourceBytes: 62_271_000) == 65_640_550)
        #expect(BufferMath.temporaryMediaCapBytes(Self.defaults, postRollSeconds: 0) == 190_182_550)
        // 4K60: ring 1.155 GB, save job (150 s) 6.258 × 153 × 1.5 = 1.436 GB, output 1.508 GB.
        #expect(BufferMath.saveBundleCapBytes(Self.biggest, postRollSeconds: 30) == 1_436_211_000)
        #expect(BufferMath.temporaryMediaCapBytes(Self.biggest, postRollSeconds: 30) == 4_099_089_550)
        for configuration in Self.everySetting {
            for postRoll in RecordingSettings.postRollChoices.map(Double.init) {
                let cap = BufferMath.temporaryMediaCapBytes(configuration, postRollSeconds: postRoll)
                // The hard cap covers #10's nominal estimate of the same files (ring + save).
                let estimate = configuration.byteCap
                    + BufferMath.requiredBytesToSave(configuration, postRollSeconds: postRoll)
                #expect(cap >= estimate, "\(configuration) +\(postRoll) s")
                #expect(BufferMath.saveBundleCapBytes(configuration, postRollSeconds: postRoll) >= configuration.byteCap)
            }
        }
    }

    @Test("Export admission: unknown → all; partial → newest segments; nothing → how much to free")
    func exportAdmission() {
        let segments: [Int64] = [1_000_000, 2_000_000, 1_500_000, 1_000_000]
        let initBytes: Int64 = 2_000
        func peak(_ newest: Int) -> Int64 {
            BufferMath.exportPeakBytes(sourceBytes: initBytes + segments.suffix(newest).reduce(0, +))
        }
        let floor = DiskSpacePolicy.reserveBytes
        func admit(_ available: Int64?, floor: Int64 = DiskSpacePolicy.reserveBytes) -> ExportAdmission {
            DiskSpacePolicy.exportAdmission(initBytes: initBytes, segmentBytes: segments, availableBytes: available,
                                            floorBytes: floor)
        }
        #expect(admit(nil) == .all, "unknown free space never shortens a save")
        #expect(admit(floor + peak(4)) == .all)
        #expect(admit(floor + peak(4) - 1) == .newest(segments: 3))
        #expect(admit(floor + peak(2)) == .newest(segments: 2))
        #expect(admit(floor + peak(1)) == .newest(segments: 1))
        #expect(admit(floor + peak(1) - 10) == .none(bytesToFree: 10))
        #expect(admit(0) == .none(bytesToFree: peak(1) + floor))
        // Capture stopped: no reserve to keep, the save may use what is free.
        #expect(admit(peak(4), floor: DiskSpacePolicy.saveFloorBytes(captureRunning: false)) == .all)
        #expect(admit(peak(4), floor: DiskSpacePolicy.saveFloorBytes(captureRunning: true))
                == .none(bytesToFree: peak(1) - (peak(4) - floor)))
        #expect(DiskSpacePolicy.exportAdmission(initBytes: 0, segmentBytes: [], availableBytes: 0, floorBytes: floor) == .all,
                "an empty bundle is the exporter's error, not a space problem")
    }

    @Test("The save floor is #10's reserve while capture runs, nothing once it stopped")
    func saveFloor() {
        #expect(DiskSpacePolicy.saveFloorBytes(captureRunning: true) == BufferMath.reserveBytes)
        #expect(DiskSpacePolicy.saveFloorBytes(captureRunning: false) == 0)
    }

    @Test("TemporarySpace: reservations count against free space above the floor, and are released once")
    func temporarySpaceReservations() {
        let disk = FakeDiskCapacity(availableBytes: 100_000_000)
        let space = TemporarySpace(capacity: disk)
        #expect(space.unreservedBytes() == 100_000_000)
        let a = space.reserve(30_000_000, floor: 64_000_000)
        #expect(a != nil)
        #expect(space.unreservedBytes() == 70_000_000)
        #expect(space.reserve(10_000_000, floor: 64_000_000) == nil, "only 6 MB left above the floor")
        #expect(space.reserve(6_000_000, floor: 64_000_000) != nil, "exactly fits; released when dropped")
        #expect(space.reservedBytes == 30_000_000)
        a?.release()
        a?.release()
        #expect(space.reservedBytes == 0, "a second release gives nothing back twice")
        #expect(space.reserve(36_000_000, floor: 64_000_000) != nil)
        #expect(space.reservedBytes == 0)

        let unknown = TemporarySpace(capacity: FakeDiskCapacity(availableBytes: nil))
        let granted = unknown.reserve(.max / 2, floor: 64_000_000)
        #expect(granted != nil, "unknown free space grants, like the rest of the policy")
        #expect(unknown.unreservedBytes() == nil)
        let none = TemporarySpace(capacity: nil)
        #expect(none.reserve(1, floor: .max) != nil)
    }
}

// MARK: - Recorder

/// Storage the recorder writes through that a test can stall, fail, or deny hard links on.
final class TestStorage: @unchecked Sendable {
    // @unchecked: all state is behind `condition`.
    private let condition = NSCondition()
    private var holding = false
    private var blockedWrites = 0
    private var writeError: Error?
    private var noLinks = false
    private var writes = 0

    private func locked<R>(_ body: () throws -> R) rethrows -> R {
        condition.lock()
        defer { condition.unlock() }
        return try body()
    }

    var operations: MediaFileOperations {
        MediaFileOperations(
            link: { [self] source, destination in
                if linksFail { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.linkItem(at: source, to: destination)
            },
            writeFragment: { [self] data, url in try write(data, to: url) })
    }

    /// Writes wait (the recorder queue with them) until `release()`.
    func hold() { locked { holding = true } }
    func release() {
        locked {
            holding = false
            condition.broadcast()
        }
    }
    /// Every later write throws `error` (nil: writes work again).
    func failWrites(_ error: Error?) { locked { writeError = error } }
    var linksFail: Bool {
        get { locked { noLinks } }
        set { locked { noLinks = newValue } }
    }
    var writeCount: Int { locked { writes } }

    /// Returns once a write is waiting in `hold()`.
    func waitUntilBlocked(timeout: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while locked({ blockedWrites }) == 0 {
            if Date() > deadline { throw TimeoutError(description: "no write reached the held storage") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        let error: Error? = locked {
            while holding {
                blockedWrites += 1
                condition.wait()
                blockedWrites -= 1
            }
            writes += 1
            return writeError
        }
        if let error { throw error }
        try data.write(to: url)
    }
}

/// Free space = `total` minus what `folders` hold now, so copies really use it up. Unknown until `set`.
final class MeasuredDiskCapacity: DiskCapacityProvider {
    private let state = Locked<(total: Int64, folders: [URL])?>(nil)

    func set(total: Int64, measuring folders: [URL]) { state.withLock { $0 = (total, folders) } }

    func availableBytes() -> Int64? {
        guard let measured = state.current else { return nil }
        return measured.total - measured.folders.reduce(0) { $0 + FileBufferStorage.directorySize($1) }
    }
}

extension RecorderHarness {
    /// Feeds one fragment straight into the recorder's writer delegate, as `writer` would.
    func deliver(_ bytes: Int, from writer: AVAssetWriter) {
        recorder.assetWriter(writer, didOutputSegmentData: Data(count: bytes), segmentType: .separable,
                             segmentReport: nil)
    }

    var workingSet: MediaWorkingSet { storage.measureWorkingSet() }

    /// Returns once every fragment delivered so far has been handled on the recorder queue.
    func drain() { _ = recorder.activeWriter }

    func waitForHalt(timeout: Double = 30) async throws -> RecorderHalt {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let halt = recorder.status().halt { return halt }
            if Date() > deadline { throw TimeoutError(description: "the recorder never halted") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private func expectContiguous(_ bundle: SegmentBundle, sourceLocation: SourceLocation = #_sourceLocation) {
    let indices = bundle.segments.map(\.index)
    #expect(indices == Array((indices.first ?? 0)..<((indices.first ?? 0) + indices.count)),
            "segments \(indices) have a hole", sourceLocation: sourceLocation)
}

@Suite("Working set (recorder)", .serialized, .timeLimit(.minutes(5)))
struct WorkingSetRecorderTests {

    @Test("Slow storage and a burst of fragments: queued data stays within its bound, then the generation stops once")
    func burstAgainstSlowStorage() async throws {
        let storage = TestStorage()
        let h = RecorderHarness(buffer: 15, audio: false, fileOperations: storage.operations)
        h.source.generate(seconds: 4)
        try await h.waitForSegments(through: h.now - 2)
        let generation = h.recorder.status().generation
        let ticket = h.recorder.beginSave(postRoll: 10)
        let writer = try #require(h.recorder.activeWriter)
        let limit = h.recorder.fragmentQueue().limit
        #expect(limit.count == 8)

        // The next real segment's write stalls, and the recorder queue with it. Frames keep coming from
        // another thread (their appends wait behind that write, as capture's would).
        storage.hold()
        let source = h.source
        let feeder = Task.detached { source.generate(seconds: 2) }
        try await storage.waitUntilBlocked()

        // Meanwhile the writer keeps delivering fragments: never more than the bound is retained.
        for _ in 0..<40 {
            h.deliver(1_000_000, from: writer)
            let queued = h.recorder.fragmentQueue()
            #expect(queued.count <= limit.count)
            #expect(queued.bytes <= limit.bytes)
        }
        let during = h.recorder.fragmentQueue()
        #expect(during.peakCount == limit.count, "filled to the bound, not past it")
        #expect(during.rejected >= 40 - limit.count)
        #expect(!ticket.isFulfilled, "settled on the recorder queue, still behind the slow write")

        storage.release()
        await feeder.value
        let (status, files, bytes) = h.recorder.diskSnapshot()
        #expect(status.halt == .backlog)
        #expect(status.generation == 0)
        #expect(files.isEmpty && bytes == 0, "the stopped generation is deleted; later frames are ignored")
        let after = h.recorder.fragmentQueue()
        #expect(after.count == 0 && after.bytes == 0, "every admitted fragment released")

        // The pending save got the footage from before the overflow: contiguous and playable.
        let bundle = try await h.awaitBundle(ticket)
        defer { bundle.discard() }
        expectContiguous(bundle)
        #expect(bundle.clipEnd < bundle.requestedEnd, "settled early")
        let clip = try await ClipExporter.export(bundle)
        let info = try await inspectClip(clip.url)
        #expect(info.duration >= 3, "duration \(info.duration)")
        expectHealthyClip(info, frameRate: h.frameRate, audio: false)

        // Late callbacks from the stopped writer: admitted, dropped as stale, released. They can't
        // recreate its folder.
        for _ in 0..<3 { h.deliver(10_000, from: writer) }
        let late = h.recorder.diskSnapshot()
        #expect(late.segmentFiles.isEmpty)
        #expect(late.status.generation == 0)
        #expect(h.recorder.fragmentQueue().count == 0)
        #expect(!FileManager.default.fileExists(
            atPath: h.storage.bufferDirectory.appendingPathComponent("gen-\(generation)").path))

        // Halted: no automatic restart under the same shortage.
        h.source.generate(seconds: 2)
        #expect(h.recorder.status().generation == 0)
        #expect(h.recorder.status().halt == .backlog)

        // `resume()` (the app's Try Again) records again.
        h.recorder.resume()
        h.source.generate(seconds: 4)
        try await h.waitForSegments(through: h.now - 2)
        #expect(h.recorder.status().halt == nil)
        #expect(h.recorder.status().generation > generation)
    }

    @Test("A single fragment larger than the bound is never retained; the generation stops, the save settles")
    func singleOversizedFragment() async throws {
        let h = RecorderHarness(buffer: 15, audio: false)
        h.source.generate(seconds: 4)
        try await h.waitForSegments(through: h.now - 2)
        let ticket = h.recorder.beginSave(postRoll: 5)
        let writer = try #require(h.recorder.activeWriter)
        let limit = h.recorder.fragmentQueue().limit
        #expect(limit.fragmentBytes <= h.byteCap, "smaller than the ring cap here (\(h.byteCap) B)")

        h.deliver(Int(limit.fragmentBytes) + 1, from: writer)
        let queued = h.recorder.fragmentQueue()
        #expect(queued.count == 0 && queued.bytes == 0, "refused before it was queued")
        #expect(queued.rejected == 1)

        let (status, files, bytes) = h.recorder.diskSnapshot()
        #expect(status.halt == .backlog)
        #expect(files.isEmpty && bytes == 0)
        #expect(bytes <= h.byteCap)
        let bundle = try await h.awaitBundle(ticket)
        defer { bundle.discard() }
        expectContiguous(bundle)
        let clip = try await ClipExporter.export(bundle)
        let info = try await inspectClip(clip.url)
        #expect((1.5...4.5).contains(info.duration), "duration \(info.duration)")
        expectHealthyClip(info, frameRate: h.frameRate, audio: false)
    }

    @Test("A segment write fails (full disk): the generation stops instead of continuing with a hole")
    func writeFailureHalts() async throws {
        let storage = TestStorage()
        let h = RecorderHarness(buffer: 15, audio: true, fileOperations: storage.operations)
        h.source.generate(seconds: 5)
        try await h.waitForSegments(through: h.now - 2)
        let ticket = h.recorder.beginSave(postRoll: 10)

        storage.failWrites(CocoaError(.fileWriteOutOfSpace))
        h.source.generate(seconds: 3)
        guard case .writeFailed = try await h.waitForHalt() else {
            Issue.record("expected writeFailed, got \(String(describing: h.recorder.status().halt))")
            return
        }
        let (status, files, _) = h.recorder.diskSnapshot()
        #expect(status.generation == 0)
        #expect(files.isEmpty)
        #expect(status.halt?.message.contains("Free up space") == true)
        #expect(h.recorder.fragmentQueue().count == 0)

        let bundle = try await h.awaitBundle(ticket)
        defer { bundle.discard() }
        expectContiguous(bundle)
        let clip = try await ClipExporter.export(bundle)
        expectHealthyClip(try await inspectClip(clip.url), frameRate: h.frameRate, audio: true)

        // Space is back and the app tries again: recording works.
        storage.failWrites(nil)
        h.recorder.resume()
        h.source.generate(seconds: 4)
        try await h.waitForSegments(through: h.now - 2)
        #expect(h.recorder.status().halt == nil)
        #expect(h.recorder.status().segmentCount >= 2)
    }

    @Test("Hard links are counted once; a forced copy fallback is counted, measured from the files",
          arguments: [false, true])
    func linkOrCopyAccounting(forceCopy: Bool) async throws {
        let storage = TestStorage()
        storage.linksFail = forceCopy
        let h = RecorderHarness(buffer: 15, audio: true, fileOperations: storage.operations)
        h.source.generate(seconds: 8)
        try await h.waitForSegments(through: h.now - 2)
        let ticket = h.recorder.beginSave(postRoll: 0)
        h.source.generate(seconds: 2)
        let bundle = try await h.awaitBundle(ticket)
        let set = h.workingSet
        #expect(set.ringBytes > 0)
        if forceCopy {
            #expect(set.saveJobBytes == bundle.sourceBytes, "copies take their full size")
            #expect(set.temporaryBytes == set.ringBytes + bundle.sourceBytes)
        } else {
            #expect(set.saveJobBytes == 0, "every file in the job is a link to a ring file (nothing evicted yet)")
            #expect(set.temporaryBytes == set.ringBytes)
        }
        #expect(bundle.limit == nil)

        // Export into UnsavedClips like the app: the partial output is counted while it exists.
        let partial = try h.storage.partialClipURL(baseName: "linkOrCopy-\(forceCopy)")
        let clip = try await ClipExporter.export(bundle, to: partial,
                                                 outputByteLimit: BufferMath.exportOutputBytes(sourceBytes: bundle.sourceBytes))
        #expect(h.workingSet.exportBytes == FileBufferStorage.fileSize(partial))
        #expect(FileBufferStorage.fileSize(partial) <= BufferMath.exportOutputBytes(sourceBytes: bundle.sourceBytes))
        expectHealthyClip(try await inspectClip(clip.url), frameRate: h.frameRate, audio: true)
        bundle.discard()
        try FileManager.default.removeItem(at: partial)
        let cleaned = h.workingSet
        #expect(cleaned.saveJobBytes == 0 && cleaned.exportBytes == 0, "success cleanup leaves only the ring")
    }

    /// A harness whose saves must copy (no hard links) and whose free space shrinks as the copies land.
    private func copyingHarness() -> (RecorderHarness, MeasuredDiskCapacity) {
        let storage = TestStorage()
        storage.linksFail = true
        let disk = MeasuredDiskCapacity()
        let h = RecorderHarness(buffer: 15, audio: false, space: TemporarySpace(capacity: disk),
                                fileOperations: storage.operations)
        return (h, disk)
    }

    @Test("Copy fallback with little free space: the newest footage that fits, then the save settles early")
    func copyFallbackLimitedBySpace() async throws {
        let (h, disk) = copyingHarness()
        h.source.generate(seconds: 10)
        // Every segment the frames so far can produce has arrived (the next ends with the next frame).
        try await h.waitForSegments(through: h.now - 1.01)
        let ring = h.segmentFilesOnDisk.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let initFile = try #require(FileBufferStorage.files(in: h.storage.bufferDirectory, withExtension: "mp4").first)
        let newestThree = ring.suffix(3).reduce(0) { $0 + FileBufferStorage.fileSize($1) }
        // Room above the reserve for the init segment and the three newest segments, plus one byte.
        disk.set(total: DiskSpacePolicy.reserveBytes + FileBufferStorage.fileSize(initFile) + newestThree + 1,
                 measuring: [h.storage.clipsDirectory])

        let ticket = h.recorder.beginSave(postRoll: 0)
        h.source.generate(seconds: 2) // the segment with the tap: its copy no longer fits
        let bundle = try await h.awaitBundle(ticket)
        defer { bundle.discard() }
        #expect(bundle.limit == .freeSpace)
        #expect(bundle.segments.map(\.url.lastPathComponent) == ring.suffix(3).map(\.lastPathComponent),
                "the newest three, oldest dropped")
        expectContiguous(bundle)
        #expect(bundle.clipEnd < bundle.requestedEnd, "settled before the tap's segment")
        #expect((disk.availableBytes() ?? 0) >= DiskSpacePolicy.reserveBytes, "never into the reserve")
        let clip = try await ClipExporter.export(bundle)
        let info = try await inspectClip(clip.url)
        #expect(abs(info.duration - 3) <= 1, "duration \(info.duration)")
        expectHealthyClip(info, frameRate: h.frameRate, audio: false)
        #expect(h.recorder.status().halt == nil, "recording carries on")
    }

    @Test("Copy fallback with no room for even the newest segment: the save fails and leaves nothing")
    func copyFallbackNoRoom() async throws {
        let (h, disk) = copyingHarness()
        h.source.generate(seconds: 6)
        try await h.waitForSegments(through: h.now - 1.01)
        let initFile = try #require(FileBufferStorage.files(in: h.storage.bufferDirectory, withExtension: "mp4").first)
        disk.set(total: DiskSpacePolicy.reserveBytes + FileBufferStorage.fileSize(initFile),
                 measuring: [h.storage.clipsDirectory])
        let ticket = h.recorder.beginSave(postRoll: 0)
        await #expect(throws: StorageSpaceError.self) { try await ticket.bundle() }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: h.storage.clipsDirectory.path)) ?? []
        #expect(left.isEmpty, "job folder removed: \(left)")
        #expect(h.recorder.status().segmentCount > 0, "the ring is untouched")
        #expect(h.recorder.status().halt == nil)
    }

    @Test("Repeated saves exported while capture continues stay within the temporary-media cap, then clean up")
    func exportsWhileCapturing() async throws {
        let h = RecorderHarness(buffer: 15, audio: true)
        let configuration = h.recorder.currentConfiguration
        let cap = BufferMath.temporaryMediaCapBytes(configuration, postRollSeconds: 2)
        h.source.generate(seconds: 16)
        try await h.waitForSegments(through: h.now - 2)
        for round in 0..<3 {
            let ticket = h.recorder.beginSave(postRoll: 2)
            h.source.generate(seconds: 3.5)
            let bundle = try await h.awaitBundle(ticket)
            #expect(bundle.limit == nil)
            #expect(bundle.sourceBytes <= BufferMath.saveBundleCapBytes(configuration, postRollSeconds: 2))
            let partial = try h.storage.partialClipURL(baseName: "round-\(round)")
            let outputLimit = BufferMath.exportOutputBytes(sourceBytes: bundle.sourceBytes)
            async let exported = ClipExporter.export(bundle, to: partial, outputByteLimit: outputLimit)
            var peak = h.workingSet.temporaryBytes
            for _ in 0..<6 {
                h.source.generate(seconds: 0.5) // capture continues during the export
                peak = max(peak, h.workingSet.temporaryBytes)
            }
            let clip = try await exported
            peak = max(peak, h.workingSet.temporaryBytes)
            #expect(peak <= cap, "round \(round): peak \(peak) cap \(cap)")
            #expect(FileBufferStorage.fileSize(partial) <= outputLimit)
            let info = try await inspectClip(clip.url)
            #expect(abs(info.duration - 17) <= 1.5, "round \(round): duration \(info.duration)")
            expectHealthyClip(info, frameRate: h.frameRate, audio: true)
            bundle.discard()
            try FileManager.default.removeItem(at: partial)
            let after = h.workingSet
            #expect(after.saveJobBytes == 0 && after.exportBytes == 0 && after.stagingBytes == 0)
            #expect(after.ringBytes <= configuration.byteCap)
        }
        let queue = h.recorder.fragmentQueue()
        #expect(queue.rejected == 0, "healthy storage never reaches the bound")
        #expect(queue.peakCount <= queue.limit.count)
        #expect(h.recorder.status().halt == nil)
    }

    @Test("Source concatenation fails (a segment is gone): nothing is exported, discarding leaves nothing")
    func sourceCopyFailureCleansUp() async throws {
        let h = RecorderHarness(buffer: 15, audio: false)
        h.source.generate(seconds: 6)
        try await h.waitForSegments(through: h.now - 2)
        let ticket = h.recorder.beginSave(postRoll: 0)
        h.source.generate(seconds: 2)
        let bundle = try await h.awaitBundle(ticket)
        try FileManager.default.removeItem(at: bundle.segments[1].url)
        let partial = try h.storage.partialClipURL(baseName: "broken")
        await #expect(throws: (any Error).self) { try await ClipExporter.export(bundle, to: partial) }
        #expect(!FileManager.default.fileExists(atPath: partial.path), "no output was started")
        bundle.discard()
        let set = h.workingSet
        #expect(set.saveJobBytes == 0 && set.exportBytes == 0)
        #expect(h.recorder.status().halt == nil, "recording is unaffected")
    }

    /// Feeds `fragments` of about `overshoot ×` the nominal rate (VBR 0.5–1.5×) into the current writer,
    /// handling each before the next, as healthy storage does.
    private struct FragmentFeed {
        let perSecond: Double
        let overshoot: Double
        var n = 0

        mutating func next() -> Int {
            n += 1
            let vbr = 0.5 + Double((n * 37) % 101) / 100
            return max(1, Int(perSecond * vbr * overshoot))
        }
    }

    /// One soak run: fill the ring, save with `postRoll`, and check every bound by enumeration.
    private func soak(_ preset: QualityPreset, bufferSeconds: Int, postRoll: Int, overshoot: Double = 1)
        async throws -> (bundleLimit: SaveLimit?, ringSeconds: Double) {
        let label = "\(preset), \(bufferSeconds) s, +\(postRoll) s, ×\(overshoot)"
        let h = RecorderHarness(buffer: Double(bufferSeconds), audio: false, videoBitrate: preset.videoBitrate / 100)
        let configuration = h.recorder.currentConfiguration
        h.source.generate(seconds: 2)
        try await h.waitForSegments(through: 0.99)
        let writer = try #require(h.recorder.activeWriter)
        var feed = FragmentFeed(perSecond: BufferMath.bytesPerSecond(configuration), overshoot: overshoot)

        for i in 0..<(bufferSeconds + 5) {
            h.deliver(feed.next(), from: writer)
            h.drain()
            if i % 10 == 0 {
                let (status, files, bytes) = h.recorder.diskSnapshot()
                #expect(bytes <= configuration.byteCap, "\(label): ring \(bytes)")
                #expect(files.count == status.segmentCount, "\(label): files on disk = ring")
            }
        }
        let filled = h.recorder.diskSnapshot()
        #expect(filled.bytes <= configuration.byteCap, "\(label)")
        if overshoot <= 1 {
            #expect(filled.status.bufferedSeconds >= Double(bufferSeconds), "\(label): \(filled.status.bufferedSeconds) s")
        }

        let ticket = h.recorder.beginSave(postRoll: Double(postRoll))
        var extra = 0
        while !ticket.isFulfilled, extra < postRoll + 10 {
            h.deliver(feed.next(), from: writer)
            h.drain()
            extra += 1
        }
        let bundle = try await h.awaitBundle(ticket, timeout: 5)
        defer { bundle.discard() }
        let bundleCap = BufferMath.saveBundleCapBytes(configuration, postRollSeconds: Double(postRoll))
        let set = h.workingSet
        #expect(set.ringBytes <= configuration.byteCap, "\(label)")
        #expect(bundle.sourceBytes <= bundleCap, "\(label): save job \(bundle.sourceBytes) cap \(bundleCap)")
        #expect(set.saveJobBytes <= bundleCap, "\(label)")
        // With the export peak on top (concatenated source + output), still within the whole cap.
        #expect(set.ringBytes + bundle.sourceBytes + BufferMath.exportOutputBytes(sourceBytes: bundle.sourceBytes)
                <= BufferMath.temporaryMediaCapBytes(configuration, postRollSeconds: Double(postRoll)), "\(label)")
        expectContiguous(bundle)

        let queue = h.recorder.fragmentQueue()
        #expect(queue.count == 0 && queue.bytes == 0, "\(label)")
        #expect(queue.rejected == 0, "\(label)")
        #expect(queue.peakCount <= queue.limit.count && queue.peakBytes <= queue.limit.bytes, "\(label)")
        #expect(h.recorder.status().halt == nil, "\(label)")
        return (bundle.limit, h.recorder.status().bufferedSeconds)
    }

    @Test("Soak: every preset and buffer length, +30 s post-roll (bitrates ÷100): ring, save and queue stay bounded")
    func soakEveryPresetAndBuffer() async throws {
        for resolution in VideoResolution.allCases {
            for rate in FrameRate.allCases {
                for seconds in RecordingSettings.bufferChoices {
                    let result = try await soak(QualityPreset(resolution: resolution, frameRate: rate),
                                                bufferSeconds: seconds, postRoll: 30)
                    #expect(result.bundleLimit == nil, "\(resolution) \(rate) \(seconds) s: nothing cut")
                }
            }
        }
    }

    @Test("Encoder far over its bitrate (8×) at 4K60: the ring keeps its cap and the save stops at its own")
    func soakOvershootingEncoder() async throws {
        let result = try await soak(QualityPreset(resolution: .uhd4K, frameRate: .fps60), bufferSeconds: 15,
                                    postRoll: 30, overshoot: 8)
        #expect(result.bundleLimit == .workingSetCap)
        #expect(result.ringSeconds < 15, "the byte cap wins over the duration")
    }
}


// MARK: - Model

/// Model tests: in the `AppModelTests` suite so they share its serialization and time limit.
@MainActor
extension AppModelTests {

    private func keptClipFile(_ h: ModelHarness, bytes: Int = 1_000_000) throws -> URL {
        try FileManager.default.createDirectory(at: h.storage.unsavedDirectory, withIntermediateDirectories: true)
        let url = h.storage.unsavedDirectory.appendingPathComponent("RewindCam 2026-11-02 kept.mov")
        try Data(count: bytes).write(to: url)
        return url
    }

    private func folderContents(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// Hands the recorder a fragment larger than its bound, as an encoder overshoot would.
    private func overflowRecorder(_ model: AppModel) throws {
        let writer = try #require(model.recorder.activeWriter)
        let limit = model.recorder.fragmentQueue().limit
        model.recorder.assetWriter(writer, didOutputSegmentData: Data(count: Int(limit.fragmentBytes) + 1),
                                   segmentType: .separable, segmentReport: nil)
        #expect(model.recorder.fragmentQueue().bytes == 0, "never retained")
        _ = model.recorder.activeWriter // the recorder queue has handled it
    }

    @Test("Recorder overflow while recording: Not recording with Try Again, the pending save delivers once, no loop")
    func recorderOverflowStopsCapture() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let kept = try keptClipFile(h)
        let model = h.makeModel()
        model.updateSettings { $0.postRollSeconds = 10 }
        model.start()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        h.screen.brightness = 0.7
        model.setDimmed(true)
        h.source.generate(seconds: 4)
        let task = try #require(model.save())

        try overflowRecorder(model)
        #expect(model.recorder.status().halt == .backlog)
        await passTime(0.5, model, h) // the next status tick
        #expect(model.phase == .failed(RecorderHalt.backlog.message))
        let notice = try #require(model.startFailureNotice)
        #expect(notice.action == .tryAgain)
        #expect(notice.message.contains("faster than it could be stored"))
        #expect(h.source.runState == .stopped)
        #expect(!model.isDimmed, "woken so the notice can be seen")
        #expect(!h.screen.idleTimerDisabled)

        await task.value
        #expect(h.library.clips().count == 1, "the footage from before the overflow is saved")
        #expect(model.toast?.message.contains("It ends early") == true, "toast: \(String(describing: model.toast))")
        #expect(!model.isSaving)
        #expect(h.haptics.failures == 1)
        #expect(FileManager.default.fileExists(atPath: kept.path), "a kept clip is never touched")

        // Bounded: nothing restarts on its own.
        let starts = h.source.startCount
        await passTime(30, model, h)
        #expect(h.source.startCount == starts)
        #expect(model.phase == .failed(RecorderHalt.backlog.message))

        model.retryStart()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(model.recorder.status().halt == nil)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Recorder halt with free space below the reserve is the out-of-space stop")
    func recorderHaltWithLowDiskIsOutOfSpace() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.disk.set(5_000_000_000)
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        h.source.generate(seconds: 3)
        try overflowRecorder(model)
        h.disk.set(50_000_000)
        await passTime(0.5, model, h) // not the 5 s free-space check: the halt is acted on at once
        guard case .outOfSpace(let check) = model.phase else {
            Issue.record("expected outOfSpace, got \(model.phase)")
            return
        }
        #expect(check.level == .tooLow)
        #expect(model.startFailureNotice?.id == "lowDiskBanner")
    }

    @Test("A save that only partly fits the free space exports its newest part and says so")
    func saveShortenedToFreeSpace() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let kept = try keptClipFile(h)
        h.disk.set(5_000_000_000)
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        h.source.generate(seconds: 8)
        _ = model.recorder.activeWriter
        let ring = model.recorder.status().bytes
        #expect(ring > 0)
        // Room above the reserve (capture is running) for the export of about half the footage.
        h.disk.set(DiskSpacePolicy.reserveBytes + BufferMath.exportPeakBytes(sourceBytes: ring / 2))

        let task = try #require(model.save(), "a save is never refused for space")
        #expect(model.toast?.isWarning == true, "#10's warning first")
        h.source.generate(seconds: 2)
        await task.value

        let clip = try #require(h.library.clips().first)
        let duration = try await AVURLAsset(url: clip).load(.duration).seconds
        #expect(duration >= 1 && duration < 7, "about half of ~9 s; got \(duration)")
        let toast = try #require(model.toast)
        #expect(toast.message.hasPrefix("Saved \(Int(duration.rounded())) s clip to Photos. "))
        #expect(toast.message.contains(AppModel.shortenedSentence(.freeSpace)), "toast: \(toast.message)")
        #expect(!toast.isError)
        #expect(folderContents(h.storage.clipsDirectory).isEmpty)
        #expect(folderContents(h.storage.unsavedDirectory) == [kept.lastPathComponent])
        #expect(model.temporarySpace.reservedBytes == 0, "the export's reservation is released")
        #expect(model.phase == .recording)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("A save with no room for even its last second writes nothing and says how much to free")
    func saveWithNoRoomFails() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let kept = try keptClipFile(h)
        h.disk.set(5_000_000_000)
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        h.source.generate(seconds: 5)
        h.disk.set(DiskSpacePolicy.reserveBytes + 1_000) // recording can go on, a save can't fit

        let task = try #require(model.save())
        h.source.generate(seconds: 2)
        await task.value
        #expect(h.library.clips().isEmpty)
        let toast = try #require(model.toast)
        #expect(toast.isError)
        #expect(toast.message.hasPrefix("Nothing was saved: there isn't enough free space to export even the last second."))
        #expect(toast.message.contains("Free up about"))
        #expect(!toast.message.contains("Storage is low: free up space"), "said once: \(toast.message)")
        #expect(h.haptics.failures == 1)
        #expect(!model.isSaving)
        #expect(folderContents(h.storage.clipsDirectory).isEmpty, "the job folder is discarded")
        #expect(folderContents(h.storage.unsavedDirectory) == [kept.lastPathComponent], "no partial export")
        #expect(model.unsavedClips.count == 1, "the kept clip is still offered, never evicted")
        #expect(model.temporarySpace.reservedBytes == 0)
        #expect(model.phase == .recording)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Free-space reads are net of a running save's reservation; Settings measures the working set")
    func freeSpaceNetOfReservationsAndWorkingSet() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        _ = try keptClipFile(h)
        h.disk.set(1_000_000_000)
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        h.source.generate(seconds: 6)
        _ = model.recorder.activeWriter

        model.refreshDiskSpace()
        #expect(model.availableDiskBytes == 1_000_000_000)
        let set = model.workingSet
        #expect(set.keptClipBytes == 1_000_000, "kept clips are reported, separately")
        #expect(set.ringBytes > 0)
        #expect(set.saveJobBytes == 0 && set.exportBytes == 0 && set.stagingBytes == 0)
        #expect(set.temporaryBytes == set.ringBytes)
        // Defaults (1080p30, 30 s, sound, no post-roll), as in DESIGN.md.
        #expect(model.temporaryMediaCapBytes == 190_182_550)
        #expect(set.temporaryBytes <= model.temporaryMediaCapBytes)

        let reservation = try #require(model.temporarySpace.reserve(300_000_000, floor: DiskSpacePolicy.reserveBytes))
        model.refreshDiskSpace()
        #expect(model.availableDiskBytes == 700_000_000, "a running export's bytes count as used")
        reservation.release()
        model.refreshDiskSpace()
        #expect(model.availableDiskBytes == 1_000_000_000)
        model.stop()
        await model.waitForPipeline()
    }
}
