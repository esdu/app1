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
    /// What VoiceOver would have been told (issue #11).
    let announcer = FakeAccessibilityAnnouncer()
    let screen = FakeScreenController()
    let library: FakePhotoLibrary
    let defaults: UserDefaults
    let suiteName: String
    let storage: FileBufferStorage
    let voice = FakeVoiceTrigger()
    let clock = FakeWallClock()
    let battery = FakeBatteryMonitor(level: 0.8)
    let backgroundTasks = FakeBackgroundTasks()
    /// Counts "Open Settings" taps instead of leaving the app.
    let appSettings = FakeAppSettingsOpener()
    /// Status loop and recovery backoff: nothing runs until a test calls `scheduler.advance(by:)`.
    let scheduler = FakeDelayScheduler()
    /// Free space the model sees (issue #10). Unknown (nil) by default: treated as enough.
    let disk = FakeDiskCapacity(availableBytes: nil)
    /// The recorder's real-time mode (drop a sample when the encoder isn't ready). Off by default, so
    /// appends wait and every frame is encoded; on where a test feeds one track without the other.
    let realTime: Bool

    /// A "relaunch" is a second `makeModel()` on the same harness: same storage folders, same fake Photos.
    init(thermal: ThermalLevel = .nominal, suiteName: String = "RewindCamTests-\(UUID().uuidString)",
         realTime: Bool = false) {
        self.realTime = realTime
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindCamModel-\(UUID().uuidString)", isDirectory: true)
        // Separate volatile (Caches) and durable (Application Support) roots, like the app.
        storage = FileBufferStorage(root: root.appendingPathComponent("Caches", isDirectory: true),
                                    durableRoot: root.appendingPathComponent("ApplicationSupport", isDirectory: true))
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
            battery: battery, screen: screen, haptics: haptics, announcer: announcer,
            realTime: realTime, fakeLibrary: library, supportsCaptureButtons: false,
            backgroundTasks: backgroundTasks, appSettings: appSettings, scheduler: scheduler,
            diskCapacity: disk, voice: voice,
            clock: clock, monotonicClock: scheduler)
    }

    func makeModel() -> AppModel { AppModel(environment: makeEnvironment()) }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
