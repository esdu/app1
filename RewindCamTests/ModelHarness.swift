import Foundation
import Testing
@testable import RewindCam

/// In-memory app environment: synthetic manual source, fake Photos, fake device services.
@MainActor
final class ModelHarness {
    let root: URL
    let source: SyntheticFrameSource
    let thermal: FakeThermalMonitor
    let haptics = FakeHaptics()
    let screen = FakeScreenController()
    let library: FakePhotoLibrary
    let defaults: UserDefaults
    let suiteName: String
    let storage: FileBufferStorage
    let voice = FakeVoiceTrigger()
    let clock = FakeWallClock()
    let battery = FakeBatteryMonitor(level: 0.8)

    init(thermal: ThermalLevel = .nominal, suiteName: String = "RewindCamTests-\(UUID().uuidString)") {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindCamModel-\(UUID().uuidString)", isDirectory: true)
        storage = FileBufferStorage(root: root)
        library = FakePhotoLibrary(directory: root.appendingPathComponent("FakePhotoLibrary", isDirectory: true))
        source = SyntheticFrameSource(format: .init(width: 320, height: 180, frameRate: 15, audioEnabled: true),
                                      mode: .manual)
        self.thermal = FakeThermalMonitor(thermal)
        self.suiteName = suiteName
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func makeEnvironment() -> AppEnvironment {
        AppEnvironment(
            isUITest: false, source: source, photoLibrary: library, storage: storage,
            settingsStore: UserDefaultsSettingsStore(defaults: defaults), thermal: thermal,
            battery: battery, screen: screen, haptics: haptics,
            realTime: false, fakeLibrary: library, supportsCaptureButtons: false,
            voice: voice, clock: clock)
    }

    func makeModel() -> AppModel { AppModel(environment: makeEnvironment()) }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
