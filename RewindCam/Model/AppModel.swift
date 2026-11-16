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

    let environment: AppEnvironment
    let recorder: RollingRecorder
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
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
        environment.thermal.onChange = { [weak self] level in self?.thermalChanged(level) }
        environment.source.setSink(fanOut)
        environment.source.setEventHandler { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }
        if let synthetic = environment.source as? SyntheticFrameSource {
            synthetic.setPreviewHandler { [weak self] image in
                guard let self else { return }
                Task { @MainActor in self.previewImage = image }
            }
        }
        refreshStatus()
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
        let exported: (clip: UnsavedClip, duration: Double)
        do {
            exported = try await exportDurably(ticket)
        } catch {
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
            showToast("Saved \(Int(exported.duration.rounded())) s clip to Photos")
        } catch {
            photosFailed(error)
        }
    }

    /// Waits for the segments, exports to `<name>.partial.mov` in the unsaved-clips folder and renames
    /// it to `.mov` only once the export is complete. The job folder in Caches is always discarded.
    private func exportDurably(_ ticket: SaveTicket) async throws -> (clip: UnsavedClip, duration: Double) {
        let storage = environment.storage
        let bundle = try await ticket.bundle()
        defer { bundle.discard() }
        let partial = try storage.partialClipURL(baseName: ClipExporter.defaultBaseName())
        do {
            let output = try await ClipExporter.export(bundle, to: partial)
            let clip = try storage.commitPartialClip(output.url)
            return (clip, output.duration)
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

    private func schedulePipeline(_ work: @escaping @MainActor (AppModel) async -> Void) {
        let previous = pipelineTask
        pipelineTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
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
        let capture = captureConfiguration
        // The recorder ignores samples until it is configured for what the source really delivers.
        recorder.suspend()
        do {
            let active = try await environment.source.start(capture)
            activeCapture = active
            appliedCapture = capture
            recorder.reconfigure(recorderConfiguration)
            recorder.resume()
            phase = .recording
            environment.screen.setIdleTimerDisabled(true)
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
        stopVoice()
        await environment.source.stop()
        recorder.suspend()
        appliedCapture = nil
        activeCapture = nil
        environment.screen.setIdleTimerDisabled(false)
        phase = reason.map { .paused($0.message) } ?? .idle
        refreshStatus()
    }

    private func handle(_ event: FrameSourceEvent) {
        // A source that failed to start has nothing to pause or resume; keep the failure notice.
        guard !phase.isStartFailure else { return }
        switch event {
        case .interrupted(let reason):
            recorder.suspend()
            phase = .paused(reason.message)
        case .interruptionEnded:
            guard wantsRunning else { return }
            recorder.resume()
            phase = .recording
        }
        refreshStatus()
    }

    private func startStatusLoop() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshStatus()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func refreshStatus() {
        status = recorder.status()
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
