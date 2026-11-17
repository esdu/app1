import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

/// Why a save holds less than was asked for, besides recording having stopped (issue #14).
enum SaveLimit: Equatable, Sendable {
    /// Copies (hard links failed) or the export didn't fit in the free space above the floor.
    case freeSpace
    /// The save's job folder reached `BufferMath.saveBundleCapBytes` (the encoder far over its bitrate).
    case workingSetCap
}

/// The pieces of one save request, hard-linked into a private folder so the ring can keep evicting.
struct SegmentBundle: Sendable {
    let directory: URL
    let initSegment: URL
    let segments: [BufferedSegment]
    let requestedStart: Double
    let requestedEnd: Double
    /// Set when the bundle was cut short to stay within free space or the working-set cap.
    var limit: SaveLimit?

    var clipStart: Double { max(requestedStart, segments.first?.start ?? requestedStart) }
    var clipEnd: Double { min(requestedEnd, segments.last?.end ?? requestedEnd) }
    var clipDuration: Double { max(0, clipEnd - clipStart) }

    /// Size of the job folder's `init.mp4` on disk.
    var initBytes: Int64 { FileBufferStorage.fileSize(initSegment) }
    /// What concatenating the bundle writes (`source.mp4`): init + segments, from their sizes on disk.
    var sourceBytes: Int64 { initBytes + segments.reduce(0) { $0 + $1.bytes } }

    /// Only the newest `count` segments (the clip still ends where asked, but starts later); the
    /// others' links are deleted now. Marked `.freeSpace`.
    func keepingNewest(_ count: Int) -> SegmentBundle {
        let dropped = segments.dropLast(max(0, count))
        for segment in dropped { try? FileManager.default.removeItem(at: segment.url) }
        return SegmentBundle(directory: directory, initSegment: initSegment, segments: Array(segments.suffix(count)),
                             requestedStart: requestedStart, requestedEnd: requestedEnd, limit: .freeSpace)
    }

    func discard() { try? FileManager.default.removeItem(at: directory) }
}

/// Why the recorder stopped itself (issue #14). It ignores samples until `resume()` or `reset()`, so a
/// shortage can't turn into an automatic restart loop; `AppModel` stops capture and says why.
enum RecorderHalt: Equatable, Sendable {
    /// Fragment data arrived faster than it could be written (`FragmentQueueLimit` reached), or one
    /// fragment was larger than the limit allows.
    case backlog
    /// A fragment couldn't be written (usually a full disk).
    case writeFailed(String)

    var message: String {
        switch self {
        case .backlog:
            "Recording stopped: video arrived faster than it could be stored, so RewindCam stopped instead of "
                + "using more memory. Tap Try Again; if it happens again, choose a lower quality in Settings."
        case .writeFailed(let why):
            "Recording stopped: the buffer couldn't be written (\(why)). Free up space and tap Try Again."
        }
    }
}

/// Fragment data admitted by the writer delegate and not yet written or dropped (issue #14).
struct FragmentQueueStats: Equatable, Sendable {
    var limit: FragmentQueueLimit
    var count = 0
    var bytes: Int64 = 0
    var peakCount = 0
    var peakBytes: Int64 = 0
    var admitted = 0
    var rejected = 0
}

/// The file operations the recorder performs on media, so tests can use slow or failing storage.
struct MediaFileOperations: Sendable {
    /// Hard-links `$0` to `$1`.
    var link: @Sendable (URL, URL) throws -> Void
    /// Writes one fragment's bytes to a new file.
    var writeFragment: @Sendable (Data, URL) throws -> Void

    static let live = MediaFileOperations(
        link: { try FileManager.default.linkItem(at: $0, to: $1) },
        writeFragment: { try $0.write(to: $1) })
}

enum RecorderError: LocalizedError, Equatable {
    case nothingBuffered
    case alreadySaving
    case fileError(String)
    /// A save waiting for its post-roll was settled because video stopped arriving (issue #9), and
    /// no footage for it had been buffered.
    case videoStopped

    var errorDescription: String? {
        switch self {
        case .nothingBuffered: "Nothing is buffered yet."
        case .alreadySaving: "Already saving a clip…"
        case .fileError(let why): "Storage error: \(why)"
        case .videoStopped: "Nothing was saved: video stopped arriving before any footage for this clip was "
            + "recorded. Save again once RewindCam shows REC."
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
    /// Set when the recorder stopped itself (issue #14); cleared by `resume()` or `reset()`.
    var halt: RecorderHalt?
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
        /// Non-real-time only: how long an append waits for the input to become ready before the
        /// sample is dropped. Tests that expect a stalled writer lower it.
        var appendWaitLimit: Double = 10

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
        /// `BufferMath.saveBundleCapBytes`: the job folder never holds more (issue #14).
        let byteCap: Int64
        var segments: [BufferedSegment] = []
        /// init + segments in the job folder.
        var bytes: Int64
        var limit: SaveLimit?

        init(ticket: SaveTicket, generationID: Int, start: Double, end: Double, directory: URL, initSegment: URL,
             byteCap: Int64) {
            self.ticket = ticket
            self.generationID = generationID
            self.start = start
            self.end = end
            self.directory = directory
            self.initSegment = initSegment
            self.byteCap = byteCap
            bytes = FileBufferStorage.fileSize(initSegment)
        }

        /// Links (or, if linking fails and the space is granted, copies) one segment into the job folder.
        /// Throws `SaveLimit` when the segment would take the folder past its cap or the copy has no room.
        func link(_ segment: BufferedSegment, using recorder: RollingRecorder) throws {
            guard bytes + segment.bytes <= byteCap else { throw SaveLimitReached(limit: .workingSetCap) }
            let dest = directory.appendingPathComponent(segment.url.lastPathComponent)
            do {
                try recorder.linkOrCopyForSave(segment.url, to: dest)
            } catch is StorageSpaceError {
                throw SaveLimitReached(limit: .freeSpace)
            }
            segments.append(segment.relocated(to: dest))
            bytes += segment.bytes
        }

        var bundle: SegmentBundle {
            SegmentBundle(directory: directory, initSegment: initSegment, segments: segments,
                          requestedStart: start, requestedEnd: end, limit: limit)
        }
    }

    private struct SaveLimitReached: Error {
        let limit: SaveLimit
    }

    let bufferDirectory: URL
    let clipsDirectory: URL
    private let queue = DispatchQueue(label: "RewindCam.RollingRecorder", qos: .userInitiated)
    private var configuration: Configuration
    private var generation: Generation?
    private var generationCounter = 0
    private var pending: PendingSave?
    private var suspended = false
    /// Set when the recorder stopped itself (issue #14); samples are ignored until `resume()`/`reset()`.
    private var halt: RecorderHalt?
    private var lastError: String?
    private var retryAfter: CMTime = .invalid
    private let statusBox = Locked(RecorderStatus())
    private let fileOperations: MediaFileOperations
    /// Free space for copies when hard links fail (issue #14); nil: unknown, copies always allowed.
    private let space: TemporarySpace?

    /// Fragment admission (issue #14), shared by the writer's delegate thread and `queue`.
    private struct Admission {
        var stats: FragmentQueueStats
        /// Writers whose fragment was refused: everything later from them is refused too, until the
        /// recorder queue has stopped their generation (`fragmentRejected`).
        var refusedWriters: Set<ObjectIdentifier> = []
    }
    private let admission: Locked<Admission>

    init(bufferDirectory: URL, clipsDirectory: URL, configuration: Configuration,
         space: TemporarySpace? = nil, fileOperations: MediaFileOperations = .live) {
        self.bufferDirectory = bufferDirectory
        self.clipsDirectory = clipsDirectory
        self.configuration = configuration
        self.space = space
        self.fileOperations = fileOperations
        admission = Locked(Admission(stats: FragmentQueueStats(limit: BufferMath.fragmentQueueLimit(configuration))))
        super.init()
    }

    deinit {
        // Never let an AVAssetWriter be released mid-session: its encoder threads may still be
        // delivering output. (All queue blocks retain `self`, so nothing else runs now.)
        if let g = generation, g.writer.status == .writing {
            g.writer.cancelWriting()
        }
    }

    var currentConfiguration: Configuration { queue.sync { configuration } }

    /// Lock-protected snapshot; safe to call from the main thread at any rate.
    func status() -> RecorderStatus { statusBox.current }

    /// Fragment data waiting for the recorder queue right now, its peaks and the bound (issue #14).
    func fragmentQueue() -> FragmentQueueStats { admission.current.stats }

    /// The current generation's writer, if any. Tests feed its delegate callbacks directly
    /// (bursts, oversized fragments) to exercise fragment admission.
    var activeWriter: AVAssetWriter? { queue.sync { generation?.writer } }

    /// Status plus the segment files actually on disk, read together on the recorder queue
    /// (segments land asynchronously, so separate reads can disagree by one segment).
    func diskSnapshot() -> (status: RecorderStatus, segmentFiles: [URL], bytes: Int64) {
        queue.sync {
            publish()
            let files = FileBufferStorage.files(in: bufferDirectory, withExtension: "m4s")
            return (statusBox.current, files, FileBufferStorage.directorySize(bufferDirectory))
        }
    }

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

    /// Takes samples again; also ends a halt (issue #14).
    func resume() {
        queue.sync {
            suspended = false
            halt = nil
            retryAfter = .invalid
            publish()
        }
    }

    /// Drops the current buffer and ends a halt; the next video frame starts a fresh generation.
    func reset() {
        queue.sync {
            tearDownGeneration()
            halt = nil
            publish()
        }
    }

    /// Buffer-length changes apply in place; encoder changes start a new generation.
    func reconfigure(_ new: Configuration) {
        queue.sync {
            let restart = new.needsNewWriter(comparedTo: configuration)
            configuration = new
            admission.withLock { $0.stats.limit = BufferMath.fragmentQueueLimit(new) }
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
                try FileProtectionPolicy.prepareDirectory(dir)
                let initCopy = dir.appendingPathComponent("init.mp4")
                try linkOrCopyForSave(initURL, to: initCopy)
                let p = PendingSave(ticket: ticket, generationID: g.id, start: start, end: end,
                                    directory: dir, initSegment: initCopy,
                                    byteCap: BufferMath.saveBundleCapBytes(configuration, postRollSeconds: postRoll))
                // Newest first, so a copy that doesn't fit (hard links failed, issue #14) costs the oldest
                // footage and what is linked stays one contiguous run that ends at the tap.
                var linked: [BufferedSegment] = []
                for segment in g.ring.segments.reversed() where segment.end > start + 1e-6 {
                    do {
                        try p.link(segment, using: self)
                    } catch let reached as SaveLimitReached {
                        p.limit = reached.limit
                        break
                    }
                    linked.append(p.segments.removeLast())
                }
                p.segments = linked.reversed()
                if p.limit != nil, p.segments.isEmpty, !g.ring.segments.isEmpty {
                    throw StorageSpaceError.noRoomToCopy(bytes: g.ring.segments.last?.bytes ?? 0)
                }
                pending = p
                // A start cut short for space still takes the post-roll: it continues the same run.
                if let last = p.segments.last, last.end >= end - tolerance {
                    complete(p)
                }
            } catch let error as StorageSpaceError {
                try? FileManager.default.removeItem(at: dir)
                ticket.fulfill(.failure(error))
            } catch {
                try? FileManager.default.removeItem(at: dir)
                ticket.fulfill(.failure(RecorderError.fileError(error.localizedDescription)))
            }
        }
        return ticket
    }

    /// Settles a save that is waiting for its post-roll now, with the segments already linked, or with
    /// `RecorderError.videoStopped` if there are none (issue #9: frames stopped, so the post-roll would
    /// never arrive). Recording itself is untouched. Does nothing if no save is pending; a ticket is
    /// only ever fulfilled once.
    func settlePendingSave() {
        queue.sync {
            guard let p = pending else { return }
            resolveEarly(p, ifEmpty: RecorderError.videoStopped)
            publish()
        }
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
        let bytes = Int64(segmentData.count)
        // Never block the writer's thread: hop to our queue. But only retain the data if it fits the
        // queued-fragment bound (issue #14); a refused fragment is let go here, and its generation is
        // stopped on the queue rather than continued with a hole in it.
        switch admit(ObjectIdentifier(writer), bytes: bytes) {
        case .admitted:
            queue.async { [self] in
                defer { releaseAdmission(bytes) }
                handleSegment(from: writerRef.value, data: segmentData, isInit: isInit, timing: timing)
            }
        case .refusedFirst:
            queue.async { [self] in fragmentRefused(from: writerRef.value) }
        case .refusedAgain:
            break // already being stopped
        }
    }

    // MARK: - Fragment admission (issue #14; thread-safe)

    private enum AdmissionResult { case admitted, refusedFirst, refusedAgain }

    /// Reserves room for one fragment in the queued-fragment bound. Refuses it if it alone is larger than
    /// `FragmentQueueLimit.fragmentBytes`, if it would exceed the count or byte bound, or if an earlier
    /// fragment of the same writer was refused (the sequence after that point is not usable).
    private func admit(_ writer: ObjectIdentifier, bytes: Int64) -> AdmissionResult {
        admission.withLock { (a: inout Admission) -> AdmissionResult in
            if a.refusedWriters.contains(writer) {
                a.stats.rejected += 1
                return .refusedAgain
            }
            let limit = a.stats.limit
            guard bytes <= limit.fragmentBytes, a.stats.count + 1 <= limit.count,
                  a.stats.bytes + bytes <= limit.bytes else {
                a.refusedWriters.insert(writer)
                a.stats.rejected += 1
                return .refusedFirst
            }
            a.stats.count += 1
            a.stats.bytes += bytes
            a.stats.admitted += 1
            a.stats.peakCount = max(a.stats.peakCount, a.stats.count)
            a.stats.peakBytes = max(a.stats.peakBytes, a.stats.bytes)
            return .admitted
        }
    }

    /// Every admitted fragment is released exactly once, when its queue block ends: written, dropped as
    /// stale or refused, or failed.
    private func releaseAdmission(_ bytes: Int64) {
        admission.withLock { a in
            a.stats.count -= 1
            a.stats.bytes -= bytes
        }
    }

    private func isRefused(_ writer: AVAssetWriter) -> Bool {
        admission.withLock { $0.refusedWriters.contains(ObjectIdentifier(writer)) }
    }

    // MARK: - Private (on `queue`)

    private var tolerance: Double { 0.5 / Double(max(1, configuration.frameRate)) }

    /// How far (seconds) audio may run ahead of the newest video frame before it is dropped. Capture
    /// delivers audio and video on one clock within a few hundred ms of each other, so only audio
    /// without video (a stalled camera) reaches this.
    static let maxAudioLead: Double = 1

    private func append(_ sampleBuffer: CMSampleBuffer, kind: MediaKind) {
        guard !suspended, halt == nil else { return }
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
            // Never more than `maxAudioLead` past the newest video frame (issue #9). The writer
            // interleaves audio with video, so audio with no video to go with it (the camera stopped
            // while the microphone didn't) only piles up in it; in a UI test, appends then blocked
            // this queue, and with it the main thread's next suspend. Clips end at a video frame anyway.
            guard g.lastVideoPTS.isValid, (pts - g.lastVideoPTS).seconds <= Self.maxAudioLead else { return }
            guard waitUntilReady(input, writer: g.writer) else { return }
            if !input.append(sampleBuffer) { writerFailed(g, at: pts) }
        }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) -> Bool {
        if input.isReadyForMoreMediaData { return true }
        guard !configuration.realTime else { return false }
        let deadline = Date().addingTimeInterval(configuration.appendWaitLimit)
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
            try FileProtectionPolicy.prepareDirectory(dir)
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

        // Only when the source really delivers audio (`ActiveCapture.audioCaptured`): an audio input
        // that never gets samples holds back the writer's segments (issue #3, RecorderTests).
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
        // Stale generation: dropped (its reservation is released by the caller), and it can't
        // recreate the deleted generation folder.
        guard let g = generation, g.writer === writer else { return }
        // A later fragment of this writer was refused (issue #14): the generation is being stopped
        // (`fragmentRefused` is queued behind this), so nothing more of it is kept.
        guard !isRefused(writer) else { return }
        if isInit {
            let url = g.directory.appendingPathComponent("init.mp4")
            do {
                try fileOperations.writeFragment(data, url)
                g.initSegment = url
            } catch {
                haltGeneration(.writeFailed(error.localizedDescription))
            }
            return
        }

        let index = g.nextSegmentIndex
        g.nextSegmentIndex += 1
        let url = g.directory.appendingPathComponent(String(format: "seg-%06d.m4s", index))
        do {
            try fileOperations.writeFragment(data, url)
        } catch {
            // Skipping the segment would leave a hole that a save could span (issue #14): stop instead.
            haltGeneration(.writeFailed(error.localizedDescription))
            return
        }

        var start = timing?.start ?? g.lastSegmentEnd ?? g.startTime.seconds
        if g.reportOffset == nil { g.reportOffset = (timing == nil) ? 0 : g.startTime.seconds - start }
        start += g.reportOffset ?? 0
        let duration = timing.map { $0.duration }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? configuration.segmentInterval
        let segment = BufferedSegment(index: index, url: url, start: start, duration: duration, bytes: Int64(data.count))
        g.lastSegmentEnd = segment.end
        // Evicted files are deleted after the pending save has linked this segment: the ring may evict
        // the newest segment itself if it alone is over the cap (`SegmentRing`).
        let evicted = g.ring.append(segment)
        defer { delete(evicted) }

        if let p = pending, p.generationID == g.id {
            do {
                if segment.end > p.start { try p.link(segment, using: self) }
                if segment.end >= p.end - tolerance { complete(p) }
            } catch let reached as SaveLimitReached {
                // No room for the copy, or the job folder is at its cap: settle with the run so far.
                p.limit = reached.limit
                resolveEarly(p, ifEmpty: StorageSpaceError.noRoomToCopy(bytes: segment.bytes))
            } catch {
                pending = nil
                p.bundle.discard()
                p.ticket.fulfill(.failure(RecorderError.fileError(error.localizedDescription)))
            }
        }
        publish()
    }

    /// The first refused fragment of `writer` (issue #14). If it belongs to the current generation, that
    /// generation stops: a pending save is settled with the contiguous footage it already has, and the
    /// recorder halts until `resume()`/`reset()`. A stale writer's refusal changes nothing. Either way the
    /// writer's refusal mark is cleared: everything it sent before is already handled by now.
    private func fragmentRefused(from writer: AVAssetWriter) {
        defer { admission.withLock { _ = $0.refusedWriters.remove(ObjectIdentifier(writer)) } }
        guard let g = generation, g.writer === writer else { return }
        haltGeneration(.backlog)
    }

    /// Stops the current generation for a resource problem and ignores samples until `resume()`/`reset()`
    /// (no automatic restart under the same shortage). The pending save is settled once.
    private func haltGeneration(_ reason: RecorderHalt) {
        halt = reason
        tearDownGeneration()
        publish()
    }

    private func complete(_ p: PendingSave) {
        if pending === p { pending = nil }
        p.ticket.fulfill(.success(p.bundle))
    }

    /// Interruption while a save is pending: hand over whatever was already captured.
    private func resolveEarly(_ p: PendingSave, ifEmpty error: Error = RecorderError.nothingBuffered) {
        if pending === p { pending = nil }
        if p.segments.isEmpty {
            p.bundle.discard()
            p.ticket.fulfill(.failure(error))
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
            lastError: lastError,
            halt: halt
        )
        statusBox.withLock { $0 = snapshot }
    }

    /// A save's link (or copy) of a ring file, on `queue`: copies are admitted against `space` above the
    /// reserve (capture is running), issue #14.
    fileprivate func linkOrCopyForSave(_ src: URL, to dest: URL) throws {
        try Self.linkOrCopy(src, to: dest, link: fileOperations.link, space: space,
                            floor: DiskSpacePolicy.saveFloorBytes(captureRunning: true))
    }

    /// A hard link shares the source's inode, and so its protection class, and costs no space. A copy is
    /// a new file: it gets the media class set explicitly (`FileProtectionPolicy`), and (issue #14) is
    /// made only if `space` grants its size above `floor`, else `StorageSpaceError.noRoomToCopy`.
    static func linkOrCopy(_ src: URL, to dest: URL,
                           link: @Sendable (URL, URL) throws -> Void = MediaFileOperations.live.link,
                           space: TemporarySpace? = nil, floor: Int64 = 0) throws {
        do {
            try link(src, dest)
        } catch {
            let bytes = FileBufferStorage.fileSize(src)
            var reservation: SpaceReservation?
            if let space {
                guard let granted = space.reserve(bytes, floor: floor) else {
                    throw StorageSpaceError.noRoomToCopy(bytes: bytes)
                }
                reservation = granted
            }
            defer { reservation?.release() }
            try FileProtectionPolicy.copyItem(at: src, to: dest)
        }
    }
}
