import AVFoundation
import Observation
import SwiftUI

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
    /// Not a failure, but something to know (e.g. a save started with low storage, issue #10).
    var isWarning = false
}

enum SaveTrigger: Sendable {
    case button, volumeButton, voice
}

/// What travels through `AppModel`'s ordered source-event channel.
private enum CaptureChannelItem: Sendable {
    /// Something the source reported, in the order it reported it.
    case event(FrameSourceEvent)
    /// Resumed when the consumer reaches it: every event yielded before it has been handled
    /// (`AppModel.waitForCaptureEvents()`).
    case barrier(CheckedContinuation<Void, Never>)
}

/// Single source of truth for the UI. Orchestrates source → recorder → exporter → Photos.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case paused(String)
        /// Capture couldn't start because camera access is denied or restricted (issue #8). Fixed in
        /// the Settings app; see `startFailureNotice`.
        case cameraDenied
        /// Capture couldn't start for another reason (no camera, configuration failed). Try Again.
        case failed(String)
        /// Not enough free space to keep the buffer (issue #10): capture didn't start, or stopped when
        /// free space fell below the reserve. See `startFailureNotice` and `DiskSpacePolicy`.
        case outOfSpace(DiskSpaceCheck)
        /// The user tapped Pause (issue #15): the camera is off and the unsaved buffer discarded until
        /// they tap Resume. Unlike `.paused` (an interruption iOS ends, or a recovery under way) nothing
        /// automatic leaves this phase: not the foreground, not a late source event, not a timer.
        case userPaused

        /// The last start attempt failed (or capture stopped for lack of space); nothing is captured
        /// until a start succeeds: Try Again, the foreground re-check, or (out of space) a settings change.
        var isStartFailure: Bool {
            switch self {
            case .cameraDenied, .failed, .outOfSpace: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var settings: RecordingSettings
    /// What we actually record at (the user's preset, possibly lowered for heat).
    private(set) var activePreset: QualityPreset
    private(set) var thermalLevel: ThermalLevel
    private(set) var thermalMessage: String?
    private(set) var status = RecorderStatus()
    private(set) var batteryLevel: Float?
    private(set) var isCharging = false
    private(set) var isSaving = false
    private(set) var toast: Toast?
    private(set) var isDimmed = false
    private(set) var savedClipCount = 0
    private(set) var fakeLibraryCount = 0
    private(set) var previewImage: UncheckedSendable<CGImage>?
    private(set) var supportedResolutions: [VideoResolution]
    private(set) var orphansRemoved = 0
    private(set) var isVoiceListening = false
    /// The voice trigger stopped itself because speech recognition kept failing (issue #36). Cleared
    /// when it starts again (the next time recording starts or resumes) or is turned off.
    private(set) var voiceRecognitionFailed = false
    private(set) var batteryDrain = BatteryDrainMeter()
    /// Finished clips that haven't reached Photos (kept in `storage.unsavedDirectory`), offered for retry.
    private(set) var unsavedClips: [UnsavedClip] = []
    private(set) var isRetryingUnsaved = false
    /// Why the last attempt to add a clip to Photos failed; cleared by the next success.
    private(set) var lastPhotosError: String?
    /// Result of the add-only Photos request made at launch (nil until answered).
    private(set) var photosAccessGranted: Bool?
    /// What the running source actually delivers (nil while not started). The recorder's audio input
    /// follows this, never the "Record sound" setting alone (issue #3).
    private(set) var activeCapture: ActiveCapture?
    /// Automatic capture recovery in progress (issue #4); nil otherwise. See `recoverCapture(_:)`.
    private(set) var recovery: CaptureRecovery?
    /// Set when an automatic restart after a frame stall (issue #9) brought recording back; drives
    /// `stallNotice` until the buffer has refilled or capture stops. nil otherwise.
    private(set) var recoveredStall: RecoveredStall?
    /// The user paused capture (issue #15; `pauseCapture()`): only `resumeCapture()` clears it. Not
    /// persisted: a relaunch starts recording as before (DESIGN.md "User pause").
    private(set) var isUserPaused = false
    /// The last free-space check while capture runs (issue #10); drives `diskSpaceNotice`. nil when
    /// capture isn't running.
    private(set) var diskSpace: DiskSpaceCheck?
    /// Free space as last read (start, periodic check, save, Settings sheet); nil if unknown or not read.
    /// Net of what a running save has reserved but not written yet (issue #14, `TemporarySpace`).
    private(set) var availableDiskBytes: Int64?
    /// RewindCam's media on disk as last measured (issue #14; the Settings sheet measures it when it opens).
    private(set) var workingSet = MediaWorkingSet()

    /// A frame stall that an automatic restart recovered from: what stalled and when it restarted.
    struct RecoveredStall: Equatable {
        let stall: FrameWatchdog.Stall
        let restartedAt: Date
    }

    /// One automatic recovery: why it started and how much of its restart budget is spent.
    struct CaptureRecovery: Equatable {
        /// Identifies this recovery, so a backoff timer or attempt from an earlier one does nothing.
        let id: Int
        let reason: CaptureRecoveryReason
        /// The capture generation it was started in (`captureGeneration`); a newer one supersedes it.
        let generation: Int
        var backoff = RestartBackoff()
    }

    let environment: AppEnvironment
    let recorder: RollingRecorder
    /// Free space net of reservations by running saves (issue #14). Every free-space read goes through it.
    let temporarySpace: TemporarySpace
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    /// Pipeline work queued or running. While non-zero the pipeline owns phase and recorder: source
    /// events are recorded, and applied when the last piece of work finishes (`schedulePipeline`).
    @ObservationIgnored private var pipelineDepth = 0
    @ObservationIgnored private var sourceEventsWhilePipelineBusy = false
    /// What the source last reported: the interruption in effect, or nil once it said it runs again.
    @ObservationIgnored private var sourceInterruption: InterruptionReason?
    @ObservationIgnored private var recoveryCounter = 0
    /// Checks on every status tick that video and segments keep arriving (issue #9); see `checkFrameWatchdog()`.
    @ObservationIgnored private(set) var frameWatchdog = FrameWatchdog()
    @ObservationIgnored private var statusLoopRunning = false
    /// When the free space was last read for `checkDiskSpace()` (monotonic seconds).
    @ObservationIgnored private var lastDiskCheck: TimeInterval?
    /// The ordered source-event channel (issue #4); see `handle(_:)`.
    private let captureEvents: AsyncStream<CaptureChannelItem>.Continuation
    /// Source events handled so far (tests compare it with how many were emitted).
    @ObservationIgnored private(set) var handledSourceEvents = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Dim (issue #38): the brightness to put back while RewindCam holds the system brightness at
    /// `dimmedBrightness`; nil while it doesn't (awake, or dimmed with the scene not active). Mirrored in
    /// `settingsStore` (`saveDimRestore`) so the next launch can put it back after a kill.
    @ObservationIgnored private var savedBrightness: CGFloat?
    /// What the screen read back after Dim set `dimmedBrightness` (a device may clamp or round it); the
    /// level that counts as "still dimmed" when putting `savedBrightness` back. Persisted with it.
    @ObservationIgnored private var dimmedReadBack: CGFloat?
    /// The scene is `.active` (last `scenePhaseChanged`). The system brightness follows Dim only then;
    /// the overlay stays up regardless. True until told otherwise: Dim is tapped in an active scene.
    @ObservationIgnored private var sceneIsActive = true
    /// The brightness a previous run left to restore has been looked at (`restoreBrightnessFromLastRun`).
    @ObservationIgnored private var checkedLastRunBrightness = false
    @ObservationIgnored private var wantsRunning = false
    /// Capture generation (issue #15): bumped by every change of intent -- `start()`, `stop()`,
    /// `pauseCapture()`, `resumeCapture()`. Work queued for one generation (a start, a reconfigure, a
    /// recovery) checks it after every `await` (`isCurrent(_:)`), so a completion that arrives after a
    /// pause, a background or a newer start publishes nothing and leaves no session running.
    @ObservationIgnored private(set) var captureGeneration = 0
    @ObservationIgnored private var didCleanUp = false
    @ObservationIgnored private var didRequestPhotosAccess = false
    /// Kept clips a save is still handing to Photos; hidden from `unsavedClips` so Retry can't race it.
    @ObservationIgnored private var clipsInFlight: Set<String> = [] // file names
    @ObservationIgnored private var appliedCapture: CaptureConfiguration?
    /// Source → recorder, plus an optional tap for the voice trigger.
    private let fanOut: SampleFanOut
    /// Bumped on every voice start/stop so a stale authorization callback can't start a second session.
    @ObservationIgnored private var voiceSession = 0
    /// What VoiceOver was last told (issue #11; `announceChanges()`): the phase, the thermal message and
    /// the notices on screen. Only a difference is announced, so the 0.5 s status tick can't repeat one.
    @ObservationIgnored private var announcedPhase: Phase = .idle
    @ObservationIgnored private var announcedThermalMessage: String?
    @ObservationIgnored private var announcedNoticeIDs: Set<String> = []

    init(environment: AppEnvironment) {
        self.environment = environment
        let loaded = environment.settingsStore.load()
        let thermal = environment.thermal.level
        let effective = QualityGovernor.effectivePreset(user: loaded.preset, thermal: thermal)
        settings = loaded
        thermalLevel = thermal
        activePreset = effective
        thermalMessage = QualityGovernor.message(user: loaded.preset, effective: effective, thermal: thermal)
        supportedResolutions = environment.source.supportedResolutions(for: loaded.camera)
        let space = TemporarySpace(capacity: environment.diskCapacity)
        temporarySpace = space
        recorder = RollingRecorder(
            bufferDirectory: environment.storage.bufferDirectory,
            clipsDirectory: environment.storage.clipsDirectory,
            // No audio until a started source says it delivers some (`bringUp`).
            configuration: RollingRecorder.Configuration(bufferSeconds: loaded.bufferSeconds, preset: effective,
                                                         audioEnabled: false,
                                                         realTime: environment.realTime),
            space: space)

        fanOut = SampleFanOut(primary: recorder)
        // Source events arrive on any thread. They go through one AsyncStream, consumed by one
        // main-actor task, so they are handled strictly in the order the source emitted them (issue #4;
        // one unstructured Task per event could run them out of order).
        let (events, captureEvents) = AsyncStream<CaptureChannelItem>.makeStream()
        self.captureEvents = captureEvents
        environment.thermal.onChange = { [weak self] level in self?.thermalChanged(level) }
        environment.source.setSink(fanOut)
        environment.source.setEventHandler { event in captureEvents.yield(.event(event)) }
        Task { [weak self] in
            for await item in events {
                switch item {
                case .event(let event): self?.handle(event)
                case .barrier(let reached): reached.resume()
                }
            }
        }
        if let synthetic = environment.source as? SyntheticFrameSource {
            synthetic.setPreviewHandler { [weak self] image in
                guard let self else { return }
                Task { @MainActor in self.previewImage = image }
            }
        }
        // A phone that is already hot at launch shows the banner; only later changes are announced.
        announcedThermalMessage = thermalMessage
        // Issue #37: follows how the phone is held, so a save can turn its clip upright.
        environment.orientation.start()
        refreshStatus()
    }

    deinit {
        captureEvents.finish() // ends the consumer task
    }

    // MARK: Derived state

    var captureSession: AVCaptureSession? { environment.source.captureSession }
    var isUITest: Bool { environment.isUITest }
    var supportsCaptureButtons: Bool { environment.supportsCaptureButtons }

    /// Seconds of footage a save would contain right now (never more than the buffer length).
    var readySeconds: Int { Int(min(status.bufferedSeconds, Double(settings.bufferSeconds)).rounded(.down)) }

    var estimatedBufferBytes: Int64 {
        RollingRecorder.Configuration(bufferSeconds: settings.bufferSeconds, preset: activePreset,
                                      audioEnabled: settings.audioEnabled).byteCap
    }

    var isVoiceAvailable: Bool { environment.voice?.isAvailable ?? false }

    // MARK: Free space (issue #10; DESIGN.md §2 "Bounded disk" → "Free space")

    /// The free-space policy for the current settings at the preset actually recorded. Sized with the
    /// "Record sound" setting rather than what the source delivers: before a start that isn't known yet,
    /// and the audio track only ever makes the estimate larger (64 kb/s).
    var diskPolicy: DiskSpacePolicy { diskSpacePolicy(bufferSeconds: settings.bufferSeconds) }

    func diskSpacePolicy(bufferSeconds: Int) -> DiskSpacePolicy {
        DiskSpacePolicy(bufferSeconds: bufferSeconds, preset: activePreset, audioEnabled: settings.audioEnabled,
                        postRollSeconds: settings.postRollSeconds)
    }

    /// Total size of the finished clips kept for Photos (#1). They use free space like any file, and
    /// RewindCam never deletes them to make room; the notices say how much they take.
    var unsavedClipBytes: Int64 { unsavedClips.reduce(0) { $0 + $1.bytes } }

    /// "2 clips waiting for Photos use 76 MB." (empty when there are none).
    var unsavedClipsSpaceSentence: String {
        let count = unsavedClips.count
        guard count > 0 else { return "" }
        let size = BufferMath.formatted(bytes: unsavedClipBytes)
        return count == 1 ? "1 clip waiting for Photos uses \(size)." : "\(count) clips waiting for Photos use \(size)."
    }

    /// Where on the phone to free space. RewindCam can't open that page, so the notices name it.
    static let storageHint = "Settings › General › iPhone Storage"

    /// The out-of-space message (issue #10): what doesn't fit, about how much to free (enough for the
    /// buffer and one save), the in-app alternative, and what unsaved clips take.
    func outOfSpaceMessage(_ check: DiskSpaceCheck) -> String {
        var message = "Not enough free space to keep a \(settings.bufferSeconds) s buffer at \(activePreset). "
            + "Free up about \(BufferMath.formatted(bytes: check.bytesToFree)) (\(Self.storageHint)) "
            + "or choose a shorter buffer or lower quality in Settings."
        let unsaved = unsavedClipsSpaceSentence
        if !unsaved.isEmpty { message += " " + unsaved }
        return message
    }

    /// Shown while recording with free space between the reserve and room for the buffer plus a save
    /// (issue #10): recording continues, but a save may not fit.
    var diskSpaceNotice: AppNotice? {
        guard phase == .recording, let check = diskSpace, check.level == .saveMayNotFit else { return nil }
        let free = check.availableBytes.map { BufferMath.formatted(bytes: $0) } ?? "little"
        var message = "About \(free) free. A save at these settings can need up to "
            + "\(BufferMath.formatted(bytes: diskPolicy.requiredBytesToSave)), so it may end early or fail. "
            + "Recording stops if free space falls below \(BufferMath.formatted(bytes: DiskSpacePolicy.reserveBytes)). "
            + "Free up about \(BufferMath.formatted(bytes: check.bytesToFree)) (\(Self.storageHint))."
        let unsaved = unsavedClipsSpaceSentence
        if !unsaved.isEmpty { message += " " + unsaved }
        return AppNotice(id: "lowDiskWarningBanner", systemImage: "externaldrive.badge.exclamationmark",
                         title: "Storage is low", message: message, severity: .warning, action: nil,
                         spoken: "Storage is low. A save may not fit, and recording stops if free space runs out.")
    }

    /// Settings sheet: would a `bufferSeconds` buffer at the current quality fit in the free space?
    /// The running ring's bytes count as available (a new buffer length reuses or deletes them).
    func diskSpaceCheck(bufferSeconds: Int) -> DiskSpaceCheck {
        diskSpacePolicy(bufferSeconds: bufferSeconds)
            .beforeBuffering(availableBytes: availableDiskBytes.map { $0 + status.bytes })
    }

    /// Buffer lengths that don't fit at the current quality (Settings lists them).
    var bufferChoicesThatDontFit: [Int] {
        RecordingSettings.bufferChoices.filter { diskSpaceCheck(bufferSeconds: $0).level == .tooLow }
    }

    /// Reads free space now and measures the working set (the Settings sheet calls this when it opens).
    func refreshDiskSpace() {
        availableDiskBytes = temporarySpace.unreservedBytes()
        workingSet = environment.storage.measureWorkingSet()
    }

    /// The most RewindCam's temporary media can take at the current settings (issue #14): ring + one
    /// save's job folder + its export output. Kept clips come on top (`unsavedClipBytes`).
    var temporaryMediaCapBytes: Int64 {
        BufferMath.temporaryMediaCapBytes(
            RollingRecorder.Configuration(bufferSeconds: settings.bufferSeconds, preset: activePreset,
                                          audioEnabled: settings.audioEnabled),
            postRollSeconds: Double(settings.postRollSeconds))
    }

    static let photosDeniedHint = "Photos access is off. Saved clips stay in RewindCam until you allow it "
        + "in Settings › RewindCam › Photos, then tap Retry."

    /// What to tell the user about Photos, if anything (shown with the unsaved-clips banner).
    var photosProblem: String? {
        if let lastPhotosError { return lastPhotosError }
        return photosAccessGranted == false ? Self.photosDeniedHint : nil
    }

    /// The voice trigger needs the microphone even when sound isn't recorded into clips.
    var captureConfiguration: CaptureConfiguration {
        CaptureConfiguration(preset: activePreset,
                             audioEnabled: settings.audioEnabled || (settings.voiceTriggerEnabled && isVoiceAvailable),
                             camera: settings.camera)
    }

    private var measuredConfiguration: String {
        "\(activePreset), voice \(isVoiceListening ? "on" : "off")"
    }

    /// Audio is written only if the user wants sound *and* the running source captures it. A writer
    /// with an audio input that is never fed stalls (no segments), so this must follow the source.
    var recorderConfiguration: RollingRecorder.Configuration {
        RollingRecorder.Configuration(bufferSeconds: settings.bufferSeconds, preset: activePreset,
                                      audioEnabled: settings.audioEnabled && activeCapture?.audioCaptured == true,
                                      realTime: environment.realTime)
    }

    /// Why the microphone isn't captured although sound or the voice trigger needs it (nil otherwise).
    private var microphoneProblem: AudioUnavailableReason? {
        guard let reason = activeCapture?.audioUnavailable,
              settings.audioEnabled || wantsVoiceTrigger else { return nil }
        return reason
    }

    private var wantsVoiceTrigger: Bool { settings.voiceTriggerEnabled && isVoiceAvailable }

    /// Shown while capture runs without the microphone that "Record sound" or the voice trigger needs.
    /// The settings themselves are left as the user chose them.
    var microphoneNotice: AppNotice? {
        guard let reason = microphoneProblem else { return nil }
        let sound = settings.audioEnabled
        let voice = wantsVoiceTrigger
        let title = sound && voice ? "Sound and the voice trigger are off"
            : sound ? "Sound is off" : "The voice trigger can't listen"
        let consequence = sound ? ", so clips are saved without sound" : ""
        switch reason {
        case .microphoneDenied:
            return AppNotice(id: "microphoneBanner", systemImage: "mic.slash.fill", title: title,
                             message: "Microphone access is denied\(consequence). "
                                 + "Allow it in Settings › RewindCam › Microphone.",
                             severity: .warning, action: .openSettings)
        case .microphoneUnavailable(let why):
            return AppNotice(id: "microphoneBanner", systemImage: "mic.slash.fill", title: title,
                             message: "The microphone can't be used (\(why))\(consequence).",
                             severity: .warning, action: nil)
        }
    }

    static let cameraDeniedMessage = "RewindCam needs the camera to keep the last moments ready to save. "
        + "Allow it in Settings › RewindCam › Camera."

    /// Shown while capture couldn't start (issue #8): camera denied → **Open Settings**; any other
    /// start failure → **Try Again**. Either way the app also re-checks when it returns to the
    /// foreground (`scenePhaseChanged(.active)`), e.g. after the user allowed the camera in Settings.
    var startFailureNotice: AppNotice? {
        switch phase {
        case .cameraDenied:
            AppNotice(id: "cameraDeniedBanner", systemImage: "video.slash.fill", title: "Camera access is off",
                      message: Self.cameraDeniedMessage, severity: .error, action: .openSettings)
        case .failed(let why):
            AppNotice(id: "errorBanner", systemImage: "exclamationmark.triangle.fill", title: "Not recording",
                      message: why, severity: .error, action: .tryAgain)
        case .outOfSpace(let check):
            // Try Again, not Open Settings: RewindCam's page in Settings can't free space, and iOS has no
            // public link to iPhone Storage, so the message names it. The app also checks again on
            // return to the foreground and when the buffer or quality changes in Settings.
            AppNotice(id: "lowDiskBanner", systemImage: "externaldrive.badge.xmark",
                      title: "Not recording: not enough free space", message: outOfSpaceMessage(check),
                      severity: .error, action: .tryAgain)
        default:
            nil
        }
    }

    /// Shown after the frame watchdog (issue #9) restarted the camera on its own and recording came back:
    /// says that video had stopped, when the camera was restarted, and that the footage from before is
    /// gone. Clears itself once the buffer holds a full buffer length again, or when capture stops.
    var stallNotice: AppNotice? {
        guard let recoveredStall, phase == .recording else { return nil }
        let what = switch recoveredStall.stall {
        case .noVideo: "No new video arrived for \(Int(FrameWatchdog.timeout)) s"
        case .noSegments: "Video stopped reaching the buffer"
        }
        let time = recoveredStall.restartedAt.formatted(date: .omitted, time: .shortened)
        return AppNotice(id: "stallBanner", systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                         title: "The camera was restarted",
                         message: "\(what), so RewindCam restarted the camera at \(time). "
                             + "Footage from before then is gone; Save has what was recorded since.",
                         severity: .warning, action: nil,
                         spoken: "The camera was restarted because video had stopped. "
                             + "Footage from before then is gone; Save has what was recorded since.")
    }

    /// Shown while the user has paused (issue #15): that nothing is recorded, that the unsaved buffer was
    /// discarded and saved clips are kept, and that it stays paused until Resume. No action: the Resume
    /// button sits where Pause was, next to Save.
    var userPausedNotice: AppNotice? {
        guard phase == .userPaused else { return nil }
        return AppNotice(id: "userPausedBanner", systemImage: "pause.circle.fill",
                         title: "Paused: the camera is off",
                         message: "Nothing is being recorded, and the unsaved buffer was discarded. "
                             + "Clips you saved, and clips waiting for Photos, are kept. RewindCam stays "
                             + "paused, also when you leave and come back, until you tap Resume.",
                         severity: .info, action: nil)
    }

    /// What Pause discards, for the confirmation before it (issue #15). nil when nothing is buffered.
    var pauseDiscardWarning: String? {
        guard phase == .recording, readySeconds > 0 else { return nil }
        return "The last \(readySeconds) s haven't been saved and will be discarded. Clips you saved, "
            + "and clips waiting for Photos, are kept. Recording stays off until you tap Resume."
    }

    /// Why Save can't do anything right now (nil while recording: nothing is buffered in any other
    /// phase). The Save button is disabled and says this in its accessibility hint; a save from the
    /// volume buttons shows it as a toast.
    var saveUnavailableReason: String? {
        switch phase {
        case .recording: nil
        case .idle, .starting: "The camera is starting."
        case .paused: "Recording is paused."
        case .cameraDenied: "Camera access is off, so nothing is being recorded."
        case .failed: "The camera isn't running, so nothing is being recorded."
        case .outOfSpace: "There isn't enough free space to record."
        case .userPaused: "Recording is paused. Tap Resume to record again."
        }
    }

    /// The "Listening" row in Settings.
    var voiceListeningLabel: String {
        if isVoiceListening { return "Yes" }
        if wantsVoiceTrigger, let reason = microphoneProblem {
            return reason == .microphoneDenied ? "No — microphone access is denied" : "No — microphone unavailable"
        }
        return voiceRecognitionFailed ? "No — \(Self.speechRecognitionUnavailable)" : "No"
    }

    /// Why the voice trigger stopped itself (issue #36): the "Listening" row and the toast.
    static let speechRecognitionUnavailable = "speech recognition isn't available"

    // MARK: Lifecycle

    /// Launch, foreground, Try Again and Resume. Does nothing while the user has paused (issue #15):
    /// only `resumeCapture()` clears that, then comes here.
    func start() {
        guard !isUserPaused else { return }
        wantsRunning = true
        captureGeneration += 1
        let generation = captureGeneration
        // Launch, foreground or Try Again: a fresh session, with a fresh stall budget (issue #9).
        frameWatchdog.forgetStalls()
        recoveredStall = nil
        schedulePipeline { model in await model.bringUp(generation) }
    }

    func stop(reason: InterruptionReason? = nil) {
        wantsRunning = false
        captureGeneration += 1
        schedulePipeline { model in await model.tearDown(reason: reason) }
    }

    // MARK: User pause (issue #15; DESIGN.md "User pause")

    /// **Pause** (issue #15): the user turns capture off until they tap Resume. Everything automatic
    /// stops at once, before any `await`: the generation moves on (a start, reconfigure or restart still
    /// running publishes nothing and stops what it started), recovery and its timers end, the frame
    /// watchdog is disarmed, the voice trigger stops, the recorder is suspended (the unsaved buffer is
    /// discarded; a save waiting for its post-roll gets what is there), the screen wakes from Dim and may
    /// lock again. The source is stopped on the pipeline, after whatever is running there.
    func pauseCapture() {
        guard !isUserPaused else { return }
        isUserPaused = true
        wantsRunning = false
        captureGeneration += 1
        endRecovery()
        frameWatchdog.disarm()
        recoveredStall = nil
        diskSpace = nil
        sourceInterruption = nil
        activeCapture = nil
        appliedCapture = nil
        stopVoice()
        recorder.suspend()
        setDimmed(false)
        environment.screen.setIdleTimerDisabled(false)
        previewImage = nil
        phase = .userPaused
        refreshStatus()
        schedulePipeline { model in await model.tearDown(reason: nil) }
    }

    /// **Resume** (issue #15): clears the pause and starts like a launch (a fresh generation, stall
    /// budget and free-space check).
    func resumeCapture() {
        guard isUserPaused else { return }
        isUserPaused = false
        phase = .starting
        start()
    }

    /// Awaits all queued start/stop/restart work (tests).
    func waitForPipeline() async {
        while let task = pipelineTask {
            await task.value
            if task == pipelineTask { break }
        }
    }

    /// Returns once every source event emitted before the call has been handled (tests).
    func waitForCaptureEvents() async {
        await withCheckedContinuation { (reached: CheckedContinuation<Void, Never>) in
            if case .terminated = captureEvents.yield(.barrier(reached)) { reached.resume() }
        }
    }

    /// Awaits pipeline work and source events until neither has anything left, e.g. an event that
    /// started a recovery attempt whose restart emitted another event (tests).
    func waitForCapture() async {
        repeat {
            await waitForPipeline()
            await waitForCaptureEvents()
        } while pipelineDepth > 0
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            restoreBrightnessFromLastRun()
            sceneIsActive = true
            // Back from Control Center, a call or an alert with the overlay still up: dim again (#38).
            if isDimmed { lowerBrightness() }
            // Not running (launch, back from the background), or the last start failed: start again.
            // The failed case is how "allowed the camera in Settings and came back" recovers when iOS
            // doesn't background the app in between (e.g. a permission prompt was just answered).
            // An explicit pause (#15) holds: `start()` does nothing until Resume.
            if !wantsRunning || self.phase.isStartFailure { start() }
        case .background:
            sceneIsActive = false
            setDimmed(false)
            stop(reason: .backgrounded)
        default:
            // .inactive (Control Center, Notification Centre, alerts, an incoming call, the app switcher):
            // capture keeps running and the overlay stays, but the brightness goes back so what iOS shows
            // is readable (#38); `.active` dims again. Nothing is announced: nothing changed for the user.
            restoreBrightnessFromLastRun()
            sceneIsActive = false
            restoreBrightness()
        }
    }

    /// "Try Again" (`AppNotice.Action.tryAgain`) after a start failure. Goes through `start()`, the
    /// same pipeline as launch and foreground; ignored unless the last start failed, so a double tap
    /// queues only one attempt.
    func retryStart() {
        guard phase.isStartFailure, !isUserPaused else { return }
        phase = .starting
        // If this attempt fails the same way, VoiceOver says so again (issue #11).
        announceChanges()
        start()
    }

    // MARK: Settings

    func updateSettings(_ change: (inout RecordingSettings) -> Void) {
        var new = settings
        change(&new)
        guard new != settings else { return }
        let old = settings
        if new.camera != old.camera {
            supportedResolutions = environment.source.supportedResolutions(for: new.camera)
            if !supportedResolutions.contains(new.resolution) {
                let wanted = new.resolution
                new.resolution = supportedResolutions.filter { $0 <= wanted }.max() ?? .hd720
            }
        }
        settings = new
        environment.settingsStore.save(new)
        applyQuality()
        if new.voiceTriggerEnabled != old.voiceTriggerEnabled {
            if new.voiceTriggerEnabled {
                startVoiceIfNeeded()
            } else {
                stopVoice()
                voiceRecognitionFailed = false // turning it on again is a fresh try
            }
        }
    }

    // MARK: Thermal

    private func thermalChanged(_ level: ThermalLevel) {
        thermalLevel = level
        applyQuality()
    }

    /// Recomputes the effective preset; restarts capture only if what we capture changed.
    private func applyQuality() {
        // A new writer (or a restart) may be coming: no stall until it has had the full timeout (#9).
        frameWatchdog.disarm()
        let effective = QualityGovernor.effectivePreset(user: settings.preset, thermal: thermalLevel)
        thermalMessage = QualityGovernor.message(user: settings.preset, effective: effective, thermal: thermalLevel)
        activePreset = effective
        if automaticCaptureAllowed, case .outOfSpace = phase {
            // Stopped for lack of space: a shorter buffer or lower quality may fit now (issue #10).
            recorder.reconfigure(recorderConfiguration)
            refreshStatus()
            retryStart()
            return
        }
        let capture = captureConfiguration
        if automaticCaptureAllowed, let applied = appliedCapture, applied != capture {
            let generation = captureGeneration
            schedulePipeline { model in
                await model.tearDown(reason: nil)
                await model.bringUp(generation)
            }
        } else {
            // Buffer length changes apply in place without losing footage.
            recorder.reconfigure(recorderConfiguration)
            // A longer buffer is checked like a start (issue #10): it must fit next to what the ring
            // already holds, or recording stops with the out-of-space notice instead of filling the disk.
            if automaticCaptureAllowed, phase == .recording, pipelineDepth == 0 {
                let ringBytes = recorder.status().bytes
                let check = diskPolicy.beforeBuffering(availableBytes: readDiskSpace().map { $0 + ringBytes })
                if check.level == .tooLow {
                    schedulePipeline { model in await model.stopForLowDisk(check) }
                } else {
                    diskSpace = check
                }
            }
        }
        refreshStatus()
    }

    // MARK: Save
    //
    // Save path (DESIGN.md §2, "Save path"):
    //  1. The recorder hard-links the segments into a job folder in Caches/RewindClips.
    //  2. The clip is exported to UnsavedClips/<name>.partial.mov (Application Support) and renamed
    //     to .mov once complete. The job folder is then deleted; the .mov is the durable copy.
    //  3. Photos gets a disposable hard link of the .mov. Only when Photos reports success is the
    //     .mov deleted. On failure it stays, the user is told, and Retry offers it again, also
    //     after a relaunch.
    // The whole save runs inside a background-task assertion.

    @discardableResult
    func save(trigger: SaveTrigger = .button) -> Task<Void, Never>? {
        guard !isSaving else {
            showToast("Already saving — hold on…")
            return nil
        }
        if let reason = saveUnavailableReason {
            // The button is disabled; this is the volume buttons (or a stale voice callback).
            environment.haptics.failure()
            showToast("Can't save. \(reason)", isError: true)
            return nil
        }
        // Issue #10: low free space never refuses a save (a shorter clip beats none); it warns. Issue #14
        // then sizes the export from the files themselves (`exportDurably`).
        let available = temporarySpace.unreservedBytes()
        availableDiskBytes = available
        let lowSpace = diskPolicy.beforeSave(availableBytes: available).level == .saveMayNotFit
        let postRoll = Double(settings.postRollSeconds)
        let ticket = recorder.beginSave(postRoll: postRoll)
        // Issue #37: the clip is turned for the way the phone is held now, at the tap.
        let orientation = clipOrientationAtTap
        isSaving = true
        let background = environment.backgroundTasks.begin(name: "Save clip")
        if trigger == .voice { environment.haptics.success() }
        let recordingMore = postRoll > 0 && !ticket.isFulfilled
        if lowSpace {
            let free = BufferMath.formatted(bytes: available ?? 0)
            let need = BufferMath.formatted(bytes: diskPolicy.requiredBytesToSave)
            var message = "Storage is low: about \(free) free, and this save can need up to \(need). "
            message += "Saving anyway; the clip may end early or fail."
            if recordingMore { message += " Recording \(settings.postRollSeconds) s more…" }
            showToast(message, isWarning: true)
        } else if recordingMore {
            showToast("Saving… recording \(settings.postRollSeconds) s more")
        }
        return Task {
            await exportAndAddToPhotos(ticket, lowSpace: lowSpace, orientation: orientation)
            isSaving = false
            refreshStatus()
            environment.backgroundTasks.end(background)
        }
    }

    /// Adds every unsaved clip to Photos, oldest first, stopping at the first failure.
    @discardableResult
    func retryUnsavedClips() -> Task<Void, Never>? {
        let clips = unsavedClips
        guard !isRetryingUnsaved, !clips.isEmpty else { return nil }
        isRetryingUnsaved = true
        let background = environment.backgroundTasks.begin(name: "Retry unsaved clips")
        return Task {
            var added = 0
            var failure: Error?
            for clip in clips {
                do {
                    try await addToPhotos(clip)
                    added += 1
                } catch {
                    failure = error
                    break
                }
            }
            savedClipCount += added
            reloadUnsavedClips()
            if let failure {
                photosFailed(failure)
            } else {
                lastPhotosError = nil
                photosAccessGranted = true
                environment.haptics.success()
                showToast(added == 1 ? "Saved 1 clip to Photos" : "Saved \(added) clips to Photos")
            }
            isRetryingUnsaved = false
            refreshStatus()
            environment.backgroundTasks.end(background)
        }
    }

    /// Why a saved clip is shorter than asked (issue #14).
    static func shortenedSentence(_ limit: SaveLimit) -> String {
        switch limit {
        case .freeSpace:
            "It's shorter than asked: there wasn't enough free space for all of it (\(storageHint))."
        case .workingSetCap:
            "It's shorter than asked: the video took more space than RewindCam allows a save."
        }
    }

    private func exportAndAddToPhotos(_ ticket: SaveTicket, lowSpace: Bool, orientation: ClipOrientation) async {
        let exported: (clip: UnsavedClip, duration: Double, endedEarly: Bool, limit: SaveLimit?)
        do {
            exported = try await exportDurably(ticket, orientation: orientation)
        } catch {
            // Includes a post-roll settled with nothing buffered because video stopped (#9):
            // `RecorderError.videoStopped` says to save again once recording is back.
            environment.haptics.failure()
            var message = error.localizedDescription
            // A `StorageSpaceError` already says how much to free and where.
            if lowSpace, !(error is StorageSpaceError) {
                message += " Storage is low: free up space (\(Self.storageHint)), then save again."
            }
            showToast(message, isError: true)
            return
        }
        let clip = exported.clip
        clipsInFlight.insert(clip.name)
        defer {
            clipsInFlight.remove(clip.name)
            reloadUnsavedClips()
        }
        do {
            try await addToPhotos(clip)
            savedClipCount += 1
            lastPhotosError = nil
            environment.haptics.success()
            let seconds = Int(exported.duration.rounded())
            var message = "Saved \(seconds) s clip to Photos"
            // Recording stopped (interruption, or video stopped arriving, #9) before the clip's end.
            if exported.endedEarly {
                message += ". It ends early: recording stopped before the end you asked for."
            }
            // Cut to what fits (issue #14): says so, never silently shorter.
            if let limit = exported.limit {
                message += exported.endedEarly ? " " : ". "
                message += Self.shortenedSentence(limit)
            }
            showToast(message)
        } catch {
            photosFailed(error)
        }
    }

    /// Waits for the segments, exports to `<name>.partial.mov` in the unsaved-clips folder and renames
    /// it to `.mov` only once the export is complete. The job folder in Caches is always discarded.
    ///
    /// Issue #14: before anything is written, the export's peak (concatenated source + output, from the
    /// bundle's actual file sizes) is reserved in `temporarySpace` above `saveFloorBytes`. If only part
    /// fits, the newest part is exported (the clip still ends where asked, `SaveLimit.freeSpace`); if not
    /// even the newest second fits, nothing is written and the error says how much to free.
    private func exportDurably(_ ticket: SaveTicket, orientation: ClipOrientation) async throws
        -> (clip: UnsavedClip, duration: Double, endedEarly: Bool, limit: SaveLimit?) {
        let storage = environment.storage
        var bundle = try await ticket.bundle()
        defer { bundle.discard() }
        let floor = saveFloorBytes
        switch DiskSpacePolicy.exportAdmission(initBytes: bundle.initBytes, segmentBytes: bundle.segments.map(\.bytes),
                                               availableBytes: temporarySpace.unreservedBytes(), floorBytes: floor) {
        case .all: break
        case .newest(let count): bundle = bundle.keepingNewest(count)
        case .none(let bytesToFree): throw StorageSpaceError.noRoomToExport(bytesToFree: bytesToFree)
        }
        let source = bundle.sourceBytes
        let peak = BufferMath.exportPeakBytes(sourceBytes: source)
        guard let reservation = temporarySpace.reserve(peak, floor: floor) else {
            // Something else took the space since the admission above.
            let room = (temporarySpace.unreservedBytes() ?? 0) - floor
            throw StorageSpaceError.noRoomToExport(bytesToFree: max(1, peak - room))
        }
        defer { reservation.release() }
        let partial = try storage.partialClipURL(baseName: ClipExporter.defaultBaseName())
        do {
            let output = try await ClipExporter.export(bundle, to: partial,
                                                       outputByteLimit: BufferMath.exportOutputBytes(sourceBytes: source),
                                                       orientation: orientation)
            let clip = try storage.commitPartialClip(output.url)
            // Settled early (`RollingRecorder.resolveEarly` / `settlePendingSave`): footage stops short.
            let endedEarly = bundle.clipEnd < bundle.requestedEnd - 0.5
            return (clip, output.duration, endedEarly, bundle.limit)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Hands Photos a hard link of the kept clip, so the kept copy survives whatever Photos does with
    /// the file on failure. The kept copy is deleted only after Photos reports success.
    private func addToPhotos(_ clip: UnsavedClip) async throws {
        let storage = environment.storage
        let library = environment.photoLibrary
        // A staging copy (only if hard links fail) is admitted like any temporary media (issue #14).
        let staged = try storage.stageForPhotos(clip, space: temporarySpace, floor: saveFloorBytes)
        defer { storage.discardStaging(staged) }
        try await library.saveVideo(at: staged)
        storage.removeUnsavedClip(clip)
    }

    /// What a save's temporary files must leave free right now (issue #14): the reserve while the
    /// recorder writes, nothing more once capture has stopped.
    private var saveFloorBytes: Int64 {
        let status = recorder.status()
        return DiskSpacePolicy.saveFloorBytes(captureRunning: !status.isSuspended && status.halt == nil)
    }

    private func photosFailed(_ error: Error) {
        if let photosError = error as? PhotoLibraryError, case .accessDenied = photosError {
            photosAccessGranted = false
        }
        lastPhotosError = error.localizedDescription
        environment.haptics.failure()
        showToast("Not added to Photos. The clip is kept in RewindCam — tap Retry.", isError: true)
    }

    private func reloadUnsavedClips() {
        unsavedClips = environment.storage.unsavedClips().filter { !clipsInFlight.contains($0.name) }
    }

    /// Asks for add-only Photos access once per launch, right after the camera starts, so the prompt
    /// is answered before the first save. Not awaited by the pipeline: a pending prompt can't stall
    /// start/stop. A denial costs nothing: clips are kept until access is allowed.
    private func requestPhotosAccessOnce() {
        guard !didRequestPhotosAccess else { return }
        didRequestPhotosAccess = true
        let library = environment.photoLibrary
        Task {
            photosAccessGranted = await library.requestAddAccess()
        }
    }

    // MARK: Settings app

    /// Every "Open Settings" button ends here (`AppNotice.Action.openSettings`).
    func openAppSettings() {
        environment.appSettings.openAppSettings()
    }

    // MARK: Dim mode

    /// The system screen brightness while dimmed (and the scene is active).
    static let dimmedBrightness: CGFloat = 0.02

    /// Dim is for long recording sessions; while the user has paused (#15) nothing records and the screen
    /// may lock, so dimming is refused (the button is disabled) and pausing wakes the screen.
    ///
    /// `isDimmed` is the overlay. The system brightness follows it only while the scene is active
    /// (issue #38; `scenePhaseChanged`): `.inactive` puts it back so iOS's own screens are readable,
    /// `.active` lowers it again. Waking puts back the level from before only if the screen is still at
    /// `dimmedBrightness`; a level the user or auto-brightness set meanwhile is left alone.
    func setDimmed(_ dimmed: Bool) {
        guard dimmed != isDimmed, !(dimmed && isUserPaused) else { return }
        isDimmed = dimmed
        if dimmed {
            if sceneIsActive { lowerBrightness() }
        } else {
            restoreBrightness()
        }
    }

    /// Remembers the current brightness (in memory and in the store, written first so a kill from here on
    /// can be undone at the next launch), lowers it, and remembers what the screen then reports.
    /// Does nothing if already lowered.
    private func lowerBrightness() {
        restoreBrightnessFromLastRun() // never overwrite what a killed run left to restore
        guard savedBrightness == nil else { return }
        let current = environment.screen.brightness
        savedBrightness = current
        environment.settingsStore.saveDimRestore(DimRestore(brightness: Double(current), dimmedReadBack: nil))
        environment.screen.brightness = Self.dimmedBrightness
        let readBack = environment.screen.brightness
        dimmedReadBack = readBack
        environment.settingsStore.saveDimRestore(DimRestore(brightness: Double(current),
                                                            dimmedReadBack: Double(readBack)))
    }

    /// Puts back the remembered brightness (unless changed meanwhile) and forgets it. Does nothing if
    /// the brightness isn't lowered.
    private func restoreBrightness() {
        guard let saved = savedBrightness else { return }
        let readBack = dimmedReadBack
        savedBrightness = nil
        dimmedReadBack = nil
        Self.putBack(saved, ifStillAt: readBack, on: environment.screen)
        environment.settingsStore.saveDimRestore(nil)
    }

    /// Once per process, at the first foreground scene phase: a run that ended while dimmed (kill, crash)
    /// left its brightness in the store; put it back if the screen is still at the dimmed level, and
    /// clear it either way. Not in `init`: before a window scene exists the brightness can't be read or set.
    private func restoreBrightnessFromLastRun() {
        guard !checkedLastRunBrightness else { return }
        checkedLastRunBrightness = true
        guard let pending = environment.settingsStore.loadDimRestore() else { return }
        Self.putBack(CGFloat(pending.brightness), ifStillAt: pending.dimmedReadBack.map { CGFloat($0) },
                     on: environment.screen)
        environment.settingsStore.saveDimRestore(nil)
    }

    /// `saved` unless the screen is no longer at the dimmed level, i.e. what it read back once dimmed
    /// (`dimmedBrightness` if that isn't known): a level the user, auto-brightness or a lock since a kill
    /// set wins.
    private static func putBack(_ saved: CGFloat, ifStillAt dimmedLevel: CGFloat?, on screen: ScreenController) {
        guard abs(screen.brightness - (dimmedLevel ?? dimmedBrightness)) < 0.005 else { return }
        screen.brightness = saved
    }

    // MARK: Toast

    /// Shows a toast for 4 s and speaks it to VoiceOver (issue #11): every toast is an event the user
    /// caused or must know about (a save's result, why Save refused), so each is announced exactly once.
    func showToast(_ message: String, isError: Bool = false, isWarning: Bool = false) {
        let toast = Toast(message: message, isError: isError, isWarning: isWarning)
        self.toast = toast
        environment.announcer.announce(message, priority: isError ? .high : .normal)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.toast == toast else { return }
            self?.toast = nil
        }
    }

    // MARK: - Private

    /// Serialises every session mutation (start, stop, restart, recovery attempts): each piece of work
    /// starts after the previous one finished. Source events that arrive meanwhile are applied once
    /// the queue is empty, so they can't interleave with a half-done start or stop.
    private func schedulePipeline(_ work: @escaping @MainActor (AppModel) async -> Void) {
        let previous = pipelineTask
        pipelineDepth += 1
        pipelineTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
            self.pipelineDepth -= 1
            if self.pipelineDepth == 0, self.sourceEventsWhilePipelineBusy {
                self.sourceEventsWhilePipelineBusy = false
                self.applySourceState()
                self.refreshStatus()
            }
        }
    }

    /// True while `generation` is the newest intent and that intent is to capture (issue #15).
    private func isCurrent(_ generation: Int) -> Bool {
        generation == captureGeneration && automaticCaptureAllowed
    }

    /// Starts capture for `generation` (`start()`, or a reconfigure in `applyQuality`). After each
    /// `await` it checks the generation is still current: a pause, background or newer start while the
    /// camera starts (or a permission prompt is up) makes this start stale, and a stale start publishes
    /// no phase -- not `.recording`, not `.cameraDenied` -- and stops whatever it started.
    private func bringUp(_ generation: Int) async {
        if !didCleanUp {
            // Removes the old buffer, job folders and partial exports; finished clips are kept.
            orphansRemoved = environment.storage.removeOrphans()
            didCleanUp = true
            reloadUnsavedClips()
        }
        guard isCurrent(generation) else { return }
        phase = .starting
        // A fresh start supersedes any recovery and anything the previous session reported.
        endRecovery()
        frameWatchdog.disarm()
        sourceInterruption = nil
        let capture = captureConfiguration
        // The recorder ignores samples until it is configured for what the source really delivers.
        recorder.suspend()
        // Issue #10: room for the ring (the old one was just deleted) and the reserve, or don't start.
        let space = diskPolicy.beforeBuffering(availableBytes: readDiskSpace())
        guard space.level != .tooLow else {
            await stopCapture()
            guard isCurrent(generation) else { return }
            phase = .outOfSpace(space)
            refreshStatus()
            return
        }
        diskSpace = space
        do {
            let active = try await environment.source.start(capture)
            guard isCurrent(generation) else {
                // Superseded while the camera started: the newer intent owns the phase. Its own work
                // (a pause's or background's tear-down, a newer start) is queued behind this one.
                await stopCapture()
                refreshStatus()
                return
            }
            activeCapture = active
            appliedCapture = capture
            recorder.reconfigure(recorderConfiguration)
            environment.screen.setIdleTimerDisabled(true)
            // Recording, unless the source reported an interruption while it started.
            applySourceState()
            startStatusLoop()
            startVoiceIfNeeded()
            batteryDrain.reset(configuration: measuredConfiguration)
            requestPhotosAccessOnce()
        } catch {
            // A denial answered after a pause is not news: nothing is meant to run.
            if isCurrent(generation) { await startFailed(error) } else { await stopCapture() }
        }
        refreshStatus()
    }

    /// Capture didn't start (issue #8). Nothing runs and Save is disabled; `startFailureNotice` says
    /// why and offers the fix. Recovery is only ever a new `bringUp` through the pipeline: Try Again
    /// (`retryStart`) or the foreground re-check in `scenePhaseChanged(.active)`.
    private func startFailed(_ error: Error) async {
        await stopCapture()
        // A pause or stop while the source stopped owns the phase now (issue #15).
        guard automaticCaptureAllowed else { return }
        if let error = error as? FrameSourceError, error == .cameraAccessDenied {
            phase = .cameraDenied
        } else {
            phase = .failed(error.localizedDescription)
        }
    }

    /// What a failed start, a given-up recovery and an out-of-space stop share: no recovery, watchdog,
    /// voice or disk warning, the source stopped, the screen allowed to lock, no stale preview. The
    /// caller sets the phase that says why; the recorder is already suspended.
    private func stopCapture() async {
        endRecovery()
        frameWatchdog.disarm()
        recoveredStall = nil
        sourceInterruption = nil
        diskSpace = nil
        appliedCapture = nil
        activeCapture = nil
        stopVoice()
        // A failed reconfigure can leave a half-built session running.
        await environment.source.stop()
        environment.screen.setIdleTimerDisabled(false)
        previewImage = nil // no stale frame that looks live
    }

    private func tearDown(reason: InterruptionReason?) async {
        endRecovery()
        frameWatchdog.disarm()
        recoveredStall = nil
        diskSpace = nil
        sourceInterruption = nil
        stopVoice()
        await environment.source.stop()
        recorder.suspend()
        appliedCapture = nil
        activeCapture = nil
        environment.screen.setIdleTimerDisabled(false)
        if isUserPaused {
            phase = .userPaused // issue #15: also when the app is backgrounded while paused
        } else if wantsRunning {
            phase = .starting // a start queued behind this stop (reconfigure, Resume, back in the foreground)
        } else {
            phase = reason.map { .paused($0.message) } ?? .idle
        }
        refreshStatus()
    }

    // MARK: Source events and recovery (issue #4; DESIGN.md "Event ordering and recovery")
    //
    // * One ordered channel: every `FrameSourceEvent` goes through `captureEvents` and is handled here,
    //   in emission order. Nothing else feeds source state in; later features (frame watchdog #9,
    //   user pause #15) read or extend this, they don't add a second stream.
    // * One recovery entry point: `recoverCapture(_:)`. Callers: a runtime-error event, the status-loop
    //   safety net (`reconcileCapture()`), and the frame watchdog (#9, `checkFrameWatchdog()`).
    // * Every automatic path checks `automaticCaptureAllowed`, which is false while the user has paused
    //   (#15); work queued for an older capture generation checks `isCurrent(_:)` as well.

    /// Whether automatic paths (event handling, recovery, the safety net, the frame watchdog, the
    /// free-space check) may bring capture back: capture is wanted and the user hasn't paused (#15).
    private var automaticCaptureAllowed: Bool { wantsRunning && !isUserPaused }

    private func handle(_ event: FrameSourceEvent) {
        handledSourceEvents += 1
        // A failed start (or a recovery that gave up) stopped the source: what it still reports is
        // stale, and only `start()` leaves that phase. Keeps the failure notice and its Try Again.
        guard !phase.isStartFailure else { return }
        switch event {
        case .interrupted(let reason): sourceInterruption = reason
        case .interruptionEnded: sourceInterruption = nil
        }
        // Start, stop and recovery attempts own phase and recorder while they run; the last of them
        // applies what the source said when it finishes (`schedulePipeline`).
        guard pipelineDepth == 0 else {
            sourceEventsWhilePipelineBusy = true
            return
        }
        applySourceState()
        refreshStatus()
    }

    /// Makes phase and recorder follow what the source last reported (`sourceInterruption`). Only while
    /// capture is meant to run and has been brought up (recording, paused, or at the end of a start).
    private func applySourceState() {
        guard automaticCaptureAllowed else { return }
        switch phase {
        case .recording, .paused, .starting: break
        case .idle, .cameraDenied, .failed, .outOfSpace, .userPaused: return
        }
        switch sourceInterruption {
        case .runtimeError(let why)?:
            recoverCapture(.runtimeError(why))
        case let reason?:
            // iOS ends ordinary interruptions itself and says so; restarting meanwhile can't help.
            endRecovery()
            frameWatchdog.disarm()
            recorder.suspend()
            phase = .paused(reason.message)
        case nil:
            // A stale "running again" mid-recovery: wait for the restart (or the safety net) instead.
            // A stalled source (#9) says it runs all along, so only its restart ends that recovery.
            if let recovery, recovery.reason.isStall || environment.source.runState != .running { return }
            endRecovery()
            frameWatchdog.disarm() // re-armed on the next status tick, with a full timeout
            recorder.resume()
            phase = .recording
            startVoiceIfNeeded()
        }
    }

    /// **The recovery entry point** (issue #4). Suspends the recorder, says why in the phase, and — unless
    /// a recovery is already running, whose budget then continues — asks the source to run again
    /// (`FrameSource.resumeRunning()`) at once and then on the `RestartBackoff` schedule. It ends when
    /// the source runs again (recording resumes), when a start, stop or ordinary interruption supersedes
    /// it, or when the budget is spent: then capture stops and the phase becomes `.failed` with
    /// Try Again, like a failed start (#8). Ignored unless capture is meant to run and was brought up.
    func recoverCapture(_ reason: CaptureRecoveryReason) {
        guard automaticCaptureAllowed else { return }
        switch phase {
        case .recording, .paused, .starting: break
        case .idle, .cameraDenied, .failed, .outOfSpace, .userPaused: return
        }
        recorder.suspend()
        frameWatchdog.disarm()
        phase = .paused(reason.pausedMessage)
        guard recovery == nil else { return }
        recoveryCounter += 1
        // A frame stall gets `FrameWatchdog.automaticRestartsPerStall` restarts per episode; after that
        // the recovery starts with a spent budget, i.e. gives up at once through the usual path.
        let budget = reason.isStall && !frameWatchdog.mayRestartAutomatically ? RestartBackoff.spent : RestartBackoff()
        recovery = CaptureRecovery(id: recoveryCounter, reason: reason, generation: captureGeneration, backoff: budget)
        scheduleRecoveryAttempt()
    }

    private func endRecovery() {
        recovery = nil // pending timers and attempts see a different id and do nothing
    }

    /// True while recovery `id` is the one running, in the current generation, and capture may run.
    /// Every backoff timer and attempt checks this, before and after each `await` (issue #15).
    private func isCurrentRecovery(_ id: Int) -> Bool {
        guard let recovery, recovery.id == id else { return false }
        return isCurrent(recovery.generation)
    }

    /// Queues the next attempt on the pipeline after its backoff delay; gives up when the budget is spent.
    private func scheduleRecoveryAttempt() {
        guard var current = recovery else { return }
        let id = current.id
        guard let delay = current.backoff.nextDelay() else {
            schedulePipeline { model in await model.giveUpRecovery(id) }
            return
        }
        recovery = current
        if delay <= 0 {
            schedulePipeline { model in await model.attemptRecovery(id) }
        } else {
            environment.scheduler.schedule(after: delay) { [weak self] in
                guard let self, self.isCurrentRecovery(id) else { return }
                self.schedulePipeline { model in await model.attemptRecovery(id) }
            }
        }
    }

    /// One restart attempt for `reason`; true if the source runs afterwards. The per-reason seam: a
    /// frame stall (#9) needs more than `resumeRunning()` (a source that "runs" without delivering).
    private func restartSource(for reason: CaptureRecoveryReason) async -> Bool {
        switch reason {
        case .runtimeError, .sourceStopped:
            return await environment.source.resumeRunning()
        case .stalled:
            return await restartStalledSource()
        }
    }

    /// A stalled source still reports `.running`, so `resumeRunning()` would change nothing: stop it and
    /// start it again with the current configuration -- `tearDown` + `bringUp`, but keeping the recovery
    /// and the phase, which `attemptRecovery` owns. The recorder stays suspended until recording
    /// resumes (`applySourceState`), so nothing from the old session reaches the new buffer.
    private func restartStalledSource() async -> Bool {
        stopVoice()
        recorder.suspend()
        await environment.source.stop()
        let capture = captureConfiguration
        do {
            let active = try await environment.source.start(capture)
            activeCapture = active
            appliedCapture = capture
            recorder.reconfigure(recorderConfiguration)
            return environment.source.runState == .running
        } catch {
            // Not running; the backoff tries again, then gives up with Try Again.
            appliedCapture = nil
            activeCapture = nil
            return false
        }
    }

    private func attemptRecovery(_ id: Int) async {
        guard isCurrentRecovery(id), let current = recovery else { return }
        let running = await restartSource(for: current.reason)
        // A pause, stop, new start or ordinary interruption may have superseded this recovery meanwhile.
        // Then what the restart started is left to the tear-down or start queued behind this attempt.
        guard isCurrentRecovery(id) else { return }
        if running {
            // Its `.interruptionEnded` is in the channel too; applying it here as well means the
            // outcome doesn't depend on which of the two is handled first.
            if case .stalled(let stall) = current.reason {
                recoveredStall = RecoveredStall(stall: stall, restartedAt: environment.clock.now())
            }
            endRecovery()
            sourceInterruption = nil
            applySourceState()
            refreshStatus()
        } else {
            scheduleRecoveryAttempt()
        }
    }

    /// Restarts didn't bring capture back: stop it and say so truthfully, with Try Again (issue #8's
    /// `.failed` notice). Wakes the screen from Dim so the notice can be seen.
    private func giveUpRecovery(_ id: Int) async {
        guard isCurrentRecovery(id), let current = recovery else { return }
        setDimmed(false)
        environment.haptics.failure()
        recorder.suspend()
        await startFailed(FrameSourceError.restartFailed(current.reason.failureDetail))
        refreshStatus()
    }

    /// **Safety net** (issue #4), run on every status-loop tick: repairs phase and recorder when they
    /// disagree with what the source is actually doing, in case an event was missed or never sent.
    /// * running, but the recorder is suspended or the phase paused → resume recording;
    /// * interrupted, but the phase says recording → pause;
    /// * stopped (not interrupted) while recording or paused, with no recovery running →
    ///   `recoverCapture(.sourceStopped)`.
    /// Does nothing while pipeline work runs or capture isn't meant to run.
    func reconcileCapture() {
        guard automaticCaptureAllowed, pipelineDepth == 0 else { return }
        switch (environment.source.runState, phase) {
        case (.running, .recording):
            guard recorder.status().isSuspended else { return }
            sourceInterruption = nil
            endRecovery()
            applySourceState()
        case (.running, .paused):
            // A stalled source (#9) "runs" without delivering: only its restart ends that recovery.
            if recovery?.reason.isStall == true { return }
            sourceInterruption = nil
            endRecovery()
            applySourceState()
        case (.interrupted, .recording):
            sourceInterruption = sourceInterruption ?? .other("the camera was interrupted")
            applySourceState()
        case (.stopped, .recording), (.stopped, .paused):
            guard recovery == nil else { return }
            recoverCapture(.sourceStopped)
        default:
            return
        }
        refreshStatus()
    }

    static let statusInterval: TimeInterval = 0.5

    /// Runs `statusTick()` every `statusInterval` from the first successful start, on
    /// `environment.scheduler` (tests advance it by hand).
    private func startStatusLoop() {
        guard !statusLoopRunning else { return }
        statusLoopRunning = true
        scheduleStatusTick()
    }

    private func scheduleStatusTick() {
        environment.scheduler.schedule(after: Self.statusInterval) { [weak self] in
            guard let self else { return }
            self.statusTick()
            self.scheduleStatusTick()
        }
    }

    /// One status-loop tick: refresh what the UI shows, then the safety net, then the frame watchdog,
    /// then (every `DiskSpacePolicy.checkInterval`) the free-space check.
    func statusTick() {
        refreshStatus()
        reconcileCapture()
        checkFrameWatchdog()
        checkDiskSpace()
    }

    /// Reads free space through `environment.diskCapacity`, net of what a running save has reserved
    /// (issue #14, `TemporarySpace`); the periodic check's interval restarts.
    private func readDiskSpace() -> Int64? {
        lastDiskCheck = environment.monotonicClock.seconds
        let available = temporarySpace.unreservedBytes()
        availableDiskBytes = available
        return available
    }

    /// **Free-space check** (issue #10), on the status loop after the frame watchdog, at most every
    /// `DiskSpacePolicy.checkInterval` (5 s; the 0.5 s tick is needlessly often for a volume query), and
    /// only while recording with no pipeline work. Below the reserve, capture stops cleanly
    /// (`stopForLowDisk`) before segment writes can fail; between the reserve and room for buffer + save,
    /// `diskSpaceNotice` warns. Unknown free space counts as enough.
    ///
    /// Issue #14: on every tick (not only every 5 s), a recorder that stopped itself (`RecorderHalt`: fragment
    /// backlog over its bound, or a segment write failed) stops capture here too, before the frame
    /// watchdog could take the missing frames for a stall and restart into the same shortage.
    private func checkDiskSpace() {
        guard automaticCaptureAllowed, phase == .recording, pipelineDepth == 0 else { return }
        if let halt = recorder.status().halt {
            let check = diskPolicy.whileRecording(availableBytes: readDiskSpace(), ringBytes: 0)
            schedulePipeline { model in await model.stopForRecorderHalt(halt, check: check) }
            return
        }
        if let last = lastDiskCheck,
           environment.monotonicClock.seconds - last < DiskSpacePolicy.checkInterval - 1e-6 { return }
        let available = readDiskSpace()
        let check = diskPolicy.whileRecording(availableBytes: available, ringBytes: recorder.status().bytes)
        guard check.level == .tooLow else {
            diskSpace = check
            return
        }
        schedulePipeline { model in await model.stopForLowDisk(check) }
    }

    /// Stops capture because free space ran out (issue #10). The recorder is suspended first: its ring is
    /// deleted, and a save waiting for its post-roll is settled with what is there (a running export
    /// carries on). Then the camera stops, the screen wakes from Dim and the out-of-space notice says
    /// why. Capture stays stopped until Try Again, the foreground re-check or a settings change finds
    /// room. Finished clips in `UnsavedClips/` are never touched.
    private func stopForLowDisk(_ check: DiskSpaceCheck) async {
        await stopForResources(.outOfSpace(check))
    }

    /// The recorder halted (issue #14): if free space is below the reserve, this is #10's out-of-space
    /// stop; otherwise "Not recording" with the halt's reason and Try Again. Either way nothing restarts
    /// on its own, so the same shortage can't loop; a pending save was already settled by the recorder.
    private func stopForRecorderHalt(_ halt: RecorderHalt, check: DiskSpaceCheck) async {
        await stopForResources(check.level == .tooLow ? .outOfSpace(check) : .failed(halt.message))
    }

    /// Shared by the resource stops: suspend the recorder (ring deleted, a pending post-roll settled with
    /// what is there; a running export carries on), stop the camera, wake from Dim, set `phase`.
    private func stopForResources(_ stoppedPhase: Phase) async {
        guard automaticCaptureAllowed else { return }
        switch phase {
        case .recording, .paused, .starting: break
        case .idle, .cameraDenied, .failed, .outOfSpace, .userPaused: return
        }
        recorder.suspend()
        setDimmed(false)
        environment.haptics.failure()
        await stopCapture()
        guard automaticCaptureAllowed else { return } // paused or stopped meanwhile (#15)
        phase = stoppedPhase
        refreshStatus()
    }

    /// **Frame watchdog** (issue #9), run on every status tick after the safety net. While capture is
    /// meant to run and the app records -- source running, recorder taking samples, no recovery or
    /// pipeline work -- `FrameWatchdog` checks that new video frames and segments keep arriving, timed
    /// on `environment.monotonicClock`. Anything else disarms it, and the first tick after re-arms it,
    /// so a start, restart, interruption or reconfiguration always gets the full timeout.
    ///
    /// On a stall: a save waiting for its post-roll is settled at once with the footage already
    /// buffered (or an actionable error), since that post-roll will never arrive; then
    /// `recoverCapture(.stalled)` says so in the phase and restarts the source, once per stall
    /// episode. If the restarted source stalls again, the recovery gives up into "Not recording"
    /// with Try Again and wakes the screen (`giveUpRecovery`).
    private func checkFrameWatchdog() {
        let current = recorder.status()
        guard automaticCaptureAllowed, phase == .recording, recovery == nil, pipelineDepth == 0,
              environment.source.runState == .running, !current.isSuspended else {
            frameWatchdog.disarm()
            return
        }
        let now = environment.monotonicClock.seconds
        guard frameWatchdog.isArmed else {
            frameWatchdog.arm(at: now, status: current)
            return
        }
        guard let stall = frameWatchdog.observe(current, at: now) else { return }
        recorder.settlePendingSave()
        recoverCapture(.stalled(stall))
        refreshStatus()
    }

    func refreshStatus() {
        status = recorder.status()
        // The footage lost in a stall restart (#9) no longer matters once the buffer is full again.
        if recoveredStall != nil, readySeconds >= settings.bufferSeconds { recoveredStall = nil }
        batteryLevel = environment.battery.level
        isCharging = environment.battery.isCharging
        if let fake = environment.fakeLibrary {
            fakeLibraryCount = fake.clips().count
        }
        if phase == .recording {
            batteryDrain.record(level: batteryLevel, isCharging: isCharging, at: environment.clock.now())
        }
        announceChanges()
    }

    // MARK: VoiceOver announcements (issue #11; DESIGN.md "Accessibility")

    /// Tells VoiceOver what changed since the last call, in one announcement: the phase (recording,
    /// paused, resumed, stopped, failed), a thermal step-down or recovery, and warnings that appeared
    /// (frame-stall restart, low storage, microphone). Runs at the end of every `refreshStatus()`, which
    /// every phase change reaches, and compares with what was last announced, so an unchanged state on
    /// the 0.5 s status tick says nothing. `.starting` is not announced: it lasts a moment, and the
    /// phase it ends in is. Toasts (save results) are announced by `showToast`.
    private func announceChanges() {
        var parts: [String] = []
        var priority = AnnouncementPriority.normal
        if phase == .starting {
            // Try Again after a failure: if this start fails the same way, that is news again.
            if announcedPhase.isStartFailure { announcedPhase = .starting }
        } else if phase != announcedPhase {
            let previous = announcedPhase
            announcedPhase = phase
            if let text = Self.phaseAnnouncement(phase, after: previous) {
                parts.append(text)
                if phase.isStartFailure { priority = .high }
            }
        }
        if thermalMessage != announcedThermalMessage {
            let hadMessage = announcedThermalMessage != nil
            announcedThermalMessage = thermalMessage
            if let thermalMessage {
                parts.append(thermalMessage)
            } else if hadMessage {
                parts.append("The phone has cooled down. Quality is back to \(activePreset).")
            }
        }
        // Each warning once while it is shown; it is news again only after it went away.
        let notices = [stallNotice, diskSpaceNotice, microphoneNotice].compactMap { $0 }
        announcedNoticeIDs.formIntersection(notices.map(\.id))
        for notice in notices where !announcedNoticeIDs.contains(notice.id) {
            announcedNoticeIDs.insert(notice.id)
            parts.append(notice.announcement)
        }
        guard !parts.isEmpty else { return }
        environment.announcer.announce(parts.joined(separator: " "), priority: priority)
    }

    /// What VoiceOver says when the phase becomes `phase` (nil: nothing worth saying).
    static func phaseAnnouncement(_ phase: Phase, after previous: Phase) -> String? {
        switch phase {
        case .starting:
            return nil
        case .idle:
            return previous == .recording ? "Recording stopped." : nil
        case .recording:
            switch previous {
            case .paused, .userPaused: return "Recording resumed."
            default: return "Recording."
            }
        case .paused(let why):
            return why // "Paused — another app is using the camera.", "Camera error: … Restarting…"
        case .userPaused:
            return "Paused. The camera is off until you tap Resume."
        case .cameraDenied:
            return "Not recording: camera access is off."
        case .failed(let why):
            return "Not recording. \(why)"
        case .outOfSpace:
            return "Not recording: not enough free space."
        }
    }

    // MARK: Voice trigger

    private func startVoiceIfNeeded() {
        guard settings.voiceTriggerEnabled, phase == .recording, automaticCaptureAllowed, !isVoiceListening,
              let voice = environment.voice else { return }
        guard voice.isAvailable else {
            showToast("Voice trigger needs on-device speech recognition, which this iPhone doesn't support.", isError: true)
            return
        }
        // Without captured audio there is nothing to listen to. `microphoneNotice` and the Settings row
        // say why; a capture restart that is already queued (voice just turned on) calls this again.
        guard activeCapture?.audioCaptured == true else { return }
        isVoiceListening = true
        voiceRecognitionFailed = false
        voiceSession += 1
        let session = voiceSession
        Task {
            let authorized = await voice.requestAuthorization()
            // Stopped meanwhile: every stop, including a user pause (#15), bumps `voiceSession`.
            guard session == voiceSession, isVoiceListening else { return }
            guard authorized else {
                isVoiceListening = false
                showToast("Allow Speech Recognition in Settings to use the voice trigger.", isError: true)
                return
            }
            fanOut.setTap(voice)
            voice.start(onTrigger: { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.save(trigger: .voice) }
            }, onGiveUp: { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.voiceGaveUp(session) }
            })
            batteryDrain.reset(configuration: measuredConfiguration)
        }
    }

    /// The trigger gave up after its restart budget (issue #36; DESIGN.md §6): recognition sessions kept
    /// failing. Listening is off and says why in Settings; one toast tells the user (and VoiceOver) once.
    /// Recording and Save are unaffected. The next start (recording starts or resumes, or the trigger
    /// is turned off and on) tries again with a fresh budget.
    private func voiceGaveUp(_ session: Int) {
        // A stop, pause or newer start since then owns the state (every one bumps `voiceSession`).
        guard session == voiceSession, isVoiceListening else { return }
        stopVoice()
        voiceRecognitionFailed = true
        showToast("The voice trigger stopped: \(Self.speechRecognitionUnavailable).", isError: true)
    }

    private func stopVoice() {
        guard isVoiceListening else { return }
        isVoiceListening = false
        voiceSession += 1
        fanOut.setTap(nil)
        environment.voice?.stop()
        batteryDrain.reset(configuration: measuredConfiguration)
    }
}
