import AVFoundation
import Foundation
import Testing
@testable import RewindCam

struct TimeoutError: Error, CustomStringConvertible {
    let description: String
}

/// A real `RollingRecorder` fed by a manual `SyntheticFrameSource` in a private temp folder.
final class RecorderHarness {
    let root: URL
    let storage: FileBufferStorage
    let recorder: RollingRecorder
    let source: SyntheticFrameSource
    let frameRate: Int

    /// `audio` configures the writer; `sourceAudio` (default: same) whether the source emits audio.
    /// `space` and `fileOperations` (issue #14): free space for copies when links fail, and the
    /// storage the recorder writes through (tests make it slow, failing, or link-less).
    init(buffer: Double, audio: Bool, sourceAudio: Bool? = nil, frameRate: Int = 15, width: Int = 320,
         height: Int = 180, videoBitrate: Int = 1_000_000, realTime: Bool = false, appendWaitLimit: Double = 10,
         space: TemporarySpace? = nil, fileOperations: MediaFileOperations = .live) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindCamTests-\(UUID().uuidString)", isDirectory: true)
        storage = FileBufferStorage(root: root)
        storage.removeOrphans() // creates the folders
        self.frameRate = frameRate
        var configuration = RollingRecorder.Configuration(bufferDuration: buffer, videoBitrate: videoBitrate,
                                                          frameRate: frameRate, audioEnabled: audio,
                                                          realTime: realTime)
        configuration.appendWaitLimit = appendWaitLimit
        recorder = RollingRecorder(
            bufferDirectory: storage.bufferDirectory,
            clipsDirectory: storage.clipsDirectory,
            configuration: configuration,
            space: space,
            fileOperations: fileOperations)
        source = SyntheticFrameSource(
            format: .init(width: width, height: height, frameRate: frameRate, audioEnabled: sourceAudio ?? audio),
            mode: .manual)
        source.setSink(recorder)
    }

    deinit {
        // Stop the writer deterministically before deleting its folder.
        source.setSink(nil)
        recorder.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    /// Media time of the next frame (i.e. "now" on the synthetic timeline).
    var now: Double { source.nextVideoPTS.seconds }

    var segmentFilesOnDisk: [URL] { FileBufferStorage.files(in: storage.bufferDirectory, withExtension: "m4s") }
    var bufferBytesOnDisk: Int64 { FileBufferStorage.directorySize(storage.bufferDirectory) }
    var byteCap: Int64 { recorder.currentConfiguration.byteCap }

    /// Segments are delivered asynchronously by the writer; wait until one ends at/after `t`.
    func waitForSegments(through t: Double, timeout: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while (recorder.status().lastSegmentEnd ?? -.infinity) < t {
            if Date() > deadline {
                throw TimeoutError(description: "no segment through \(t); \(diagnostics)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The recorder's state, for failure messages: enough to tell a halted, stalled or idle writer apart.
    var diagnostics: String {
        let s = recorder.status()
        let q = recorder.fragmentQueue()
        return "last segment end \(String(describing: s.lastSegmentEnd)), last video appended "
            + "\(String(describing: s.latestMediaTime)), next frame \(now), segments \(s.segmentCount), "
            + "generation \(s.generation), halt \(String(describing: s.halt)), error \(String(describing: s.lastError)), "
            + "fragments queued \(q.count) (peak \(q.peakCount), admitted \(q.admitted), rejected \(q.rejected))"
    }

    /// Feeds `seconds` of frames the way a camera does to a writer that keeps up with it: each video frame
    /// only once the writer's video input is ready for it. Use it with `realTime: true`. A real-time input
    /// drops a frame it isn't ready for (`RollingRecorder.waitUntilReady`), and a back-to-back burst
    /// (`source.generate`) outruns the encoder by however much the machine's load allows, so how many
    /// frames survive, and so which segments exist, would vary from run to run. Paced, no frame is
    /// dropped and the segments are the ones the offline writer produces.
    func generatePaced(seconds: Double) async throws {
        // As many frames as `source.generate(seconds:)` emits (counted, not compared with `now`, which only
        // means something once the source's timeline has started).
        for _ in 0..<Int((seconds * Double(frameRate)).rounded()) {
            try await waitUntilVideoInputReady()
            source.generate(seconds: 1 / Double(frameRate)) // exactly one video frame (and the audio up to it)
        }
    }

    /// Returns once the current writer's video input takes more data (at once if there is no writing
    /// writer: the next frame starts one, or is handled as a writer failure).
    func waitUntilVideoInputReady(timeout: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while let writer = recorder.activeWriter, writer.status == .writing,
              let input = writer.inputs.first(where: { $0.mediaType == .video }), !input.isReadyForMoreMediaData {
            if Date() > deadline {
                throw TimeoutError(description: "the video input never became ready; \(diagnostics)")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Save with `postRoll`, keep "recording" `extra` seconds (`paced`: as `generatePaced`), then export.
    func saveClip(postRoll: Double = 0, thenRecord extra: Double, paced: Bool = false) async throws -> ExportedClip {
        let ticket = recorder.beginSave(postRoll: postRoll)
        if paced {
            try await generatePaced(seconds: extra)
        } else {
            source.generate(seconds: extra)
        }
        let bundle = try await awaitBundle(ticket)
        defer { bundle.discard() }
        return try keep(try await ClipExporter.export(bundle))
    }

    /// Moves an exported clip out of its save folder (which `discard()` deletes).
    func keep(_ clip: ExportedClip) throws -> ExportedClip {
        let dir = root.appendingPathComponent("KeptClips", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(clip.url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: clip.url, to: dest)
        return ExportedClip(url: dest, duration: clip.duration)
    }

    func awaitBundle(_ ticket: SaveTicket, timeout: Double = 60) async throws -> SegmentBundle {
        let deadline = Date().addingTimeInterval(timeout)
        while !ticket.isFulfilled {
            if Date() > deadline { throw TimeoutError(description: "save never completed; \(diagnostics)") }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try await ticket.bundle()
    }
}

struct ClipInfo {
    let duration: Double
    let isPlayable: Bool
    let decodedVideoFrames: Int
    let hasAudio: Bool
    let readerCompleted: Bool
}

/// Loads a clip with AVURLAsset and decodes every video frame (catches corrupt files).
func inspectClip(_ url: URL) async throws -> ClipInfo {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let duration = try await asset.load(.duration).seconds
    let playable = try await asset.load(.isPlayable)
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let audio = try await asset.loadTracks(withMediaType: .audio)

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    #expect(reader.startReading())
    var frames = 0
    while let sample = output.copyNextSampleBuffer() {
        if CMSampleBufferGetImageBuffer(sample) != nil { frames += 1 }
    }
    return ClipInfo(duration: duration, isPlayable: playable, decodedVideoFrames: frames,
                    hasAudio: !audio.isEmpty, readerCompleted: reader.status == .completed)
}

func expectHealthyClip(_ info: ClipInfo, frameRate: Int, audio: Bool,
                       sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(info.isPlayable, sourceLocation: sourceLocation)
    #expect(info.readerCompleted, "every frame must decode", sourceLocation: sourceLocation)
    let expectedFrames = info.duration * Double(frameRate)
    #expect(abs(Double(info.decodedVideoFrames) - expectedFrames) <= Double(frameRate),
            "decoded \(info.decodedVideoFrames) frames for \(info.duration) s", sourceLocation: sourceLocation)
    #expect(info.hasAudio == audio, sourceLocation: sourceLocation)
}
