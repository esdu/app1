import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

/// The pieces of one save request, hard-linked into a private folder so the ring can keep evicting.
struct SegmentBundle: Sendable {
    let directory: URL
    let initSegment: URL
    let segments: [BufferedSegment]
    let requestedStart: Double
    let requestedEnd: Double

    var clipStart: Double { max(requestedStart, segments.first?.start ?? requestedStart) }
    var clipEnd: Double { min(requestedEnd, segments.last?.end ?? requestedEnd) }
    var clipDuration: Double { max(0, clipEnd - clipStart) }

    func discard() { try? FileManager.default.removeItem(at: directory) }
}

enum RecorderError: LocalizedError, Equatable {
    case nothingBuffered
    case alreadySaving
    case fileError(String)

    var errorDescription: String? {
        switch self {
        case .nothingBuffered: "Nothing is buffered yet."
        case .alreadySaving: "Already saving a clip…"
        case .fileError(let why): "Storage error: \(why)"
        }
    }
}

struct RecorderStatus: Equatable, Sendable {
    var generation = 0
    var bufferedSeconds: Double = 0
    var segmentCount = 0
    var bytes: Int64 = 0
    var latestMediaTime: Double?
    var lastSegmentEnd: Double?
    var isSaving = false
    var isSuspended = false
    var lastError: String?
}

/// Result handle for a save request: registered synchronously, awaited later.
final class SaveTicket: @unchecked Sendable {
    // @unchecked: all state is behind `Locked`.
    private struct State {
        var result: Result<SegmentBundle, Error>?
        var waiter: CheckedContinuation<SegmentBundle, Error>?
    }
    private let state = Locked(State())

    func fulfill(_ result: Result<SegmentBundle, Error>) {
        let waiter: CheckedContinuation<SegmentBundle, Error>? = state.withLock { s in
            guard s.result == nil else { return nil }
            s.result = result
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(with: result)
    }

    var isFulfilled: Bool { state.withLock { $0.result != nil } }

    func bundle() async throws -> SegmentBundle {
        try await withCheckedThrowingContinuation { cont in
            let ready: Result<SegmentBundle, Error>? = state.withLock { s in
                if let r = s.result { return r }
                s.waiter = cont
                return nil
            }
            if let ready { cont.resume(with: ready) }
        }
    }
}

/// Encodes incoming samples into ~1 s HLS-profile fMP4 segments and keeps the newest
/// `bufferDuration` seconds of them on disk. See DESIGN.md §2.
final class RollingRecorder: NSObject, SampleSink, AVAssetWriterDelegate, @unchecked Sendable {
    // @unchecked: every mutable stored property is only touched on `queue`;
    // `statusBox` is independently locked for cheap reads from the main thread.

    struct Configuration: Equatable, Sendable {
        var bufferDuration: Double
        var videoBitrate: Int
        var frameRate: Int
        var audioEnabled: Bool
        /// `false` in unit tests: appends wait for the encoder instead of dropping frames.
        var realTime: Bool = true
        var segmentInterval: Double = 1

        var byteCap: Int64 {
            BufferMath.ringCapBytes(videoBitrate: videoBitrate, audioEnabled: audioEnabled, bufferSeconds: bufferDuration)
        }

        init(bufferDuration: Double, videoBitrate: Int, frameRate: Int, audioEnabled: Bool, realTime: Bool = true) {
            self.bufferDuration = bufferDuration
            self.videoBitrate = videoBitrate
            self.frameRate = frameRate
            self.audioEnabled = audioEnabled
            self.realTime = realTime
        }

        init(bufferSeconds: Int, preset: QualityPreset, audioEnabled: Bool, realTime: Bool = true) {
            self.init(bufferDuration: Double(bufferSeconds), videoBitrate: preset.videoBitrate,
                      frameRate: preset.frameRate.rawValue, audioEnabled: audioEnabled, realTime: realTime)
        }

        /// Changing any of these needs a new writer (and therefore clears the buffer).
        func needsNewWriter(comparedTo other: Configuration) -> Bool {
            videoBitrate != other.videoBitrate || frameRate != other.frameRate
                || audioEnabled != other.audioEnabled || realTime != other.realTime
                || segmentInterval != other.segmentInterval
        }
    }

    private final class Generation {
        let id: Int
        let directory: URL
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?
        let dimensions: CMVideoDimensions
        let startTime: CMTime
        var initSegment: URL?
        var ring: SegmentRing
        var nextSegmentIndex = 0
        var lastVideoPTS = CMTime.invalid
        var lastSegmentEnd: Double?
        /// Correction if the writer reports segment times on a different origin than the input PTS.
        var reportOffset: Double?

        init(id: Int, directory: URL, writer: AVAssetWriter, videoInput: AVAssetWriterInput,
             audioInput: AVAssetWriterInput?, dimensions: CMVideoDimensions, startTime: CMTime, ring: SegmentRing) {
            self.id = id
            self.directory = directory
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.dimensions = dimensions
            self.startTime = startTime
            self.ring = ring
        }
    }

    private final class PendingSave {
        let ticket: SaveTicket
        let generationID: Int
        let start: Double
        let end: Double
        let directory: URL
        let initSegment: URL
        var segments: [BufferedSegment] = []

        init(ticket: SaveTicket, generationID: Int, start: Double, end: Double, directory: URL, initSegment: URL) {
            self.ticket = ticket
            self.generationID = generationID
            self.start = start
            self.end = end
            self.directory = directory
            self.initSegment = initSegment
        }

        func link(_ segment: BufferedSegment) throws {
            let dest = directory.appendingPathComponent(segment.url.lastPathComponent)
            try RollingRecorder.linkOrCopy(segment.url, to: dest)
            segments.append(segment.relocated(to: dest))
        }

        var bundle: SegmentBundle {
            SegmentBundle(directory: directory, initSegment: initSegment, segments: segments,
                          requestedStart: start, requestedEnd: end)
        }
    }

    let bufferDirectory: URL
    let clipsDirectory: URL
    private let queue = DispatchQueue(label: "RewindCam.RollingRecorder", qos: .userInitiated)
    private var configuration: Configuration
    private var generation: Generation?
    private var generationCounter = 0
    private var pending: PendingSave?
    private var suspended = false
    private var lastError: String?
    private var retryAfter: CMTime = .invalid
    private let statusBox = Locked(RecorderStatus())

    init(bufferDirectory: URL, clipsDirectory: URL, configuration: Configuration) {
        self.bufferDirectory = bufferDirectory
        self.clipsDirectory = clipsDirectory
        self.configuration = configuration
        super.init()
    }

    var currentConfiguration: Configuration { queue.sync { configuration } }

    /// Lock-protected snapshot; safe to call from the main thread at any rate.
    func status() -> RecorderStatus { statusBox.current }

    // MARK: SampleSink

    func consume(_ sampleBuffer: CMSampleBuffer, kind: MediaKind) {
        queue.sync { append(sampleBuffer, kind: kind) }
    }

    // MARK: Control

    /// Interruption/backgrounding: drop the writer and the buffer, ignore samples until `resume()`.
    func suspend() {
        queue.sync {
            suspended = true
            tearDownGeneration()
            publish()
        }
    }

    func resume() {
        queue.sync {
            suspended = false
            retryAfter = .invalid
            publish()
        }
    }

    /// Drops the current buffer; the next video frame starts a fresh generation.
    func reset() {
        queue.sync {
            tearDownGeneration()
            publish()
        }
    }

    /// Buffer-length changes apply in place; encoder changes start a new generation.
    func reconfigure(_ new: Configuration) {
        queue.sync {
            let restart = new.needsNewWriter(comparedTo: configuration)
            configuration = new
            if restart {
                tearDownGeneration()
            } else if let g = generation {
                g.ring.bufferDuration = new.bufferDuration
                g.ring.byteCap = new.byteCap
                delete(g.ring.evict())
            }
            publish()
        }
    }

    /// Registers a save of `[tap − buffer, tap + postRoll]`, where `tap` is the newest video frame.
    /// Registration is synchronous; await `ticket.bundle()` for the segments.
    func beginSave(postRoll: Double) -> SaveTicket {
        let ticket = SaveTicket()
        queue.sync {
            defer { publish() }
            guard pending == nil else {
                ticket.fulfill(.failure(RecorderError.alreadySaving))
                return
            }
            guard let g = generation, let initURL = g.initSegment, g.lastVideoPTS.isValid else {
                ticket.fulfill(.failure(RecorderError.nothingBuffered))
                return
            }
            let tap = g.lastVideoPTS.seconds
            let end = tap + max(0, postRoll)
            let start = tap - configuration.bufferDuration
            let dir = clipsDirectory.appendingPathComponent("save-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let initCopy = dir.appendingPathComponent("init.mp4")
                try Self.linkOrCopy(initURL, to: initCopy)
                let p = PendingSave(ticket: ticket, generationID: g.id, start: start, end: end,
                                    directory: dir, initSegment: initCopy)
                for segment in g.ring.segments where segment.end > start + 1e-6 {
                    try p.link(segment)
                }
                pending = p
                if let last = p.segments.last, last.end >= end - tolerance {
                    complete(p)
                }
            } catch {
                try? FileManager.default.removeItem(at: dir)
                ticket.fulfill(.failure(RecorderError.fileError(error.localizedDescription)))
            }
        }
        return ticket
    }

    // MARK: AVAssetWriterDelegate

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        var timing: (start: Double, duration: Double)?
        if let reports = segmentReport?.trackReports,
           let track = reports.first(where: { $0.mediaType == .video }) ?? reports.first {
            timing = (track.earliestPresentationTimeStamp.seconds, track.duration.seconds)
        }
        let isInit = segmentType == .initialization
        let writerRef = UncheckedSendable(writer)
        // Never block the writer's thread: hop to our queue.
        queue.async { [self] in
            handleSegment(from: writerRef.value, data: segmentData, isInit: isInit, timing: timing)
        }
    }

    // MARK: - Private (on `queue`)

    private var tolerance: Double { 0.5 / Double(max(1, configuration.frameRate)) }

    private func append(_ sampleBuffer: CMSampleBuffer, kind: MediaKind) {
        guard !suspended else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { return }

        switch kind {
        case .video:
            if let g = generation, let fd = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let d = CMVideoFormatDescriptionGetDimensions(fd)
                if d.width != g.dimensions.width || d.height != g.dimensions.height {
                    tearDownGeneration()
                }
            }
            if generation == nil {
                if retryAfter.isValid, pts < retryAfter { return }
                generation = startGeneration(firstVideo: sampleBuffer)
                publish()
            }
            guard let g = generation else { return }
            guard g.writer.status == .writing else { return writerFailed(g, at: pts) }
            if g.lastVideoPTS.isValid, pts <= g.lastVideoPTS { return }
            guard waitUntilReady(g.videoInput, writer: g.writer) else { return } // dropped frame
            if g.videoInput.append(sampleBuffer) {
                g.lastVideoPTS = pts
                statusBox.withLock { $0.latestMediaTime = pts.seconds }
            } else {
                writerFailed(g, at: pts)
            }

        case .audio:
            guard let g = generation, let input = g.audioInput, g.writer.status == .writing,
                  pts >= g.startTime else { return }
            guard waitUntilReady(input, writer: g.writer) else { return }
            if !input.append(sampleBuffer) { writerFailed(g, at: pts) }
        }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) -> Bool {
        if input.isReadyForMoreMediaData { return true }
        guard !configuration.realTime else { return false }
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing || Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }

    private func startGeneration(firstVideo sampleBuffer: CMSampleBuffer) -> Generation? {
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        generationCounter += 1
        let id = generationCounter
        let dir = bufferDirectory.appendingPathComponent("gen-\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            lastError = "Can't create buffer folder: \(error.localizedDescription)"
            return nil
        }

        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: configuration.segmentInterval, preferredTimescale: 600)
        writer.initialSegmentStartTime = pts
        writer.delegate = self

        let fps = configuration.frameRate
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: configuration.videoBitrate,
            AVVideoMaxKeyFrameIntervalKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: configuration.segmentInterval,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: fps,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = configuration.realTime
        guard writer.canAdd(videoInput) else {
            lastError = "Encoder rejected \(dims.width)×\(dims.height)"
            try? FileManager.default.removeItem(at: dir)
            retryAfter = pts + CMTime(seconds: 1, preferredTimescale: 600)
            return nil
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if configuration.audioEnabled {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVChannelLayoutKey: layoutData,
                AVEncoderBitRateKey: BufferMath.audioBitrate,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = configuration.realTime
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            lastError = "Writer failed to start: \(writer.error?.localizedDescription ?? "unknown")"
            try? FileManager.default.removeItem(at: dir)
            retryAfter = pts + CMTime(seconds: 1, preferredTimescale: 600)
            return nil
        }
        writer.startSession(atSourceTime: pts)
        lastError = nil
        let ring = SegmentRing(bufferDuration: configuration.bufferDuration, byteCap: configuration.byteCap)
        return Generation(id: id, directory: dir, writer: writer, videoInput: videoInput, audioInput: audioInput,
                          dimensions: dims, startTime: pts, ring: ring)
    }

    private func writerFailed(_ g: Generation, at pts: CMTime) {
        lastError = "Encoder error: \(g.writer.error?.localizedDescription ?? "unknown"). Buffer restarted."
        tearDownGeneration()
        retryAfter = pts + CMTime(seconds: 1, preferredTimescale: 600)
        publish()
    }

    private func handleSegment(from writer: AVAssetWriter, data: Data, isInit: Bool,
                               timing: (start: Double, duration: Double)?) {
        guard let g = generation, g.writer === writer else { return } // stale generation
        if isInit {
            let url = g.directory.appendingPathComponent("init.mp4")
            do {
                try data.write(to: url)
                g.initSegment = url
            } catch {
                lastError = "Can't write buffer: \(error.localizedDescription)"
            }
            return
        }

        let index = g.nextSegmentIndex
        g.nextSegmentIndex += 1
        let url = g.directory.appendingPathComponent(String(format: "seg-%06d.m4s", index))
        do {
            try data.write(to: url)
        } catch {
            lastError = "Can't write buffer: \(error.localizedDescription)"
            return
        }

        var start = timing?.start ?? g.lastSegmentEnd ?? g.startTime.seconds
        if g.reportOffset == nil { g.reportOffset = (timing == nil) ? 0 : g.startTime.seconds - start }
        start += g.reportOffset ?? 0
        let duration = timing.map { $0.duration }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? configuration.segmentInterval
        let segment = BufferedSegment(index: index, url: url, start: start, duration: duration, bytes: Int64(data.count))
        g.lastSegmentEnd = segment.end
        delete(g.ring.append(segment))

        if let p = pending, p.generationID == g.id {
            do {
                if segment.end > p.start { try p.link(segment) }
                if segment.end >= p.end - tolerance { complete(p) }
            } catch {
                pending = nil
                p.bundle.discard()
                p.ticket.fulfill(.failure(RecorderError.fileError(error.localizedDescription)))
            }
        }
        publish()
    }

    private func complete(_ p: PendingSave) {
        if pending === p { pending = nil }
        p.ticket.fulfill(.success(p.bundle))
    }

    /// Interruption while a save is pending: hand over whatever was already captured.
    private func resolveEarly(_ p: PendingSave) {
        if pending === p { pending = nil }
        if p.segments.isEmpty {
            p.bundle.discard()
            p.ticket.fulfill(.failure(RecorderError.nothingBuffered))
        } else {
            p.ticket.fulfill(.success(p.bundle))
        }
    }

    private func tearDownGeneration() {
        if let p = pending { resolveEarly(p) }
        guard let g = generation else { return }
        generation = nil
        if g.writer.status == .writing {
            g.writer.cancelWriting() // no partial segment is ever emitted
        }
        try? FileManager.default.removeItem(at: g.directory)
    }

    private func delete(_ segments: [BufferedSegment]) {
        for s in segments { try? FileManager.default.removeItem(at: s.url) }
    }

    private func publish() {
        let g = generation
        let snapshot = RecorderStatus(
            generation: g?.id ?? 0,
            bufferedSeconds: g?.ring.totalDuration ?? 0,
            segmentCount: g?.ring.segments.count ?? 0,
            bytes: g?.ring.totalBytes ?? 0,
            latestMediaTime: (g?.lastVideoPTS.isValid ?? false) ? g?.lastVideoPTS.seconds : nil,
            lastSegmentEnd: g?.lastSegmentEnd,
            isSaving: pending != nil,
            isSuspended: suspended,
            lastError: lastError
        )
        statusBox.withLock { $0 = snapshot }
    }

    static func linkOrCopy(_ src: URL, to dest: URL) throws {
        do {
            try FileManager.default.linkItem(at: src, to: dest)
        } catch {
            try FileManager.default.copyItem(at: src, to: dest)
        }
    }
}
