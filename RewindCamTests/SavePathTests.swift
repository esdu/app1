import AVFoundation
import Foundation
import Testing
@testable import RewindCam

/// The durable save path (issue #1): a clip is only deleted once Photos has it.
/// In the `AppModelTests` suite so it shares its serialization and time limit.
@MainActor
extension AppModelTests {

    /// Starts the model, records `seconds` of synthetic footage, saves, and lets the save finish.
    private func recordAndSave(_ model: AppModel, _ h: ModelHarness, seconds: Double = 5) async throws {
        h.source.generate(seconds: seconds)
        let task = try #require(model.save())
        h.source.generate(seconds: 2)
        await task.value
    }

    private func contents(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test("Photos failure keeps the finished clip durably; Retry adds it and only then deletes it")
    func photosFailureKeepsClipAndRetrySucceeds() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.library.failNextSaves(["The disk is full."])
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()
        try await recordAndSave(model, h)

        #expect(h.library.clips().isEmpty)
        #expect(model.savedClipCount == 0)
        #expect(model.unsavedClips.count == 1)
        let kept = try #require(model.unsavedClips.first)
        #expect(FileManager.default.fileExists(atPath: kept.url.path))
        #expect(kept.url.deletingLastPathComponent().resolvingSymlinksInPath().path
                == h.storage.unsavedDirectory.resolvingSymlinksInPath().path)
        #expect(kept.url.pathExtension == "mov")
        #expect(!kept.name.contains(".partial"))
        #expect(kept.bytes > 0)
        #expect(model.toast?.isError == true)
        #expect(model.toast?.message.contains("kept") == true, "toast: \(String(describing: model.toast))")
        #expect(model.lastPhotosError?.contains("The disk is full.") == true)
        #expect(model.photosProblem != nil)
        #expect(h.haptics.failures == 1)
        #expect(h.haptics.successes == 0)
        // Job folder and Photos staging are gone; only the kept .mov remains.
        #expect(contents(h.storage.clipsDirectory).isEmpty, "Caches leftovers: \(contents(h.storage.clipsDirectory))")
        #expect(contents(h.storage.unsavedDirectory) == [kept.name])
        #expect(h.backgroundTasks.begun == 1)
        #expect(h.backgroundTasks.ended == 1)

        let retry = try #require(model.retryUnsavedClips())
        await retry.value
        #expect(h.library.clips().count == 1)
        #expect(model.unsavedClips.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: kept.url.path))
        #expect(contents(h.storage.unsavedDirectory).isEmpty)
        #expect(contents(h.storage.clipsDirectory).isEmpty)
        #expect(model.lastPhotosError == nil)
        #expect(model.savedClipCount == 1)
        #expect(model.toast?.isError == false)
        #expect(model.toast?.message.hasPrefix("Saved") == true)
        #expect(h.haptics.successes == 1)
        #expect(!model.isRetryingUnsaved)
        // Retry has its own background-task assertion, also ended.
        #expect(h.backgroundTasks.begun == 2)
        #expect(h.backgroundTasks.ended == 2)
        #expect(h.backgroundTasks.activeCount == 0)

        // What reached Photos is the whole clip, not a stub.
        let inPhotos = try #require(h.library.clips().first)
        let duration = try await AVURLAsset(url: inPhotos).load(.duration).seconds
        #expect((3.0...7.0).contains(duration), "about 5 s were recorded; got \(duration)")
        #expect(model.retryUnsavedClips() == nil, "nothing left to retry")

        model.stop()
        await model.waitForPipeline()
    }

    @Test("Photos access is requested at launch, before any save, and only once")
    func photosAccessRequestedAtLaunch() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()
        try await waitUntil { model.photosAccessGranted != nil }
        #expect(model.photosAccessGranted == true)
        #expect(h.library.accessRequests == 1)
        #expect(h.library.clips().isEmpty)

        model.stop()
        await model.waitForPipeline()
        model.start()
        await model.waitForPipeline()
        #expect(h.library.accessRequests == 1, "asked again after a restart")
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Photos denied: the user is told at launch, and a save keeps the clip with a Settings hint")
    func photosDeniedKeepsClip() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.library.setDenied(true)
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()
        try await waitUntil { model.photosAccessGranted != nil }
        #expect(model.photosAccessGranted == false)
        #expect(model.photosProblem == AppModel.photosDeniedHint)
        #expect(model.photosProblem?.contains("Settings") == true)

        try await recordAndSave(model, h)
        #expect(h.library.clips().isEmpty)
        #expect(model.unsavedClips.count == 1)
        let kept = try #require(model.unsavedClips.first)
        #expect(FileManager.default.fileExists(atPath: kept.url.path))
        #expect(model.lastPhotosError?.contains("Settings") == true)
        #expect(model.toast?.isError == true)
        #expect(h.backgroundTasks.begun == 1)
        #expect(h.backgroundTasks.ended == 1)

        // Still denied: Retry fails, and the clip is still kept.
        let retry = try #require(model.retryUnsavedClips())
        await retry.value
        #expect(model.unsavedClips.map(\.name) == [kept.name])
        #expect(FileManager.default.fileExists(atPath: kept.url.path))
        #expect(h.backgroundTasks.begun == 2)
        #expect(h.backgroundTasks.ended == 2)

        // The user allows access in Settings: Retry succeeds.
        h.library.setDenied(false)
        let second = try #require(model.retryUnsavedClips())
        await second.value
        #expect(h.library.clips().count == 1)
        #expect(model.unsavedClips.isEmpty)
        #expect(model.photosAccessGranted == true)
        #expect(model.photosProblem == nil)

        model.stop()
        await model.waitForPipeline()
    }

    @Test("Relaunch keeps clips that never reached Photos, removes stray partial exports and job folders")
    func relaunchKeepsUnsavedClips() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.library.failNextSaves(["Simulated failure."])
        let first = h.makeModel()
        first.start()
        await first.waitForPipeline()
        try await recordAndSave(first, h)
        let kept = try #require(first.unsavedClips.first)
        first.stop()
        await first.waitForPipeline()

        // What a kill mid-export leaves behind: a partial export and a save job folder.
        let fm = FileManager.default
        let partial = h.storage.unsavedDirectory.appendingPathComponent("RewindCam_killed" + UnsavedClipFiles.partialSuffix)
        try Data(count: 1_000).write(to: partial)
        let job = h.storage.clipsDirectory.appendingPathComponent("save-killed", isDirectory: true)
        try fm.createDirectory(at: job, withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: job.appendingPathComponent("seg-000001.m4s"))

        // "Relaunch": a new model on the same storage.
        let second = h.makeModel()
        #expect(second.unsavedClips.isEmpty, "not loaded before launch cleanup")
        second.start()
        await second.waitForPipeline()
        #expect(second.unsavedClips.map(\.name) == [kept.name])
        #expect(fm.fileExists(atPath: kept.url.path))
        #expect(!fm.fileExists(atPath: partial.path))
        #expect(!fm.fileExists(atPath: job.path))
        #expect(second.orphansRemoved >= 2)
        #expect(contents(h.storage.unsavedDirectory) == [kept.name])

        let retry = try #require(second.retryUnsavedClips())
        await retry.value
        #expect(h.library.clips().count == 1)
        #expect(second.unsavedClips.isEmpty)
        #expect(contents(h.storage.unsavedDirectory).isEmpty)

        second.stop()
        await second.waitForPipeline()
    }

    @Test("A save that fails before export leaves no partial file and still ends its background task")
    func failedSaveLeavesNothingBehind() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForPipeline()
        // No frames yet: nothing is buffered.
        let task = try #require(model.save())
        await task.value
        #expect(model.toast?.isError == true)
        #expect(!model.isSaving)
        #expect(model.unsavedClips.isEmpty)
        #expect(contents(h.storage.unsavedDirectory).isEmpty)
        #expect(contents(h.storage.clipsDirectory).isEmpty)
        #expect(h.backgroundTasks.begun == 1)
        #expect(h.backgroundTasks.ended == 1)
        #expect(h.backgroundTasks.activeCount == 0)
        model.stop()
        await model.waitForPipeline()
    }
}
