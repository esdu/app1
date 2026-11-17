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
    /// VoiceOver announcements for save results and state changes (issue #11). Tests: `FakeAccessibilityAnnouncer`.
    var announcer: AccessibilityAnnouncer
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
    /// The model's timers: the status loop and capture-recovery backoff (issue #4); live, also the voice
    /// trigger's restart backoff (#36). Tests: `FakeDelayScheduler`.
    var scheduler: DelayScheduler
    /// Free space on the media volume (issue #10), judged by `DiskSpacePolicy`. Tests: `FakeDiskCapacity`.
    var diskCapacity: DiskCapacityProvider
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
    /// With `-UITestMode`: a few seconds after capture starts, the synthetic camera stops delivering
    /// video (while still "running") until it is restarted: the frame watchdog's case (issue #9).
    static let uiTestStallVideoArgument = "-UITestStallVideo"
    /// With `-UITestMode`: free space reads as `uiTestLowDiskBytes` (90 MB), too little for the default
    /// 30 s buffer at 1080p 30 fps but enough for 15 s at 720p 30 fps (issue #10).
    static let uiTestLowDiskArgument = "-UITestLowDisk"
    static let uiTestLowDiskBytes: Int64 = 90_000_000
    /// With `-UITestMode`: free space reads as `uiTestLowDiskWarningBytes` (150 MB): enough to record the
    /// default 30 s buffer at 1080p 30 fps, too little to be sure a save fits, so the orange "Storage is
    /// low" banner shows while recording (issue #10). The large-text UI test uses it for a third banner.
    static let uiTestLowDiskWarningArgument = "-UITestLowDiskWarning"
    static let uiTestLowDiskWarningBytes: Int64 = 150_000_000

    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        arguments.contains(uiTestArgument) ? uiTest(arguments: arguments) : live()
    }

    static func live() -> AppEnvironment {
        let storage = FileBufferStorage.standard
        let scheduler = SystemDelayScheduler()
        return AppEnvironment(
            isUITest: false,
            source: CameraFrameSource(),
            photoLibrary: SystemPhotoLibrary(),
            storage: storage,
            settingsStore: UserDefaultsSettingsStore(),
            thermal: SystemThermalMonitor(),
            battery: SystemBatteryMonitor(),
            screen: SystemScreenController(),
            haptics: SystemHaptics(),
            announcer: SystemAccessibilityAnnouncer(),
            realTime: true,
            fakeLibrary: nil,
            supportsCaptureButtons: true,
            backgroundTasks: SystemBackgroundTasks(),
            appSettings: SystemAppSettingsOpener(),
            scheduler: scheduler,
            diskCapacity: storage.capacity,
            // Its restart backoff (issue #36) uses the same timers.
            voice: SpeechVoiceTrigger(scheduler: scheduler)
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
        if arguments.contains(uiTestStallVideoArgument) {
            source.stallVideoOnce(afterStartBy: 3)
        }
        let diskCapacity: DiskCapacityProvider
        if arguments.contains(uiTestLowDiskArgument) {
            diskCapacity = FakeDiskCapacity(availableBytes: uiTestLowDiskBytes)
        } else if arguments.contains(uiTestLowDiskWarningArgument) {
            diskCapacity = FakeDiskCapacity(availableBytes: uiTestLowDiskWarningBytes)
        } else {
            diskCapacity = storage.capacity
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
            announcer: SystemAccessibilityAnnouncer(),
            realTime: true,
            fakeLibrary: fake,
            supportsCaptureButtons: false,
            backgroundTasks: SystemBackgroundTasks(),
            appSettings: appSettings,
            scheduler: SystemDelayScheduler(),
            diskCapacity: diskCapacity
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
