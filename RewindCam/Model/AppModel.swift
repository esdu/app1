import AVFoundation
import Observation
import SwiftUI

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
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

        /// The last start attempt failed; nothing is captured until a start succeeds.
        var isStartFailure: Bool {
            switch self {
            case .cameraDenied, .failed: true
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
        var backoff = RestartBackoff()
    }

    let environment: AppEnvironment
    let recorder: RollingRecorder
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
    /// The ordered source-event channel (issue #4); see `handle(_:)`.
    private let captureEvents: AsyncStream<CaptureChannelItem>.Continuation
    /// Source events handled so far (tests compare it with how many were emitted).
    @ObservationIgnored private(set) var handledSourceEvents = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var savedBrightness: CGFloat?
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var didCleanUp = false
    @ObservationIgnored private var didRequestPhotosAccess = false
    /// Kept clips a save is still handing to Photos; hidden from `unsavedClips` so Retry can't race it.
    @ObservationIgnored private var clipsInFlight: Set<String> = [] // file names
    @ObservationIgnored private var appliedCapture: CaptureConfiguration?
    /// Source → recorder, plus an optional tap for the voice trigger.
    private let fanOut: SampleFanOut
    /// Bumped on every voice start/stop so a stale authorization callback can't start a second session.
    @ObservationIgnored private var voiceSession = 0

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
        recorder = RollingRecorder(
            bufferDirectory: environment.storage.bufferDirectory,
            clipsDirectory: environment.storage.clipsDirectory,
            // No audio until a started source says it delivers some (`bringUp`).
            configuration: RollingRecorder.Configuration(bufferSeconds: loaded.bufferSeconds, preset: effective,
                                                         audioEnabled: false,
                                                         realTime: environment.realTime))

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
                         severity: .warning, action: nil)
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
        }
    }

    /// The "Listening" row in Settings.
    var voiceListeningLabel: String {
        if isVoiceListening { return "Yes" }
        guard wantsVoiceTrigger, let reason = microphoneProblem else { return "No" }
        return reason == .microphoneDenied ? "No — microphone access is denied" : "No — microphone unavailable"
    }

    // MARK: Lifecycle

    func start() {
        wantsRunning = true
        // Launch, foreground or Try Again: a fresh session, with a fresh stall budget (issue #9).
        frameWatchdog.forgetStalls()
        recoveredStall = nil
        schedulePipeline { model in await model.bringUp() }
    }

    func stop(reason: InterruptionReason? = nil) {
        wantsRunning = false
        schedulePipeline { model in await model.tearDown(reason: reason) }
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
            // Not running (launch, back from the background), or the last start failed: start again.
            // The failed case is how "allowed the camera in Settings and came back" recovers when iOS
            // doesn't background the app in between (e.g. a permission prompt was just answered).
            if !wantsRunning || self.phase.isStartFailure { start() }
        case .background:
            setDimmed(false)
            stop(reason: .backgrounded)
        default:
            break // .inactive (Control Center, alerts): capture keeps running.
        }
    }

    /// "Try Again" (`AppNotice.Action.tryAgain`) after a start failure. Goes through `start()`, the
    /// same pipeline as launch and foreground; ignored unless the last start failed, so a double tap
    /// queues only one attempt.
    func retryStart() {
        guard phase.isStartFailure else { return }
        phase = .starting
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
            if new.voiceTriggerEnabled { startVoiceIfNeeded() } else { stopVoice() }
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
        let capture = captureConfiguration
        if wantsRunning, let applied = appliedCapture, applied != capture {
            schedulePipeline { model in
                await model.tearDown(reason: nil)
                await model.bringUp()
            }
        } else {
            // Buffer length changes apply in place without losing footage.
            recorder.reconfigure(recorderConfiguration)
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
        let postRoll = Double(settings.postRollSeconds)
        let ticket = recorder.beginSave(postRoll: postRoll)
        isSaving = true
        let background = environment.backgroundTasks.begin(name: "Save clip")
        if trigger == .voice { environment.haptics.success() }
        if postRoll > 0, !ticket.isFulfilled {
            showToast("Saving… recording \(settings.postRollSeconds) s more")
        }
        return Task {
            await exportAndAddToPhotos(ticket)
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

    private func exportAndAddToPhotos(_ ticket: SaveTicket) async {
        let exported: (clip: UnsavedClip, duration: Double, endedEarly: Bool)
        do {
            exported = try await exportDurably(ticket)
        } catch {
            // Includes a post-roll settled with nothing buffered because video stopped (#9):
            // `RecorderError.videoStopped` says to save again once recording is back.
            environment.haptics.failure()
            showToast(error.localizedDescription, isError: true)
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
            // Recording stopped (interruption, or video stopped arriving, #9) before the clip's end.
            showToast(exported.endedEarly
                ? "Saved \(seconds) s clip to Photos. It ends early: recording stopped before the end you asked for."
                : "Saved \(seconds) s clip to Photos")
        } catch {
            photosFailed(error)
        }
    }

    /// Waits for the segments, exports to `<name>.partial.mov` in the unsaved-clips folder and renames
    /// it to `.mov` only once the export is complete. The job folder in Caches is always discarded.
    private func exportDurably(_ ticket: SaveTicket) async throws
        -> (clip: UnsavedClip, duration: Double, endedEarly: Bool) {
        let storage = environment.storage
        let bundle = try await ticket.bundle()
        defer { bundle.discard() }
        let partial = try storage.partialClipURL(baseName: ClipExporter.defaultBaseName())
        do {
            let output = try await ClipExporter.export(bundle, to: partial)
            let clip = try storage.commitPartialClip(output.url)
            // Settled early (`RollingRecorder.resolveEarly` / `settlePendingSave`): footage stops short.
            let endedEarly = bundle.clipEnd < bundle.requestedEnd - 0.5
            return (clip, output.duration, endedEarly)
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
        let staged = try storage.stageForPhotos(clip)
        defer { storage.discardStaging(staged) }
        try await library.saveVideo(at: staged)
        storage.removeUnsavedClip(clip)
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

    func setDimmed(_ dimmed: Bool) {
        guard dimmed != isDimmed else { return }
        isDimmed = dimmed
        if dimmed {
            savedBrightness = environment.screen.brightness
            environment.screen.brightness = 0.02
        } else {
            environment.screen.brightness = savedBrightness ?? 0.6
            savedBrightness = nil
        }
    }

    // MARK: Toast

    func showToast(_ message: String, isError: Bool = false) {
        let toast = Toast(message: message, isError: isError)
        self.toast = toast
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

    private func bringUp() async {
        if !didCleanUp {
            // Removes the old buffer, job folders and partial exports; finished clips are kept.
            orphansRemoved = environment.storage.removeOrphans()
            didCleanUp = true
            reloadUnsavedClips()
        }
        guard wantsRunning else { return }
        phase = .starting
        // A fresh start supersedes any recovery and anything the previous session reported.
        endRecovery()
        frameWatchdog.disarm()
        sourceInterruption = nil
        let capture = captureConfiguration
        // The recorder ignores samples until it is configured for what the source really delivers.
        recorder.suspend()
        do {
            let active = try await environment.source.start(capture)
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
            await startFailed(error)
        }
        refreshStatus()
    }

    /// Capture didn't start (issue #8). Nothing runs and Save is disabled; `startFailureNotice` says
    /// why and offers the fix. Recovery is only ever a new `bringUp` through the pipeline: Try Again
    /// (`retryStart`) or the foreground re-check in `scenePhaseChanged(.active)`.
    private func startFailed(_ error: Error) async {
        endRecovery()
        frameWatchdog.disarm()
        recoveredStall = nil
        sourceInterruption = nil
        appliedCapture = nil
        activeCapture = nil
        stopVoice()
        // A failed reconfigure can leave a half-built session running; the recorder is already suspended.
        await environment.source.stop()
        environment.screen.setIdleTimerDisabled(false)
        previewImage = nil // no stale frame that looks live
        if let error = error as? FrameSourceError, error == .cameraAccessDenied {
            phase = .cameraDenied
        } else {
            phase = .failed(error.localizedDescription)
        }
    }

    private func tearDown(reason: InterruptionReason?) async {
        endRecovery()
        frameWatchdog.disarm()
        recoveredStall = nil
        sourceInterruption = nil
        stopVoice()
        await environment.source.stop()
        recorder.suspend()
        appliedCapture = nil
        activeCapture = nil
        environment.screen.setIdleTimerDisabled(false)
        phase = reason.map { .paused($0.message) } ?? .idle
        refreshStatus()
    }

    // MARK: Source events and recovery (issue #4; DESIGN.md "Event ordering and recovery")
    //
    // * One ordered channel: every `FrameSourceEvent` goes through `captureEvents` and is handled here,
    //   in emission order. Nothing else feeds source state in; later features (frame watchdog #9,
    //   user pause #15) read or extend this, they don't add a second stream.
    // * One recovery entry point: `recoverCapture(_:)`. Callers: a runtime-error event, the status-loop
    //   safety net (`reconcileCapture()`), and the frame watchdog (#9, `checkFrameWatchdog()`).
    // * Every automatic path checks `automaticCaptureAllowed`; #15's explicit pause belongs there.

    /// Whether automatic paths (event handling, recovery, the safety net) may bring capture back.
    private var automaticCaptureAllowed: Bool { wantsRunning }

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
        case .idle, .cameraDenied, .failed: return
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
        case .idle, .cameraDenied, .failed: return
        }
        recorder.suspend()
        frameWatchdog.disarm()
        phase = .paused(reason.pausedMessage)
        guard recovery == nil else { return }
        recoveryCounter += 1
        // A frame stall gets `FrameWatchdog.automaticRestartsPerStall` restarts per episode; after that
        // the recovery starts with a spent budget, i.e. gives up at once through the usual path.
        let budget = reason.isStall && !frameWatchdog.mayRestartAutomatically ? RestartBackoff.spent : RestartBackoff()
        recovery = CaptureRecovery(id: recoveryCounter, reason: reason, backoff: budget)
        scheduleRecoveryAttempt()
    }

    private func endRecovery() {
        recovery = nil // pending timers and attempts see a different id and do nothing
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
                guard let self, self.recovery?.id == id else { return }
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
        guard let current = recovery, current.id == id, automaticCaptureAllowed else { return }
        let running = await restartSource(for: current.reason)
        // A stop, a new start or an ordinary interruption may have superseded this recovery meanwhile.
        guard recovery?.id == id, automaticCaptureAllowed else { return }
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
        guard let current = recovery, current.id == id, automaticCaptureAllowed else { return }
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

    /// One status-loop tick: refresh what the UI shows, then the safety net, then the frame watchdog.
    func statusTick() {
        refreshStatus()
        reconcileCapture()
        checkFrameWatchdog()
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
    }

    // MARK: Voice trigger

    private func startVoiceIfNeeded() {
        guard settings.voiceTriggerEnabled, phase == .recording, !isVoiceListening,
              let voice = environment.voice else { return }
        guard voice.isAvailable else {
            showToast("Voice trigger needs on-device speech recognition, which this iPhone doesn't support.", isError: true)
            return
        }
        // Without captured audio there is nothing to listen to. `microphoneNotice` and the Settings row
        // say why; a capture restart that is already queued (voice just turned on) calls this again.
        guard activeCapture?.audioCaptured == true else { return }
        isVoiceListening = true
        voiceSession += 1
        let session = voiceSession
        Task {
            let authorized = await voice.requestAuthorization()
            guard session == voiceSession, isVoiceListening else { return }
            guard authorized else {
                isVoiceListening = false
                showToast("Allow Speech Recognition in Settings to use the voice trigger.", isError: true)
                return
            }
            fanOut.setTap(voice)
            voice.start { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.save(trigger: .voice) }
            }
            batteryDrain.reset(configuration: measuredConfiguration)
        }
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
