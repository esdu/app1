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
        case failed(String)
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

    let environment: AppEnvironment
    let recorder: RollingRecorder
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var savedBrightness: CGFloat?
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var didCleanUp = false
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
            configuration: RollingRecorder.Configuration(bufferSeconds: loaded.bufferSeconds, preset: effective,
                                                         audioEnabled: loaded.audioEnabled,
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

    /// The voice trigger needs the microphone even when sound isn't recorded into clips.
    var captureConfiguration: CaptureConfiguration {
        CaptureConfiguration(preset: activePreset,
                             audioEnabled: settings.audioEnabled || (settings.voiceTriggerEnabled && isVoiceAvailable),
                             camera: settings.camera)
    }

    private var measuredConfiguration: String {
        "\(activePreset), voice \(isVoiceListening ? "on" : "off")"
    }

    var recorderConfiguration: RollingRecorder.Configuration {
        RollingRecorder.Configuration(bufferSeconds: settings.bufferSeconds, preset: activePreset,
                                      audioEnabled: settings.audioEnabled, realTime: environment.realTime)
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
            if !wantsRunning { start() }
        case .background:
            setDimmed(false)
            stop(reason: .backgrounded)
        default:
            break // .inactive (Control Center, alerts): capture keeps running.
        }
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

    @discardableResult
    func save(trigger: SaveTrigger = .button) -> Task<Void, Never>? {
        guard !isSaving else {
            showToast("Already saving — hold on…")
            return nil
        }
        let postRoll = Double(settings.postRollSeconds)
        let ticket = recorder.beginSave(postRoll: postRoll)
        isSaving = true
        if trigger == .voice { environment.haptics.success() }
        if postRoll > 0, !ticket.isFulfilled {
            showToast("Saving… recording \(settings.postRollSeconds) s more")
        }
        let library = environment.photoLibrary
        return Task {
            do {
                let bundle = try await ticket.bundle()
                defer { bundle.discard() }
                let clip = try await ClipExporter.export(bundle)
                try await library.saveVideo(at: clip.url)
                savedClipCount += 1
                environment.haptics.success()
                showToast("Saved \(Int(clip.duration.rounded())) s clip to Photos")
            } catch {
                environment.haptics.failure()
                showToast(error.localizedDescription, isError: true)
            }
            isSaving = false
            refreshStatus()
        }
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
            orphansRemoved = environment.storage.removeOrphans()
            didCleanUp = true
        }
        guard wantsRunning else { return }
        phase = .starting
        let capture = captureConfiguration
        recorder.reconfigure(recorderConfiguration)
        recorder.resume()
        do {
            try await environment.source.start(capture)
            appliedCapture = capture
            phase = .recording
            environment.screen.setIdleTimerDisabled(true)
            startStatusLoop()
            startVoiceIfNeeded()
            batteryDrain.reset(configuration: measuredConfiguration)
        } catch {
            appliedCapture = nil
            phase = .failed(error.localizedDescription)
        }
        refreshStatus()
    }

    private func tearDown(reason: InterruptionReason?) async {
        stopVoice()
        await environment.source.stop()
        recorder.suspend()
        appliedCapture = nil
        environment.screen.setIdleTimerDisabled(false)
        phase = reason.map { .paused($0.message) } ?? .idle
        refreshStatus()
    }

    private func handle(_ event: FrameSourceEvent) {
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
