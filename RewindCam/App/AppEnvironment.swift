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

    static let uiTestArgument = "-UITestMode"

    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        arguments.contains(uiTestArgument) ? uiTest() : live()
    }

    static func live() -> AppEnvironment {
        AppEnvironment(
            isUITest: false,
            source: CameraFrameSource(),
            photoLibrary: SystemPhotoLibrary(),
            storage: FileBufferStorage.caches,
            settingsStore: UserDefaultsSettingsStore(),
            thermal: SystemThermalMonitor(),
            battery: SystemBatteryMonitor(),
            screen: SystemScreenController(),
            haptics: SystemHaptics(),
            realTime: true,
            fakeLibrary: nil,
            supportsCaptureButtons: true
        )
    }

    /// Synthetic camera, fake Photos in Documents, fresh settings on every launch.
    static func uiTest() -> AppEnvironment {
        let suite = "RewindCam.UITest"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let fake = FakePhotoLibrary.documents
        fake.removeAll()
        return AppEnvironment(
            isUITest: true,
            source: SyntheticFrameSource(format: .uiTest, mode: .realTime, followsConfiguration: true),
            photoLibrary: fake,
            storage: FileBufferStorage.caches,
            settingsStore: UserDefaultsSettingsStore(defaults: defaults),
            thermal: SystemThermalMonitor(),
            battery: SystemBatteryMonitor(),
            screen: SystemScreenController(),
            haptics: SystemHaptics(),
            realTime: true,
            fakeLibrary: fake,
            supportsCaptureButtons: false
        )
    }
}
