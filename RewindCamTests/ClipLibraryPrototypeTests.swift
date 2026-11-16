import AVFoundation
import Foundation
import Testing
@testable import RewindCam

/// Issue #16: checks the *disabled* `ClipLibraryPrototype` against real clips made by #1's durable save
/// path (`partialClipURL` → `ClipExporter.export` → `commitPartialClip`), in temp folders.
/// Nothing here changes what the app does; see docs/decisions/clip-library.md.
///
/// Simulator-only evidence: the Simulator has no real Photos import (`FakePhotoLibrary` moves the file
/// like `shouldMoveFile`) and does not enforce Data Protection. Physical Photos and locked-phone checks
/// are listed as pending in the decision note.
@Suite("Clip library prototype (#16, disabled)", .serialized, .timeLimit(.minutes(5)))
struct ClipLibraryPrototypeTests {

    // MARK: Helpers

    /// Records `seconds` of synthetic footage and saves it exactly like `AppModel.exportDurably`:
    /// export to `UnsavedClips/<name>.partial.mov`, then commit (rename) to `<name>.mov`.
    private func durableClip(_ h: RecorderHarness, seconds: Double = 6) async throws -> UnsavedClip {
        h.source.generate(seconds: seconds)
        let ticket = h.recorder.beginSave(postRoll: 0)
        h.source.generate(seconds: 2)
        let bundle = try await h.awaitBundle(ticket)
        defer { bundle.discard() }
        let partial = try h.storage.partialClipURL(baseName: ClipExporter.defaultBaseName())
        _ = try await ClipExporter.export(bundle, to: partial)
        return try h.storage.commitPartialClip(partial)
    }

    private func library(_ h: RecorderHarness, storage: (any BufferStorage)? = nil,
                         policy: ClipOwnershipPolicy) -> ClipLibraryPrototype {
        ClipLibraryPrototype(storage: storage ?? (h.storage as any BufferStorage),
                             keptDirectory: h.root.appendingPathComponent("KeptLocally", isDirectory: true),
                             policy: policy)
    }

    private func fakePhotos(_ h: RecorderHarness) -> FakePhotoLibrary {
        FakePhotoLibrary(directory: h.root.appendingPathComponent("FakePhotos", isDirectory: true))
    }

    private func contents(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private static func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Tests

    @Test("Policies: only Keep locally (when chosen) or local-first retains a clip Photos accepted; the prototype is off")
    func policyTable() {
        #expect(!ClipOwnershipPolicy.recoveryOnly.retainsAfterPhotos(userChoseKeep: false))
        #expect(!ClipOwnershipPolicy.recoveryOnly.retainsAfterPhotos(userChoseKeep: true))
        #expect(!ClipOwnershipPolicy.keepLocallyOptIn.retainsAfterPhotos(userChoseKeep: false))
        #expect(ClipOwnershipPolicy.keepLocallyOptIn.retainsAfterPhotos(userChoseKeep: true))
        #expect(ClipOwnershipPolicy.localFirst.retainsAfterPhotos(userChoseKeep: false))
        #expect(ClipOwnershipPolicy.localFirst.retainsAfterPhotos(userChoseKeep: true))
        #expect(ClipLibraryPrototype.isEnabledInApp == false)
    }

    @Test("Creation metadata comes from the committed name, not from file timestamps")
    func saveDateFromName() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let base = ClipExporter.defaultBaseName(at: date)
        #expect(ClipLibraryPrototype.saveDate(fromName: base + ".mov") == date)
        #expect(ClipLibraryPrototype.saveDate(fromName: base + "-2.mov") == date)
        #expect(ClipLibraryPrototype.saveDate(fromName: "RewindCam_A.mov") == nil)
        #expect(ClipLibraryPrototype.saveDate(fromName: "clip.mov") == nil)
    }

    @Test("A durable clip is listed, reloads after the buffer is gone (relaunch), plays, and can be shared")
    func reloadPlayAndShare() async throws {
        let h = RecorderHarness(buffer: 10, audio: true)
        let fm = FileManager.default
        let clip = try await durableClip(h)

        // An export still in progress and a Photos staging link are not completed clips.
        let pending = try h.storage.partialClipURL(baseName: "RewindCam_inflight")
        try Data(count: 2_000).write(to: pending)
        let staged = try h.storage.stageForPhotos(clip)

        let lib = library(h, policy: .keepLocallyOptIn)
        #expect(lib.entries().map(\.name) == [clip.name])
        let listed = try #require(lib.entries().first)
        #expect(listed.status == .notInPhotos)
        #expect(listed.bytes == clip.bytes)
        #expect(listed.bytes > 0)
        let saved = try #require(listed.createdAt)
        #expect(abs(saved.timeIntervalSinceNow) < 600, "saved \(saved)")

        // "Relaunch": capture stops, launch cleanup runs on a fresh storage value over the same folders.
        h.source.setSink(nil)
        h.recorder.suspend()
        let relaunched = FileBufferStorage(root: h.root)
        relaunched.removeOrphans()
        #expect(h.segmentFilesOnDisk.isEmpty, "the original buffer is gone")
        #expect(!fm.fileExists(atPath: pending.path))
        #expect(!fm.fileExists(atPath: staged.path))

        let reloaded = library(h, storage: relaunched, policy: .keepLocallyOptIn)
        #expect(reloaded.entries().count == 1)
        let entry = try #require(reloaded.entries().first)
        #expect(entry.id == listed.id)
        #expect(entry.bytes == listed.bytes)
        #expect(entry.status == .notInPhotos)

        // Playback: the kept file is a whole, playable clip independent of the buffer.
        let info = try await inspectClip(reloaded.playbackURL(for: entry))
        expectHealthyClip(info, frameRate: h.frameRate, audio: true)
        #expect(info.duration > 3, "duration \(info.duration)")

        // Sharing: a disposable link in Caches, not a library entry; discarding it keeps the clip.
        let item = try reloaded.shareItem(for: entry)
        #expect(item.lastPathComponent == entry.name)
        #expect(Self.samePath(item.deletingLastPathComponent().deletingLastPathComponent(), relaunched.clipsDirectory))
        #expect(try Self.inode(item) == Self.inode(entry.url))
        #expect(reloaded.entries().map(\.id) == [entry.id])
        let shared = try await inspectClip(item)
        #expect(shared.isPlayable)
        reloaded.discardShareItem(item)
        #expect(!fm.fileExists(atPath: item.path))
        #expect(contents(relaunched.clipsDirectory).isEmpty)
        #expect(fm.fileExists(atPath: entry.url.path))
        #expect(reloaded.entries().map(\.id) == [entry.id])
    }

    @Test("Recovery-only (today's policy): denied or failed Photos keeps the clip; success removes it even if Keep was asked")
    func recoveryOnlyMatchesProduction() async throws {
        let h = RecorderHarness(buffer: 10, audio: false)
        let fm = FileManager.default
        let clip = try await durableClip(h)
        let lib = library(h, policy: .recoveryOnly)
        let photos = fakePhotos(h)
        let entry = try #require(lib.entries().first)

        photos.setDenied(true)
        let denied = await lib.addToPhotos(entry, library: photos, keepLocalCopy: true)
        #expect(denied == .failed(PhotoLibraryError.accessDenied.localizedDescription))
        #expect(lib.entries().map(\.id) == [entry.id])
        #expect(fm.fileExists(atPath: clip.url.path))
        #expect(contents(h.storage.clipsDirectory).isEmpty, "staging is removed after every attempt")

        photos.setDenied(false)
        photos.failNextSaves(["The disk is full."])
        let failed = await lib.addToPhotos(entry, library: photos, keepLocalCopy: true)
        #expect(failed == .failed(PhotoLibraryError.saveFailed("The disk is full.").localizedDescription))
        #expect(lib.entries().map(\.id) == [entry.id])
        #expect(photos.clips().isEmpty)

        let added = await lib.addToPhotos(entry, library: photos, keepLocalCopy: true)
        #expect(added == .addedAndRemoved)
        #expect(lib.entries().isEmpty)
        #expect(h.storage.unsavedClips().isEmpty)
        #expect(!fm.fileExists(atPath: clip.url.path))
        #expect(contents(h.storage.clipsDirectory).isEmpty)
        #expect(photos.clips().count == 1)
        let inPhotos = try #require(photos.clips().first)
        let info = try await inspectClip(inPhotos)
        expectHealthyClip(info, frameRate: h.frameRate, audio: false)
    }

    @Test("Keep locally: Photos gets a link, the kept copy survives the move, leaves the Retry list, and is deleted only explicitly")
    func keepLocallySurvivesPhotosAndDeletesExplicitly() async throws {
        let h = RecorderHarness(buffer: 10, audio: true)
        let fm = FileManager.default
        let first = try await durableClip(h)
        let lib = library(h, policy: .keepLocallyOptIn)
        let photos = fakePhotos(h)
        let entry = try #require(lib.entries().first)

        let outcome = await lib.addToPhotos(entry, library: photos, keepLocalCopy: true)
        guard case .addedAndKept(let kept) = outcome else {
            Issue.record("expected addedAndKept, got \(outcome)")
            return
        }
        #expect(kept.status == .inPhotosKeptLocally)
        #expect(kept.name == first.name)
        #expect(kept.bytes == first.bytes)
        #expect(Self.samePath(kept.url.deletingLastPathComponent(), lib.keptDirectory))
        #expect(h.storage.unsavedClips().isEmpty, "Photos has it: #1's Retry list must not offer it again")
        #expect(lib.entries().map(\.id) == [kept.id])
        #expect(contents(h.storage.clipsDirectory).isEmpty)
        #expect(photos.clips().count == 1)
        let keptInfo = try await inspectClip(kept.url)
        expectHealthyClip(keptInfo, frameRate: h.frameRate, audio: true)
        let photosInfo = try await inspectClip(try #require(photos.clips().first))
        #expect(photosInfo.isPlayable)
        let use = lib.storageUse()
        #expect(use.notInPhotos == 0)
        #expect(use.keptLocally == kept.bytes)

        // Adding a kept clip again (say the user removed it from Photos) never deletes the local copy.
        let again = await lib.addToPhotos(kept, library: photos, keepLocalCopy: false)
        #expect(again == .addedAndKept(kept))
        #expect(photos.clips().count == 2)
        #expect(fm.fileExists(atPath: kept.url.path))

        // Without Keep, the same policy behaves like today: removed once Photos has it.
        let second = try await durableClip(h)
        let secondEntry = try #require(lib.entries().first { $0.status == .notInPhotos })
        #expect(secondEntry.name == second.name)
        let removed = await lib.addToPhotos(secondEntry, library: photos, keepLocalCopy: false)
        #expect(removed == .addedAndRemoved)
        #expect(lib.entries().map(\.id) == [kept.id])
        #expect(photos.clips().count == 3)

        // Delete: explicit and confirmed only. The copies in Photos are untouched.
        #expect(ClipLibraryPrototype.deletePrompt(for: kept).contains("stays in Photos"))
        #expect(throws: ClipLibraryPrototype.DeleteError.notConfirmed) {
            try lib.delete(kept, confirmation: .init(entryID: "notInPhotos/" + kept.name, acknowledgesOnlyCopy: true))
        }
        #expect(fm.fileExists(atPath: kept.url.path))
        try lib.delete(kept, confirmation: .init(entryID: kept.id, acknowledgesOnlyCopy: false))
        #expect(!fm.fileExists(atPath: kept.url.path))
        #expect(lib.entries().isEmpty)
        #expect(throws: ClipLibraryPrototype.DeleteError.notInLibrary) {
            try lib.delete(kept, confirmation: .init(entryID: kept.id, acknowledgesOnlyCopy: true))
        }
        #expect(photos.clips().count == 3)
        for url in photos.clips() {
            let info = try await inspectClip(url)
            #expect(info.isPlayable, "\(url.lastPathComponent)")
            #expect(info.readerCompleted, "\(url.lastPathComponent)")
        }
    }

    @Test("If the kept copy can't be moved after Photos accepted it, the clip stays offered: a duplicate, never a loss")
    func keepFailureNeverLosesTheClip() async throws {
        let h = RecorderHarness(buffer: 10, audio: false)
        let fm = FileManager.default
        let clip = try await durableClip(h)
        // A file where the kept folder should be: creating the folder fails (stands in for a
        // protected-data or disk error at that step).
        let blocked = h.root.appendingPathComponent("NotAFolder")
        try Data(count: 1).write(to: blocked)
        let lib = ClipLibraryPrototype(storage: h.storage, keptDirectory: blocked, policy: .localFirst)
        let photos = fakePhotos(h)
        let entry = try #require(lib.entries().first)

        let outcome = await lib.addToPhotos(entry, library: photos, keepLocalCopy: false)
        guard case .addedButKeepFailed = outcome else {
            Issue.record("expected addedButKeepFailed, got \(outcome)")
            return
        }
        #expect(photos.clips().count == 1)
        #expect(fm.fileExists(atPath: clip.url.path))
        #expect(h.storage.unsavedClips().map(\.name) == [clip.name])
        #expect(lib.entries().map(\.status) == [.notInPhotos])
        #expect(contents(h.storage.clipsDirectory).isEmpty)
        let info = try await inspectClip(clip.url)
        expectHealthyClip(info, frameRate: h.frameRate, audio: false)
    }

    @Test("Deleting a clip Photos doesn't have needs the only-copy acknowledgement; pending exports are never entries")
    func deleteSafetyAndPendingFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let storage = FileBufferStorage(root: root.appendingPathComponent("Caches"),
                                        durableRoot: root.appendingPathComponent("ApplicationSupport"))
        storage.removeOrphans()
        let keptDirectory = root.appendingPathComponent("ApplicationSupport/KeptClips", isDirectory: true)
        try fm.createDirectory(at: keptDirectory, withIntermediateDirectories: true)

        let partial = try storage.partialClipURL(baseName: "RewindCam_A")
        try Data(count: 1_000).write(to: partial)
        let clip = try storage.commitPartialClip(partial)
        let pending = try storage.partialClipURL(baseName: "RewindCam_B")
        try Data(count: 500).write(to: pending)
        let pendingKept = keptDirectory.appendingPathComponent("RewindCam_C" + UnsavedClipFiles.partialSuffix)
        try Data(count: 500).write(to: pendingKept)

        let lib = ClipLibraryPrototype(storage: storage, keptDirectory: keptDirectory, policy: .keepLocallyOptIn)
        #expect(lib.entries().map(\.name) == [clip.name])
        let entry = try #require(lib.entries().first)
        #expect(lib.storageUse().notInPhotos == 1_000)
        #expect(lib.storageUse().keptLocally == 0)
        #expect(ClipLibraryPrototype.deletePrompt(for: entry).contains("only copy"))

        #expect(throws: ClipLibraryPrototype.DeleteError.onlyCopyNotAcknowledged) {
            try lib.delete(entry, confirmation: .init(entryID: entry.id, acknowledgesOnlyCopy: false))
        }
        #expect(throws: ClipLibraryPrototype.DeleteError.notConfirmed) {
            try lib.delete(entry, confirmation: .init(entryID: "inPhotosKeptLocally/" + entry.name, acknowledgesOnlyCopy: true))
        }
        #expect(fm.fileExists(atPath: clip.url.path))

        // An export in progress dressed up as an entry is refused, in either folder.
        for url in [pending, pendingKept] {
            let fake = ClipLibraryPrototype.Entry(url: url, bytes: 500, createdAt: nil, status: .notInPhotos)
            #expect(throws: ClipLibraryPrototype.DeleteError.notInLibrary) {
                try lib.delete(fake, confirmation: .init(entryID: fake.id, acknowledgesOnlyCopy: true))
            }
            #expect(fm.fileExists(atPath: url.path))
        }

        try lib.delete(entry, confirmation: .init(entryID: entry.id, acknowledgesOnlyCopy: true))
        #expect(!fm.fileExists(atPath: clip.url.path))
        #expect(lib.entries().isEmpty)
        #expect(fm.fileExists(atPath: pending.path), "only the confirmed clip is deleted")
    }
}
