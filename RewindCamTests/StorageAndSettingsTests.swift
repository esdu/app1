import Foundation
import Testing
@testable import RewindCam

@Suite("Storage, settings and buffer math")
struct StorageAndSettingsTests {

    @Test func orphanedBufferFilesAreRemovedOnLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orphans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FileBufferStorage(root: root)
        let fm = FileManager.default
        let staleGen = storage.bufferDirectory.appendingPathComponent("gen-7")
        let staleSave = storage.clipsDirectory.appendingPathComponent("save-123")
        try fm.createDirectory(at: staleGen, withIntermediateDirectories: true)
        try fm.createDirectory(at: staleSave, withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: staleGen.appendingPathComponent("seg-000001.m4s"))
        try Data(count: 10_000).write(to: staleSave.appendingPathComponent("source.mp4"))
        try Data(count: 5).write(to: storage.bufferDirectory.appendingPathComponent("stray.tmp"))

        let removed = storage.removeOrphans()
        #expect(removed == 3)
        #expect(FileBufferStorage.directorySize(storage.bufferDirectory) == 0)
        #expect(FileBufferStorage.directorySize(storage.clipsDirectory) == 0)
        #expect(fm.fileExists(atPath: storage.bufferDirectory.path))
        #expect(fm.fileExists(atPath: storage.clipsDirectory.path))
    }

    @Test func settingsStoreRoundTrip() {
        let suite = "RewindCamTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.load() == RecordingSettings())
        var s = RecordingSettings()
        s.bufferSeconds = 120
        s.postRollSeconds = 30
        s.resolution = .uhd4K
        s.frameRate = .fps60
        s.audioEnabled = false
        s.camera = .front
        s.voiceTriggerEnabled = true
        store.save(s)
        #expect(UserDefaultsSettingsStore(defaults: defaults).load() == s)
    }

    @Test func settingsDecodeIsTolerant() throws {
        let json = #"{"bufferSeconds": 60, "resolution": "8K", "postRollSeconds": 7}"#
        let s = try JSONDecoder().decode(RecordingSettings.self, from: Data(json.utf8))
        #expect(s.bufferSeconds == 60)
        #expect(s.resolution == .hd1080)   // unknown value → default
        #expect(s.postRollSeconds == 0)    // not an offered choice → default
        #expect(s.audioEnabled)
    }

    @Test func bufferMathMatchesDesignDoc() {
        let p1080 = QualityPreset(resolution: .hd1080, frameRate: .fps30)
        // DESIGN.md: 1080p30, 120 s ≈ 151.0 MB nominal; ring cap ≈ 232 MB.
        let nominal = BufferMath.estimatedBytes(preset: p1080, audioEnabled: true, seconds: 120)
        #expect(abs(Double(nominal) - 150.96e6) < 0.1e6)
        let cap = BufferMath.ringCapBytes(videoBitrate: p1080.videoBitrate, audioEnabled: true, bufferSeconds: 120)
        #expect(abs(Double(cap) - 232.1e6) < 0.5e6)
        // 4K60 / 120 s ≈ 751 MB nominal.
        let p4k = QualityPreset(resolution: .uhd4K, frameRate: .fps60)
        #expect(abs(Double(BufferMath.estimatedBytes(preset: p4k, audioEnabled: true, seconds: 120)) - 751e6) < 1e6)
    }

    @Test func capGrowsMonotonicallyWithBufferAndQuality() {
        var last: Int64 = 0
        for seconds in RecordingSettings.bufferChoices {
            let cap = BufferMath.ringCapBytes(videoBitrate: 10_000_000, audioEnabled: true, bufferSeconds: Double(seconds))
            #expect(cap > last)
            last = cap
        }
    }

    @Test func fakePhotoLibraryStoresClips() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fakelib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = FakePhotoLibrary(directory: dir)
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data(count: 64).write(to: src)
        try await lib.saveVideo(at: src)
        #expect(lib.clips().count == 1)
        #expect(!FileManager.default.fileExists(atPath: src.path))
    }
}
