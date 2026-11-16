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
    /// On-device "save that" recogniser (nil where unsupported, e.g. UI tests).
    var voice: VoiceTrigger? = nil
    var clock: WallClock = SystemWallClock()

    static let uiTestArgument = "-UITestMode"
    /// With `-UITestMode`: the fake Photos library fails the first save, so the UI test can retry it.
    static let uiTestPhotosFailOnceArgument = "-UITestPhotosFailOnce"

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
        return AppEnvironment(
            isUITest: true,
            source: SyntheticFrameSource(format: .uiTest, mode: .realTime, followsConfiguration: true),
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
            backgroundTasks: SystemBackgroundTasks()
        )
    }
}
