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

    /// Exports into the bundle's own job folder (tests; the folder is deleted by `discard()`).
    static func export(_ bundle: SegmentBundle, fileName: String = defaultFileName(),
                       orientation: ClipOrientation = .upright) async throws -> ExportedClip {
        try await export(bundle, to: bundle.directory.appendingPathComponent(fileName), orientation: orientation)
    }

    /// Exports to `output`, which may be outside the bundle's folder: the app writes
    /// `UnsavedClips/<name>.partial.mov` and renames it once this returns (DESIGN.md §2, "Save path").
    /// Temporary files are still written inside `bundle.directory`.
    ///
    /// `outputByteLimit` (issue #14) is passed to the export session as `fileLengthLimit`: the output
    /// stops near it (the session may write slightly past it; the free-space reserve covers that).
    ///
    /// `orientation` (issue #37) turns the clip for the way the phone was held at the save tap: it becomes
    /// the video track's `preferredTransform` (no re-encode). The frames themselves are always the portrait
    /// buffer (`CaptureGeometry`).
    static func export(_ bundle: SegmentBundle, to output: URL, outputByteLimit: Int64? = nil,
                       orientation: ClipOrientation = .upright) async throws -> ExportedClip {
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
        compVideo.preferredTransform = try await displayTransform(of: video, turnedFor: orientation)

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
        try? fm.removeItem(at: output)
        try await runPassthroughExport(composition, to: output, fileLengthLimit: outputByteLimit)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        return ExportedClip(url: output, duration: duration)
    }

    static func defaultFileName() -> String { defaultBaseName() + ".mov" }

    /// The source track's own transform (the writer's: identity), followed by the turn for `orientation`.
    static func displayTransform(of track: AVAssetTrack, turnedFor orientation: ClipOrientation) async throws
        -> CGAffineTransform {
        let source = try await track.load(.preferredTransform)
        let natural = try await track.load(.naturalSize)
        let shown = CGRect(origin: .zero, size: natural).applying(source)
        return source
            .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
            .concatenating(orientation.transform(naturalSize: shown.size))
    }

    /// `RewindCam_<date>_<time>`, without an extension.
    static func defaultBaseName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'_'HH-mm-ss"
        return "RewindCam_\(f.string(from: date))"
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

    private static func runPassthroughExport(_ asset: AVAsset, to url: URL, fileLengthLimit: Int64?) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.exportFailed("passthrough export unavailable")
        }
        session.shouldOptimizeForNetworkUse = false
        if let fileLengthLimit, fileLengthLimit > 0 { session.fileLengthLimit = fileLengthLimit }
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
