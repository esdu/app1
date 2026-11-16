import AVFoundation
import Foundation
import Testing
@testable import RewindCam

/// End-to-end tests of the real writer → ring → exporter path, fed by synthetic frames.
/// Serialized: they encode video and are heavier than the rest.
@Suite("Rolling recorder", .serialized, .timeLimit(.minutes(5)))
struct RecorderTests {

    @Test("300 s of frames with a 30 s buffer keeps ~30 s on disk, under the cap")
    func ringEvictionAfter300Seconds() async throws {
        let h = RecorderHarness(buffer: 30, audio: false)
        var maxBytes: Int64 = 0
        for _ in 0..<10 {
            h.source.generate(seconds: 30)
            let bytes = h.recorder.diskSnapshot().bytes
            maxBytes = max(maxBytes, bytes)
            #expect(bytes <= h.byteCap)
        }
        let now = h.now
        #expect(abs(now - h.source.nextVideoPTS.seconds) < 0.001)
        try await h.waitForSegments(through: now - 2)

        let (status, files, bytes) = h.recorder.diskSnapshot()
        #expect(status.bufferedSeconds >= 30, "buffered \(status.bufferedSeconds)")
        #expect(status.bufferedSeconds < 32, "buffered \(status.bufferedSeconds)")
        // Only the retained segments exist on disk: nothing leaked.
        #expect(files.count == status.segmentCount)
        #expect(status.segmentCount >= 28 && status.segmentCount <= 34, "segments \(status.segmentCount)")
        #expect(bytes <= h.byteCap, "disk \(bytes) cap \(h.byteCap)")
        #expect(maxBytes <= h.byteCap)
        #expect(status.lastSegmentEnd! > now - 3)
    }

    @Test("Save produces a playable clip as long as the buffer (±1 s)")
    func clipDurationMatchesBuffer() async throws {
        let h = RecorderHarness(buffer: 30, audio: true)
        h.source.generate(seconds: 45)
        let clip = try await h.saveClip(thenRecord: 2)
        let info = try await inspectClip(clip.url)
        #expect(abs(info.duration - 30) <= 1, "duration \(info.duration)")
        expectHealthyClip(info, frameRate: h.frameRate, audio: true)
    }

    @Test("Post-roll: clip covers buffer + post-roll (±1 s)")
    func postRollExtendsClip() async throws {
        let h = RecorderHarness(buffer: 15, audio: true)
        h.source.generate(seconds: 25)
        let ticket = h.recorder.beginSave(postRoll: 5)
        #expect(!ticket.isFulfilled)
        h.source.generate(seconds: 3)
        // Only 3 of the 5 post-roll seconds exist yet: the save must still be waiting.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!ticket.isFulfilled)
        h.source.generate(seconds: 4)
        let bundle = try await h.awaitBundle(ticket)
        defer { bundle.discard() }
        let clip = try await ClipExporter.export(bundle)
        let info = try await inspectClip(clip.url)
        #expect(abs(info.duration - 20) <= 1, "duration \(info.duration)")
        expectHealthyClip(info, frameRate: h.frameRate, audio: true)
    }

    @Test("Saving before the buffer is full returns whatever exists")
    func earlySaveReturnsWhatExists() async throws {
        let h = RecorderHarness(buffer: 30, audio: true)
        h.source.generate(seconds: 4)
        let clip = try await h.saveClip(thenRecord: 2)
        let info = try await inspectClip(clip.url)
        #expect(abs(info.duration - 4) <= 1, "duration \(info.duration)")
        #expect(info.duration < 30)
        expectHealthyClip(info, frameRate: h.frameRate, audio: true)
    }

    @Test("Save with nothing buffered fails cleanly")
    func saveWithNothingBuffered() async throws {
        let h = RecorderHarness(buffer: 30, audio: false)
        let ticket = h.recorder.beginSave(postRoll: 0)
        await #expect(throws: RecorderError.nothingBuffered) { try await ticket.bundle() }
        #expect(FileBufferStorage.directorySize(h.storage.clipsDirectory) == 0)
    }

    @Test("Interruption resets the buffer; later clips are valid")
    func interruptionResetsBuffer() async throws {
        let h = RecorderHarness(buffer: 30, audio: true)
        h.source.generate(seconds: 10)
        try await h.waitForSegments(through: h.now - 2)
        #expect(h.recorder.status().bufferedSeconds > 5)

        h.recorder.suspend()
        let status = h.recorder.status()
        #expect(status.bufferedSeconds == 0)
        #expect(status.segmentCount == 0)
        #expect(status.isSuspended)
        #expect(h.segmentFilesOnDisk.isEmpty)
        #expect(h.bufferBytesOnDisk == 0)

        // No clip can come out of an empty, interrupted buffer.
        let ticket = h.recorder.beginSave(postRoll: 0)
        await #expect(throws: RecorderError.nothingBuffered) { try await ticket.bundle() }

        // Frames arriving while suspended are ignored.
        h.source.generate(seconds: 2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.recorder.status().bufferedSeconds == 0)

        // Resume after a gap: a fresh generation, and a clean clip of only the new footage.
        h.recorder.resume()
        h.source.skip(seconds: 5)
        h.source.generate(seconds: 6)
        let clip = try await h.saveClip(thenRecord: 2)
        let info = try await inspectClip(clip.url)
        #expect(abs(info.duration - 6) <= 1, "duration \(info.duration)")
        expectHealthyClip(info, frameRate: h.frameRate, audio: true)
    }

    @Test("Interruption during post-roll yields a valid clip of what was captured")
    func interruptionDuringPendingSave() async throws {
        let h = RecorderHarness(buffer: 30, audio: true)
        h.source.generate(seconds: 8)
        let tap = h.now
        let ticket = h.recorder.beginSave(postRoll: 10)
        h.source.generate(seconds: 2)
        try await h.waitForSegments(through: tap + 0.5)
        h.recorder.suspend()

        let bundle = try await h.awaitBundle(ticket)
        defer { bundle.discard() }
        #expect(bundle.clipEnd < tap + 10, "resolved early, before the post-roll finished")
        let clip = try await ClipExporter.export(bundle)
        let info = try await inspectClip(clip.url)
        #expect(info.duration > 7 && info.duration <= 10.5, "duration \(info.duration)")
        #expect(abs(info.duration - bundle.clipDuration) <= 1)
        expectHealthyClip(info, frameRate: h.frameRate, audio: true)
    }

    @Test("Shortening the buffer applies in place without restarting")
    func bufferShrinkInPlace() async throws {
        let h = RecorderHarness(buffer: 30, audio: false)
        h.source.generate(seconds: 40)
        try await h.waitForSegments(through: h.now - 2)
        let generation = h.recorder.status().generation
        var config = h.recorder.currentConfiguration
        config.bufferDuration = 15
        h.recorder.reconfigure(config)
        let (status, files, _) = h.recorder.diskSnapshot()
        #expect(status.generation == generation)
        #expect(status.bufferedSeconds >= 15 && status.bufferedSeconds < 17, "buffered \(status.bufferedSeconds)")
        #expect(files.count == status.segmentCount)
    }

    @Test("Only one save can be pending at a time")
    func secondSaveWhilePendingIsRejected() async throws {
        let h = RecorderHarness(buffer: 15, audio: false)
        h.source.generate(seconds: 5)
        let first = h.recorder.beginSave(postRoll: 5)
        let second = h.recorder.beginSave(postRoll: 0)
        await #expect(throws: RecorderError.alreadySaving) { try await second.bundle() }
        h.source.generate(seconds: 7)
        let bundle = try await h.awaitBundle(first)
        bundle.discard()
    }
}
