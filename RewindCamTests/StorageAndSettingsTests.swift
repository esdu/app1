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

    private func makeStorage() -> (FileBufferStorage, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unsaved-\(UUID().uuidString)")
        let storage = FileBufferStorage(root: root.appendingPathComponent("Caches"),
                                        durableRoot: root.appendingPathComponent("ApplicationSupport"))
        return (storage, root)
    }

    @Test("Launch cleanup keeps finished clips and deletes partial exports; the folder is excluded from backup")
    func launchCleanupKeepsFinishedClips() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: storage.unsavedDirectory, withIntermediateDirectories: true)
        let finished = storage.unsavedDirectory.appendingPathComponent("RewindCam_A.mov")
        let partial = storage.unsavedDirectory.appendingPathComponent("RewindCam_B" + UnsavedClipFiles.partialSuffix)
        try Data(count: 2_000).write(to: finished)
        try Data(count: 1_000).write(to: partial)
        let job = storage.clipsDirectory.appendingPathComponent("save-1")
        try fm.createDirectory(at: job, withIntermediateDirectories: true)

        #expect(storage.removeOrphans() == 2)
        #expect(fm.fileExists(atPath: finished.path))
        #expect(!fm.fileExists(atPath: partial.path))
        #expect(!fm.fileExists(atPath: job.path))
        #expect(storage.unsavedClips().map(\.name) == ["RewindCam_A.mov"])
        #expect(storage.unsavedClips().first?.bytes == 2_000)
        let values = try storage.unsavedDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        // A second launch removes nothing more.
        #expect(storage.removeOrphans() == 0)
        #expect(fm.fileExists(atPath: finished.path))
    }

    @Test("A partial export becomes visible only when committed, and never overwrites a kept clip")
    func commitPartialClipNeverOverwrites() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try storage.partialClipURL(baseName: "RewindCam_X")
        #expect(first.lastPathComponent == "RewindCam_X.partial.mov")
        try Data(count: 10).write(to: first)
        #expect(storage.unsavedClips().isEmpty, "a partial export is not offered for retry")
        let a = try storage.commitPartialClip(first)
        #expect(a.name == "RewindCam_X.mov")

        let second = try storage.partialClipURL(baseName: "RewindCam_X")
        try Data(count: 20).write(to: second)
        let b = try storage.commitPartialClip(second)
        #expect(b.name == "RewindCam_X-2.mov")
        #expect(storage.unsavedClips().map(\.name) == ["RewindCam_X-2.mov", "RewindCam_X.mov"])
        #expect(storage.unsavedClips().map(\.bytes).sorted() == [10, 20])
    }

    @Test("Photos gets a staged link; the kept clip survives Photos taking the file, and staging is cleaned up")
    func stagingForPhotosLeavesKeptClipIntact() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        storage.removeOrphans()
        let partial = try storage.partialClipURL(baseName: "RewindCam_Y")
        try Data(count: 64).write(to: partial)
        let clip = try storage.commitPartialClip(partial)

        let staged = try storage.stageForPhotos(clip)
        #expect(staged.lastPathComponent == clip.name)
        let lib = FakePhotoLibrary(directory: root.appendingPathComponent("Photos"))
        try await lib.saveVideo(at: staged) // moves the staged link away
        #expect(FileManager.default.fileExists(atPath: clip.url.path))
        #expect(StorageAndSettingsTests.size(clip.url) == 64)
        storage.discardStaging(staged)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: storage.clipsDirectory.path)) ?? []).isEmpty)

        storage.removeUnsavedClip(clip)
        #expect(storage.unsavedClips().isEmpty)
        #expect(lib.clips().count == 1)
    }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
