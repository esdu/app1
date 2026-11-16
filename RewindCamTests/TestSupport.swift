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

    init(buffer: Double, audio: Bool, frameRate: Int = 15, width: Int = 320, height: Int = 180,
         videoBitrate: Int = 1_000_000) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindCamTests-\(UUID().uuidString)", isDirectory: true)
        storage = FileBufferStorage(root: root)
        storage.removeOrphans() // creates the folders
        self.frameRate = frameRate
        recorder = RollingRecorder(
            bufferDirectory: storage.bufferDirectory,
            clipsDirectory: storage.clipsDirectory,
            configuration: .init(bufferDuration: buffer, videoBitrate: videoBitrate, frameRate: frameRate,
                                 audioEnabled: audio, realTime: false))
        source = SyntheticFrameSource(
            format: .init(width: width, height: height, frameRate: frameRate, audioEnabled: audio), mode: .manual)
        source.setSink(recorder)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

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
                throw TimeoutError(description: "no segment through \(t); last=\(String(describing: recorder.status().lastSegmentEnd))")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Save with `postRoll`, keep "recording" `extra` seconds, then export.
    func saveClip(postRoll: Double = 0, thenRecord extra: Double) async throws -> ExportedClip {
        let ticket = recorder.beginSave(postRoll: postRoll)
        source.generate(seconds: extra)
        let bundle = try await awaitBundle(ticket)
        defer { bundle.discard() }
        return try await ClipExporter.export(bundle)
    }

    func awaitBundle(_ ticket: SaveTicket, timeout: Double = 60) async throws -> SegmentBundle {
        let deadline = Date().addingTimeInterval(timeout)
        while !ticket.isFulfilled {
            if Date() > deadline { throw TimeoutError(description: "save never completed") }
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
