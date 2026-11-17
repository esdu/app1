import Foundation

/// Notices when the app says it is recording but the buffer stopped growing (issue #9): no new video
/// frame reached the recorder, or frames arrive but the writer emits no segments. A pure value, like
/// `SegmentRing` and `RestartBackoff`: `AppModel.statusTick()` feeds it the recorder's status and a
/// monotonic time (`AppEnvironment.monotonicClock`), so tests drive it without a camera or a clock.
///
/// * **Video only.** Progress is `RecorderStatus.latestMediaTime`, the PTS of the newest *video* frame
///   appended to the writer. Audio samples never change it, so a microphone that keeps delivering
///   can't hide a camera that stopped.
/// * **Generations.** Each writer has a generation number (`RecorderStatus.generation`, increasing).
///   A newer generation that has a frame is progress; a snapshot from an older generation than one
///   already seen is stale and ignored, and so are all generations the recorder held before `arm`
///   found it empty (after a suspend), so nothing from before a restart counts as new video.
/// * **Arming.** The model arms it when recording settles and disarms it on every deliberate change
///   (start, restart, suspend/resume, settings or thermal reconfiguration), so a restart is never
///   reported as a stall: arming gives the new session the full `timeout` to deliver.
/// * **Budget.** `automaticRestartsPerStall` automatic restarts per stall episode. The episode ends
///   only after `recoveredAfter` seconds armed without a stall, so a camera that delivers a few frames
///   after each restart and then stops again can't make the app restart forever.
struct FrameWatchdog: Equatable, Sendable {
    enum Stall: Equatable, Sendable {
        /// No new video frame reached the recorder for `timeout` seconds (audio doesn't count).
        case noVideo
        /// Video frames kept arriving for `timeout` seconds without the writer emitting a new segment
        /// (a writer that never becomes ready, or keeps failing and restarting).
        case noSegments
    }

    /// Seconds without progress that count as a stall. Frames normally arrive every 17–33 ms and
    /// segments every second (`segmentInterval`); a new writer's first segment takes 1–2 s. 5 s is
    /// far outside any normal gap, is checked every 0.5 s, and keeps the window in which the app shows
    /// "REC" over a buffer that isn't growing short compared with the shortest buffer (15 s).
    static let timeout: TimeInterval = 5
    /// Automatic restarts per stall episode; the next stall in the same episode gives up (Try Again).
    static let automaticRestartsPerStall = 1
    /// Seconds armed without a stall after which a stall episode counts as over.
    static let recoveredAfter: TimeInterval = 30

    private(set) var isArmed = false
    private var armedAt: TimeInterval = 0
    /// Generations at or below this number are stale.
    private var staleThrough = 0
    /// The generation being watched (0: none yet).
    private var generation = 0
    private var latestVideo: Double?
    private var lastSegmentEnd: Double?
    private var videoProgressAt: TimeInterval = 0
    private var segmentProgressAt: TimeInterval = 0
    /// Stalls reported in the current episode.
    private(set) var stallsInEpisode = 0

    /// Whether the stall just reported may be handled by an automatic restart.
    var mayRestartAutomatically: Bool { stallsInEpisode <= Self.automaticRestartsPerStall }

    /// Starts watching from `now`, with whatever the recorder holds now as the baseline: only frames
    /// and segments newer than that count as progress.
    mutating func arm(at now: TimeInterval, status: RecorderStatus) {
        isArmed = true
        armedAt = now
        videoProgressAt = now
        segmentProgressAt = now
        if status.generation != 0, status.generation > staleThrough, status.generation >= generation {
            generation = status.generation
            latestVideo = status.latestMediaTime
            lastSegmentEnd = status.lastSegmentEnd
        } else {
            // No writer (suspended, or one failed): everything seen so far belongs to the past.
            staleThrough = max(staleThrough, generation, status.generation)
            generation = 0
            latestVideo = nil
            lastSegmentEnd = nil
        }
    }

    /// Stops watching (a deliberate change is under way); `arm` starts again. Keeps the episode budget.
    mutating func disarm() {
        isArmed = false
    }

    /// A user-initiated start (launch, foreground, Try Again) begins a new episode.
    mutating func forgetStalls() {
        stallsInEpisode = 0
    }

    /// Feeds one status snapshot. Returns a stall at most once per arming (it disarms itself), and
    /// counts it against the episode budget (`mayRestartAutomatically`).
    mutating func observe(_ status: RecorderStatus, at now: TimeInterval) -> Stall? {
        guard isArmed else { return nil }
        let g = status.generation
        if g != 0, g > staleThrough, g >= generation {
            if g > generation {
                // A new writer: its first frame and segment are progress.
                generation = g
                latestVideo = nil
                lastSegmentEnd = nil
            }
            if let video = status.latestMediaTime, video > latestVideo ?? -.infinity {
                latestVideo = video
                videoProgressAt = now
            }
            if let end = status.lastSegmentEnd, end > lastSegmentEnd ?? -.infinity {
                lastSegmentEnd = end
                segmentProgressAt = now
            }
        }
        let epsilon = 1e-9
        let stall: Stall?
        if now - videoProgressAt >= Self.timeout - epsilon {
            stall = .noVideo
        } else if videoProgressAt - segmentProgressAt >= Self.timeout - epsilon {
            // Frames kept arriving for `timeout` after the last new segment. (When the camera stops,
            // segments stop a moment before the frames do; that is reported as `.noVideo` instead.)
            stall = .noSegments
        } else {
            stall = nil
        }
        if let stall {
            isArmed = false
            stallsInEpisode += 1
            return stall
        }
        if stallsInEpisode > 0, now - armedAt >= Self.recoveredAfter - epsilon {
            stallsInEpisode = 0
        }
        return nil
    }
}
