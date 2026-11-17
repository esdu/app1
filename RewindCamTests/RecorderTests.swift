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

    /// Issue #3 regression: the writer has an AAC input but the source delivers only video, which is
    /// what happened when the microphone was denied with "Record sound" on. Pins down what
    /// AVAssetWriter does then, and so why `RollingRecorder.Configuration.audioEnabled` must follow
    /// what the source captures (`ActiveCapture.audioCaptured`), not the setting.
    /// Runs both with real-time inputs (as in the app) and non-real-time ones (as in the other tests).
    @Test("Writer audio input that is never fed: no segments are emitted and nothing can be saved",
          arguments: [true, false])
    func writerAudioInputWithoutSamples(realTime: Bool) async throws {
        // A short append wait: a stalled non-real-time input would otherwise block each frame for 10 s.
        let h = RecorderHarness(buffer: 30, audio: true, sourceAudio: false, realTime: realTime, appendWaitLimit: 0.05)
        h.source.generate(seconds: 6)
        // A healthy writer delivers segments within milliseconds; give this one far longer.
        let deadline = Date().addingTimeInterval(3)
        while h.recorder.status().lastSegmentEnd == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let (status, files, _) = h.recorder.diskSnapshot()
        let observed = "realTime \(realTime): segments \(status.segmentCount), buffered \(status.bufferedSeconds) s, "
            + "last segment end \(String(describing: status.lastSegmentEnd)), "
            + "last video appended \(String(describing: status.latestMediaTime)), error \(String(describing: status.lastError))"
        #expect(status.segmentCount == 0, "\(observed)")
        #expect(files.isEmpty, "\(observed)")
        #expect(status.bufferedSeconds == 0, "\(observed)")
        let ticket = h.recorder.beginSave(postRoll: 0)
        await #expect(throws: RecorderError.nothingBuffered) { try await ticket.bundle() }

        // Control, same mode and same frames: without the audio input the writer emits segments. So the
        // stall above is caused by the unfed audio input alone. The frames are fed paced, as a camera
        // feeds a writer that keeps up: a back-to-back burst into the real-time writer dropped as many
        // frames as the machine's load made it, and under the stress run's load sometimes every frame
        // that would have closed the second segment, so the wait below timed out (the flake).
        var config = h.recorder.currentConfiguration
        config.audioEnabled = false
        config.appendWaitLimit = 10
        h.recorder.reconfigure(config)
        let controlStart = h.now
        try await h.generatePaced(seconds: 6)
        #expect(abs(h.now - controlStart - 6) < 1e-6, "6 s of frames, one per step")
        let lastFrame = h.now - 1 / Double(h.frameRate)
        #expect(abs((h.recorder.status().latestMediaTime ?? -1) - lastFrame) < 1e-6,
                "every paced frame is appended, none dropped; \(h.diagnostics)")
        try await h.waitForSegments(through: controlStart + 2)

        // The fix as AppModel applies it: a writer without audio yields a clean, playable clip.
        try await h.waitForSegments(through: h.now - 2)
        #expect(h.recorder.status().bufferedSeconds >= 3)
        let clip = try await h.saveClip(thenRecord: 2, paced: true)
        let info = try await inspectClip(clip.url)
        #expect(info.duration >= 3, "duration \(info.duration)")
        expectHealthyClip(info, frameRate: h.frameRate, audio: false)
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
