import AVFoundation
import CoreMedia

struct ExportedClip: Sendable {
    let url: URL
    let duration: Double
}

/// Turns a `SegmentBundle` into a trimmed, self-contained `.mov` without re-encoding.
enum ClipExporter {
    enum ExportError: LocalizedError {
        case empty
        case noVideoTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .empty: "Nothing to save yet."
            case .noVideoTrack: "The buffered video could not be read."
            case .exportFailed(let why): "Export failed: \(why)"
            }
        }
    }

    static func export(_ bundle: SegmentBundle, fileName: String = defaultFileName()) async throws -> ExportedClip {
        guard let last = bundle.segments.last, bundle.clipDuration > 0 else { throw ExportError.empty }
        let fm = FileManager.default

        // 1. init + segments → one fragmented MP4 (byte-for-byte concatenation).
        let source = bundle.directory.appendingPathComponent("source.mp4")
        try concatenate([bundle.initSegment] + bundle.segments.map(\.url), into: source)
        for segment in bundle.segments { try? fm.removeItem(at: segment.url) }
        defer { try? fm.removeItem(at: source) }

        // 2. Map the requested media-time range onto the asset's own timeline.
        // Anchored at the end: the asset's last sample ends where the last segment ends,
        // whatever origin the writer used internally.
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let videoRange = try await video.load(.timeRange)
        let tailTrim = CMTime(seconds: max(0, last.end - bundle.clipEnd), preferredTimescale: 90_000)
        let wanted = CMTime(seconds: bundle.clipDuration, preferredTimescale: 90_000)
        let sourceEnd = videoRange.end - tailTrim
        var sourceStart = sourceEnd - wanted
        if sourceStart < videoRange.start { sourceStart = videoRange.start }
        let range = CMTimeRange(start: sourceStart, end: sourceEnd)
        guard range.duration > .zero else { throw ExportError.empty }

        // 3. Trim with a composition (frame-accurate via edit lists, no re-encode).
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.exportFailed("no composition track") }
        try compVideo.insertTimeRange(range, of: video, at: .zero)
        compVideo.preferredTransform = try await video.load(.preferredTransform)

        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let audioRange = try await audio.load(.timeRange)
            let overlap = range.intersection(audioRange)
            if overlap.duration > .zero,
               let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compAudio.insertTimeRange(overlap, of: audio, at: overlap.start - range.start)
            }
        }

        // 4. Passthrough export to QuickTime.
        let output = bundle.directory.appendingPathComponent(fileName)
        try? fm.removeItem(at: output)
        try await runPassthroughExport(composition, to: output)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        return ExportedClip(url: output, duration: duration)
    }

    static func defaultFileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'_'HH-mm-ss"
        return "RewindCam_\(f.string(from: Date())).mov"
    }

    static func concatenate(_ parts: [URL], into destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw ExportError.exportFailed("can't create \(destination.lastPathComponent)")
        }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        for part in parts {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
        }
    }

    private static func runPassthroughExport(_ asset: AVAsset, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.exportFailed("passthrough export unavailable")
        }
        session.shouldOptimizeForNetworkUse = false
        if #available(iOS 18.0, *) {
            do {
                try await session.export(to: url, as: .mov)
            } catch {
                throw ExportError.exportFailed(error.localizedDescription)
            }
        } else {
            session.outputURL = url
            session.outputFileType = .mov
            await session.export()
            guard session.status == .completed else {
                throw ExportError.exportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)")
            }
        }
    }
}
