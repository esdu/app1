import AVFoundation
import Foundation
import Testing
@testable import RewindCam

/// Issue #10: the low-disk guard. Pure policy tests for `BufferMath`'s free-space thresholds and
/// `DiskSpacePolicy`, and model tests that set the free space through the harness's `FakeDiskCapacity`
/// and let time pass on its `FakeDelayScheduler` (no real sleeps).
@Suite("Free-space policy")
struct DiskSpacePolicyTests {

    private static let defaults = RollingRecorder.Configuration(bufferSeconds: 30, preset: QualityPreset(resolution: .hd1080, frameRate: .fps30),
                                                                audioEnabled: true)
    private static let biggest = RollingRecorder.Configuration(bufferSeconds: 120, preset: QualityPreset(resolution: .uhd4K, frameRate: .fps60),
                                                               audioEnabled: true)

    @Test("Defaults (1080p30, 30 s, no post-roll): ≈ 136 MB worst case, as in DESIGN.md")
    func defaultsMatchDesignTable() {
        // 10.064 Mb/s = 1.258 MB/s. Ring cap 1.258 × 33 × 1.5 = 62.271 MB; clip 30 s = 37.74 MB.
        #expect(BufferMath.requiredBytesToBuffer(Self.defaults) == 62_271_000 + 64_000_000)
        #expect(BufferMath.requiredBytesToSave(Self.defaults, postRollSeconds: 0) == 2 * 37_740_000)
        let worstCase = Self.defaults.byteCap + BufferMath.requiredBytesToSave(Self.defaults, postRollSeconds: 0)
        #expect((130_000_000...140_000_000).contains(worstCase), "worst case \(worstCase)")
    }

    @Test("4K60, 120 s, 30 s post-roll: ≈ 3.2 GB worst case, as in DESIGN.md")
    func biggestMatchesDesignTable() {
        // 50.064 Mb/s = 6.258 MB/s. Ring 6.258 × 123 × 1.5; post-roll 30 s; clip 150 s, twice.
        #expect(Self.biggest.byteCap == 1_154_601_000)
        #expect(BufferMath.requiredBytesToBuffer(Self.biggest) == 1_154_601_000 + BufferMath.reserveBytes)
        #expect(BufferMath.requiredBytesToSave(Self.biggest, postRollSeconds: 30) == 187_740_000 + 2 * 938_700_000)
        let worstCase = Self.biggest.byteCap + BufferMath.requiredBytesToSave(Self.biggest, postRollSeconds: 30)
        #expect((3_100_000_000...3_300_000_000).contains(worstCase), "worst case \(worstCase)")
    }

    @Test("Larger settings never need less space")
    func monotonic() {
        let presets = VideoResolution.allCases.flatMap { r in FrameRate.allCases.map { QualityPreset(resolution: r, frameRate: $0) } }
        for preset in presets {
            var last: (buffer: Int64, save: Int64) = (0, 0)
            for seconds in RecordingSettings.bufferChoices {
                let policy = DiskSpacePolicy(bufferSeconds: seconds, preset: preset, audioEnabled: true, postRollSeconds: 10)
                #expect(policy.requiredBytesToBuffer > last.buffer)
                #expect(policy.requiredBytesToSave > last.save)
                last = (policy.requiredBytesToBuffer, policy.requiredBytesToSave)
            }
        }
    }

    @Test("The reserve outlasts the ring's growth between two checks at every preset")
    func reserveCoversCheckInterval() {
        for resolution in VideoResolution.allCases {
            for rate in FrameRate.allCases {
                let preset = QualityPreset(resolution: resolution, frameRate: rate)
                let perSecond = Double(BufferMath.totalBitrate(videoBitrate: preset.videoBitrate, audioEnabled: true)) / 8
                let growth = perSecond * BufferMath.overheadFactor * DiskSpacePolicy.checkInterval
                #expect(growth < Double(DiskSpacePolicy.reserveBytes), "\(preset): \(growth) B per check")
            }
        }
    }

    @Test("Before buffering: too low below the ring cap + reserve, a warning below buffer + save")
    func beforeBuffering() {
        let policy = DiskSpacePolicy(configuration: Self.defaults, postRollSeconds: 0)
        let buffer = policy.requiredBytesToBuffer
        let all = policy.requiredBytesToBufferAndSave
        #expect(policy.beforeBuffering(availableBytes: nil) == .unknown)
        #expect(policy.beforeBuffering(availableBytes: nil).level == .enough, "unknown never blocks")

        let tooLow = policy.beforeBuffering(availableBytes: buffer - 1)
        #expect(tooLow.level == .tooLow)
        #expect(tooLow.availableBytes == buffer - 1)
        #expect(tooLow.bytesToFree == all - (buffer - 1), "enough to free for the buffer and a save")
        #expect(policy.beforeBuffering(availableBytes: 0).level == .tooLow)

        #expect(policy.beforeBuffering(availableBytes: buffer).level == .saveMayNotFit)
        #expect(policy.beforeBuffering(availableBytes: all - 1).level == .saveMayNotFit)
        #expect(policy.beforeBuffering(availableBytes: all - 1).bytesToFree == 1)
        #expect(policy.beforeBuffering(availableBytes: all) == DiskSpaceCheck(level: .enough, availableBytes: all, bytesToFree: 0))
        #expect(policy.beforeBuffering(availableBytes: 50_000_000_000).level == .enough)
    }

    @Test("While recording: stop below the reserve; the ring's own bytes count as available")
    func whileRecording() {
        let policy = DiskSpacePolicy(configuration: Self.defaults, postRollSeconds: 0)
        let reserve = DiskSpacePolicy.reserveBytes
        let all = policy.requiredBytesToBufferAndSave
        let fullRing = Self.defaults.byteCap
        #expect(policy.whileRecording(availableBytes: nil, ringBytes: fullRing) == .unknown)

        // Below the reserve: stop, however big the ring is.
        let stop = policy.whileRecording(availableBytes: reserve - 1, ringBytes: fullRing)
        #expect(stop.level == .tooLow)
        #expect(stop.bytesToFree == all - (reserve - 1 + fullRing), "measured after the ring is deleted")
        #expect(policy.whileRecording(availableBytes: 0, ringBytes: 0).level == .tooLow)

        // At the reserve: keep recording, with a warning.
        #expect(policy.whileRecording(availableBytes: reserve, ringBytes: fullRing).level == .saveMayNotFit)
        // A full ring with room for the reserve and a save: no warning, although free space alone is
        // less than what a start needs (the ring is already on disk).
        let afterFill = all - fullRing
        #expect(afterFill < all)
        #expect(policy.whileRecording(availableBytes: afterFill, ringBytes: fullRing).level == .enough)
        #expect(policy.whileRecording(availableBytes: afterFill - 1, ringBytes: fullRing).level == .saveMayNotFit)
        // An empty ring needs the whole amount.
        #expect(policy.whileRecording(availableBytes: afterFill, ringBytes: 0).level == .saveMayNotFit)
        #expect(policy.whileRecording(availableBytes: all, ringBytes: 0).level == .enough)
    }

    @Test("Before a save: a warning below the save estimate, never a refusal")
    func beforeSave() {
        let policy = DiskSpacePolicy(configuration: Self.biggest, postRollSeconds: 30)
        let save = policy.requiredBytesToSave
        #expect(policy.beforeSave(availableBytes: nil) == .unknown)
        #expect(policy.beforeSave(availableBytes: save).level == .enough)
        let low = policy.beforeSave(availableBytes: save - 1_000)
        #expect(low.level == .saveMayNotFit)
        #expect(low.bytesToFree == 1_000)
        #expect(policy.beforeSave(availableBytes: 0).level == .saveMayNotFit, "not .tooLow: saves are never refused")
        #expect(policy.beforeSave(availableBytes: -5).level == .saveMayNotFit)
    }

    @Test("The policy follows post-roll and sound")
    func followsSettings() {
        let preset = QualityPreset(resolution: .hd1080, frameRate: .fps30)
        let none = DiskSpacePolicy(bufferSeconds: 30, preset: preset, audioEnabled: true, postRollSeconds: 0)
        let post = DiskSpacePolicy(bufferSeconds: 30, preset: preset, audioEnabled: true, postRollSeconds: 30)
        let silent = DiskSpacePolicy(bufferSeconds: 30, preset: preset, audioEnabled: false, postRollSeconds: 0)
        #expect(post.requiredBytesToBuffer == none.requiredBytesToBuffer, "post-roll doesn't change the ring")
        // 30 s post-roll: 30 s of retained segments + 30 s more clip, twice.
        #expect(post.requiredBytesToSave - none.requiredBytesToSave == 3 * 30 * 1_258_000)
        #expect(silent.requiredBytesToSave == 2 * 30 * 1_250_000)
        #expect(silent.requiredBytesToBuffer < none.requiredBytesToBuffer)
    }
}

/// Model tests: in the `AppModelTests` suite so they share its serialization and time limit.
@MainActor
extension AppModelTests {

    /// 1080p30, 30 s, sound, no post-roll (the defaults): 126.271 MB to buffer, 201.751 MB with a save.
    private static let defaultPolicy = DiskSpacePolicy(bufferSeconds: 30, preset: QualityPreset(resolution: .hd1080, frameRate: .fps30),
                                                       audioEnabled: true, postRollSeconds: 0)

    private func keptClip(_ h: ModelHarness, bytes: Int = 1_000_000) throws -> URL {
        try FileManager.default.createDirectory(at: h.storage.unsavedDirectory, withIntermediateDirectories: true)
        let url = h.storage.unsavedDirectory.appendingPathComponent("RewindCam 2026-11-01 kept.mov")
        try Data(count: bytes).write(to: url)
        return url
    }

    @Test("Not enough space for the buffer at start: not recording, says how much to free; Try Again re-checks")
    func lowDiskAtStartRefusesToBuffer() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let kept = try keptClip(h)
        h.disk.set(100_000_000) // < 126.271 MB
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()

        guard case .outOfSpace(let check) = model.phase else {
            Issue.record("expected outOfSpace, got \(model.phase)")
            return
        }
        #expect(check.level == .tooLow)
        #expect(check.bytesToFree == Self.defaultPolicy.requiredBytesToBufferAndSave - 100_000_000)
        #expect(h.source.startCount == 0, "the camera isn't started")
        #expect(h.source.runState == .stopped)
        #expect(!h.screen.idleTimerDisabled)
        #expect(model.status.lastError == nil)
        #expect(model.status.segmentCount == 0)
        #expect(model.saveUnavailableReason == "There isn't enough free space to record.")
        #expect(model.save() == nil, "nothing to save")
        #expect(model.availableDiskBytes == 100_000_000)

        let notice = try #require(model.startFailureNotice)
        #expect(notice.id == "lowDiskBanner")
        #expect(notice.severity == .error)
        #expect(notice.action == .tryAgain)
        #expect(notice.message.hasPrefix("Not enough free space to keep a 30 s buffer at 1080p 30 fps. Free up about "))
        #expect(notice.message.contains(BufferMath.formatted(bytes: check.bytesToFree)))
        #expect(notice.message.contains(AppModel.storageHint))
        #expect(notice.message.contains("lower quality in Settings"))
        #expect(notice.message.contains("1 clip waiting for Photos uses \(BufferMath.formatted(bytes: 1_000_000))."),
                "says what kept clips take: \(notice.message)")
        #expect(model.diskSpaceNotice == nil)

        // Source events while stopped change nothing.
        h.source.simulate(.interruptionEnded)
        await model.waitForCapture()
        #expect(model.phase == .outOfSpace(check))

        // Still too little: Try Again comes back to the same notice.
        model.retryStart()
        await model.waitForCapture()
        #expect(model.phase == .outOfSpace(check))
        #expect(h.source.startCount == 0)

        // Space freed (back from Settings › iPhone Storage): the foreground re-check records.
        h.disk.set(5_000_000_000)
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(model.startFailureNotice == nil)
        #expect(model.diskSpaceNotice == nil)
        #expect(FileManager.default.fileExists(atPath: kept.path), "a kept clip is never deleted to make room")
        model.stop()
        await model.waitForPipeline()
    }

    @Test("A shorter buffer chosen in Settings starts recording once it fits, with a save warning")
    func shorterBufferInSettingsRecords() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.disk.set(100_000_000)
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        #expect(model.phase.isStartFailure)

        // Settings marks every length that doesn't fit: 15 s needs 33.966 + 64 = 97.966 MB.
        #expect(model.bufferChoicesThatDontFit == [30, 60, 90, 120])
        #expect(model.diskSpaceCheck(bufferSeconds: 15).level == .saveMayNotFit)
        #expect(model.diskSpaceCheck(bufferSeconds: 30).level == .tooLow)

        model.updateSettings { $0.bufferSeconds = 15 }
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(h.source.startCount == 1)
        let warning = try #require(model.diskSpaceNotice, "a save at 15 s needs 37.74 MB more than fits")
        #expect(warning.id == "lowDiskWarningBanner")
        #expect(warning.severity == .warning)
        #expect(warning.action == nil)
        #expect(warning.message.hasPrefix("About \(BufferMath.formatted(bytes: 100_000_000)) free."))
        #expect(warning.message.contains("may end early or fail"))
        #expect(warning.message.contains("Recording stops if free space falls below \(BufferMath.formatted(bytes: 64_000_000))"))
        #expect(model.startFailureNotice == nil)

        // A longer buffer is checked like a start; lowering quality re-checks (30 s at 720p30: 31.33 + 64 MB).
        model.updateSettings { $0.bufferSeconds = 60 }
        await model.waitForCapture()
        #expect(model.phase.isStartFailure, "a longer buffer that doesn't fit stops recording")
        model.updateSettings { $0.bufferSeconds = 30; $0.resolution = .hd720 }
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(model.status.lastError == nil)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Free space falls below the reserve mid-recording: stops cleanly within 5 s, no write errors")
    func lowDiskWhileRecordingStopsCleanly() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let kept = try keptClip(h)
        h.disk.set(5_000_000_000)
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        h.screen.brightness = 0.7
        model.setDimmed(true)
        let reads = h.disk.readCount
        await passTime(2, model, h, deliver: true)
        #expect(model.diskSpaceNotice == nil)

        h.disk.set(50_000_000) // below the 64 MB reserve
        await passTime(2.5, model, h, deliver: true)
        #expect(model.phase == .recording, "checked every 5 s, not on every 0.5 s tick")
        #expect(h.disk.readCount == reads, "no free-space read between checks")

        await passTime(0.5, model, h, deliver: true)
        #expect(h.disk.readCount == reads + 1)
        guard case .outOfSpace(let check) = model.phase else {
            Issue.record("expected outOfSpace, got \(model.phase)")
            return
        }
        #expect(check.level == .tooLow)
        #expect(check.availableBytes == 50_000_000)
        #expect(model.status.lastError == nil, "stopped before a write failed")
        #expect(model.recorder.status().isSuspended)
        #expect(model.recorder.status().segmentCount == 0, "the ring is deleted")
        #expect(h.source.runState == .stopped)
        #expect(!h.screen.idleTimerDisabled)
        #expect(!model.isDimmed, "woken so the notice can be seen")
        #expect(h.haptics.failures == 1)
        let notice = try #require(model.startFailureNotice)
        #expect(notice.id == "lowDiskBanner")
        #expect(notice.message.contains("30 s buffer at 1080p 30 fps"))
        #expect(notice.message.contains("1 clip waiting for Photos uses"))
        #expect(FileManager.default.fileExists(atPath: kept.path), "a kept clip is never deleted to make room")
        #expect(model.unsavedClips.map(\.url.lastPathComponent) == [kept.lastPathComponent])

        // Bounded: nothing restarts on its own while space stays low.
        let starts = h.source.startCount
        h.scheduler.advance(by: 60)
        await model.waitForCapture()
        #expect(h.source.startCount == starts)
        #expect(model.phase == .outOfSpace(check))

        h.disk.set(5_000_000_000)
        model.retryStart()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Between the two thresholds mid-recording: keeps recording with a warning that clears with space")
    func lowDiskWhileRecordingWarns() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.disk.set(5_000_000_000)
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        await passTime(1, model, h, deliver: true)
        #expect(model.diskSpaceNotice == nil)

        h.disk.set(150_000_000) // above the reserve, below 201.751 MB minus the small test ring
        await passTime(5, model, h, deliver: true)
        #expect(model.phase == .recording)
        #expect(model.status.lastError == nil)
        let warning = try #require(model.diskSpaceNotice)
        #expect(warning.title == "Storage is low")
        #expect(warning.message.hasPrefix("About \(BufferMath.formatted(bytes: 150_000_000)) free."))
        #expect(warning.message.contains(AppModel.storageHint))
        #expect(model.saveUnavailableReason == nil, "Save stays available")

        h.disk.set(5_000_000_000)
        await passTime(5, model, h, deliver: true)
        #expect(model.phase == .recording)
        #expect(model.diskSpaceNotice == nil)
        model.stop()
        await model.waitForPipeline()
        #expect(model.diskSpace == nil)
    }

    @Test("Unknown free space (nil) records normally")
    func unknownCapacityRecords() async throws {
        let h = ModelHarness() // FakeDiskCapacity(nil)
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        await passTime(11, model, h, deliver: true)
        #expect(model.phase == .recording)
        #expect(h.disk.readCount >= 3, "start and two periodic checks asked")
        #expect(model.diskSpace == .unknown)
        #expect(model.diskSpaceNotice == nil)
        #expect(model.bufferChoicesThatDontFit.isEmpty)
        let task = try #require(model.save())
        #expect(model.toast == nil, "no warning")
        h.source.generate(seconds: 2)
        await task.value
        #expect(h.library.clips().count == 1)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Save with low free space still produces a clip, after a warning toast")
    func lowDiskSaveWarnsButSaves() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.disk.set(5_000_000_000)
        let model = h.makeModel()
        model.start()
        await model.waitForCapture()
        h.source.generate(seconds: 5)

        h.disk.set(70_000_000) // above the reserve, below the 75.48 MB a save can need
        let task = try #require(model.save(), "a save is never refused for space")
        let toast = try #require(model.toast)
        #expect(toast.isWarning)
        #expect(!toast.isError)
        #expect(toast.message.hasPrefix("Storage is low: about \(BufferMath.formatted(bytes: 70_000_000)) free"))
        #expect(toast.message.contains("up to \(BufferMath.formatted(bytes: Self.defaultPolicy.requiredBytesToSave))"))
        #expect(toast.message.contains("Saving anyway"))
        h.source.generate(seconds: 2)
        await task.value
        #expect(h.library.clips().count == 1)
        #expect(model.toast?.message.hasPrefix("Saved") == true, "toast: \(String(describing: model.toast))")
        #expect(h.haptics.successes == 1)
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Space runs out during post-roll: capture stops, and the save still delivers what was recorded")
    func lowDiskDuringPostRollSettlesSave() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.disk.set(5_000_000_000)
        let model = h.makeModel()
        model.updateSettings { $0.postRollSeconds = 10 }
        model.start()
        await model.waitForCapture()
        h.source.generate(seconds: 4)
        let task = try #require(model.save())
        #expect(model.toast?.message == "Saving… recording 10 s more")

        h.disk.set(10_000_000)
        await passTime(5, model, h, deliver: true) // 5 s of the 10 s post-roll, then the check
        guard case .outOfSpace = model.phase else {
            Issue.record("expected outOfSpace, got \(model.phase)")
            return
        }
        await task.value
        #expect(h.library.clips().count == 1)
        #expect(model.toast?.message.contains("It ends early") == true, "toast: \(String(describing: model.toast))")
        #expect(!model.isSaving)
        #expect(model.status.lastError == nil)
    }
}
