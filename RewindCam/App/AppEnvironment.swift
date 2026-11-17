import Foundation

/// Every side-effecting dependency of the app, so tests and `-UITestMode` can swap them.
@MainActor
struct AppEnvironment {
    var isUITest: Bool
    var source: FrameSource
    var photoLibrary: PhotoLibrary
    var storage: BufferStorage
    var settingsStore: SettingsStore
    var thermal: ThermalMonitor
    var battery: BatteryMonitor
    var screen: ScreenController
    var haptics: Haptics
    /// Real-time encoding (drop frames when the encoder is busy). Tests use `false`.
    var realTime: Bool
    /// Only in `-UITestMode`: lets the UI show how many clips the fake library holds.
    var fakeLibrary: FakePhotoLibrary?
    /// Only set when the volume-button capture interaction can work (real camera).
    var supportsCaptureButtons: Bool
    /// Keeps a save (export + Photos) running when the user locks the phone or leaves the app.
    var backgroundTasks: BackgroundTasks
    /// "Open Settings" buttons (microphone notice, camera denied). Opens the real Settings app in
    /// `-UITestMode` too, so a UI test can see it come forward.
    var appSettings: AppSettingsOpener
    /// The model's timers: the status loop and capture-recovery backoff (issue #4). Tests: `FakeDelayScheduler`.
    var scheduler: DelayScheduler
    /// On-device "save that" recogniser (nil where unsupported, e.g. UI tests).
    var voice: VoiceTrigger? = nil
    var clock: WallClock = SystemWallClock()
    /// Interval timing for the frame watchdog (issue #9). Tests pass their `FakeDelayScheduler`.
    var monotonicClock: MonotonicClock = HostMonotonicClock()

    static let uiTestArgument = "-UITestMode"
    /// With `-UITestMode`: the fake Photos library fails the first save, so the UI test can retry it.
    static let uiTestPhotosFailOnceArgument = "-UITestPhotosFailOnce"
    /// With `-UITestMode`: the synthetic source acts as if microphone access were denied.
    static let uiTestDenyMicrophoneArgument = "-UITestDenyMicrophone"
    /// With `-UITestMode`: the synthetic source acts as if camera access were denied, until the user
    /// taps Open Settings (as if they allowed it there), so a UI test can walk the whole way back.
    static let uiTestDenyCameraArgument = "-UITestDenyCamera"
    /// With `-UITestMode`: the synthetic source fails every start with "no camera" (Try Again path).
    static let uiTestNoCameraArgument = "-UITestNoCamera"

    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        arguments.contains(uiTestArgument) ? uiTest(arguments: arguments) : live()
    }

    static func live() -> AppEnvironment {
        AppEnvironment(
            isUITest: false,
            source: CameraFrameSource(),
            photoLibrary: SystemPhotoLibrary(),
            storage: FileBufferStorage.standard,
            settingsStore: UserDefaultsSettingsStore(),
            thermal: SystemThermalMonitor(),
            battery: SystemBatteryMonitor(),
            screen: SystemScreenController(),
            haptics: SystemHaptics(),
            realTime: true,
            fakeLibrary: nil,
            supportsCaptureButtons: true,
            backgroundTasks: SystemBackgroundTasks(),
            appSettings: SystemAppSettingsOpener(),
            scheduler: SystemDelayScheduler(),
            voice: SpeechVoiceTrigger()
        )
    }

    /// Synthetic camera, fake Photos in Documents, fresh settings and no unsaved clips on every launch.
    static func uiTest(arguments: [String] = []) -> AppEnvironment {
        let suite = "RewindCam.UITest"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let fake = FakePhotoLibrary.documents
        fake.removeAll()
        if arguments.contains(uiTestPhotosFailOnceArgument) {
            fake.failNextSaves(["Simulated Photos failure (UI test)."])
        }
        let storage = FileBufferStorage.standard
        try? FileManager.default.removeItem(at: storage.unsavedDirectory)
        let source = SyntheticFrameSource(format: .uiTest, mode: .realTime, followsConfiguration: true)
        if arguments.contains(uiTestDenyMicrophoneArgument) {
            source.setAudioUnavailable(.microphoneDenied)
        }
        let denyCamera = arguments.contains(uiTestDenyCameraArgument)
        if denyCamera {
            source.setStartError(.cameraAccessDenied)
        } else if arguments.contains(uiTestNoCameraArgument) {
            source.setStartError(.noCamera)
        }
        let appSettings = UITestAppSettingsOpener { [source] in
            if denyCamera { source.setStartError(nil) }
        }
        return AppEnvironment(
            isUITest: true,
            source: source,
            photoLibrary: fake,
            storage: storage,
            settingsStore: UserDefaultsSettingsStore(defaults: defaults),
            thermal: SystemThermalMonitor(),
            battery: SystemBatteryMonitor(),
            screen: SystemScreenController(),
            haptics: SystemHaptics(),
            realTime: true,
            fakeLibrary: fake,
            supportsCaptureButtons: false,
            backgroundTasks: SystemBackgroundTasks(),
            appSettings: appSettings,
            scheduler: SystemDelayScheduler()
        )
    }
}

/// `-UITestMode` only: opens the real Settings app, after running `beforeOpening` — with
/// `-UITestDenyCamera`, that "allows" the camera, standing in for the user's toggle in Settings.
@MainActor
final class UITestAppSettingsOpener: AppSettingsOpener {
    private let system = SystemAppSettingsOpener()
    private let beforeOpening: @MainActor () -> Void

    init(beforeOpening: @escaping @MainActor () -> Void) {
        self.beforeOpening = beforeOpening
    }

    func openAppSettings() {
        beforeOpening()
        system.openAppSettings()
    }
}
