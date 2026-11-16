import Foundation
import Testing
@testable import RewindCam

/// File protection and backup policy (DESIGN.md §2, "File protection and backup").
///
/// The Simulator does not enforce Data Protection, and its file system may not report a class at all.
/// So these tests check, for every kind of media file the app creates:
/// - the class the policy requests, and, wherever the file system reports one, that it is that class;
/// - that hard links really are the same file (same inode, so the same class) and a copy is not;
/// - backup exclusion of the durable folder, and that Caches stays expendable.
/// Whether a locked phone can still read these files is a device-only check (README checklist).
@Suite("File protection and backup")
struct FileProtectionTests {

    private func makeStorage() -> (FileBufferStorage, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("protection-\(UUID().uuidString)")
        let storage = FileBufferStorage(root: root.appendingPathComponent("Caches"),
                                        durableRoot: root.appendingPathComponent("ApplicationSupport"))
        return (storage, root)
    }

    private static func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    private static func linkCount(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.referenceCount] as? NSNumber).intValue
    }

    @Test("Media uses 'until first unlock': lock-safe for background saves, never Complete or Complete-unless-open")
    func mediaClassIsLockSafe() {
        #expect(FileProtectionPolicy.media == .completeUntilFirstUserAuthentication)
        #expect(FileProtectionPolicy.media != .complete)
        #expect(FileProtectionPolicy.media != .completeUnlessOpen)
        // The URL and FileManager spellings name the same class.
        #expect(FileProtectionPolicy.mediaFileProtectionType.rawValue == FileProtectionPolicy.media.rawValue)
        let requested = FileProtectionPolicy.attributes[.protectionKey] as? FileProtectionType
        #expect(requested == .completeUntilFirstUserAuthentication)
    }

    @Test("Every media file and folder has the media class wherever the file system reports one")
    func everyMediaFileHasTheMediaClass() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        storage.removeOrphans() // launch: creates and prepares every folder

        // Ring generation, written like RollingRecorder does (plain, non-atomic writes).
        let gen = storage.bufferDirectory.appendingPathComponent("gen-1", isDirectory: true)
        try FileProtectionPolicy.prepareDirectory(gen)
        let initSegment = gen.appendingPathComponent("init.mp4")
        let segment = gen.appendingPathComponent("seg-000001.m4s")
        try Data(count: 100).write(to: initSegment)
        try Data(count: 1_000).write(to: segment)

        // Save job: hard links of the ring files, plus a copy (the link-failure fallback).
        let job = storage.clipsDirectory.appendingPathComponent("save-1", isDirectory: true)
        try FileProtectionPolicy.prepareDirectory(job)
        let linkedInit = job.appendingPathComponent("init.mp4")
        let linkedSegment = job.appendingPathComponent("seg-000001.m4s")
        try RollingRecorder.linkOrCopy(initSegment, to: linkedInit)
        try RollingRecorder.linkOrCopy(segment, to: linkedSegment)
        let copiedSegment = job.appendingPathComponent("seg-copy.m4s")
        try FileProtectionPolicy.copyItem(at: segment, to: copiedSegment)

        // Concatenated source, as ClipExporter writes it.
        let source = job.appendingPathComponent("source.mp4")
        try ClipExporter.concatenate([linkedInit, linkedSegment], into: source)

        // Export: an atomic write (temporary file renamed into place) stands in for a framework-created file.
        let partial = try storage.partialClipURL(baseName: "RewindCam_P")
        try Data(count: 1_100).write(to: partial, options: .atomic)
        let clip = try storage.commitPartialClip(partial)
        let staged = try storage.stageForPhotos(clip)

        // Hard links are the same file, so they share one protection class; the copy is a separate file.
        #expect(try Self.inode(linkedInit) == Self.inode(initSegment))
        #expect(try Self.inode(linkedSegment) == Self.inode(segment))
        #expect(try Self.inode(copiedSegment) != Self.inode(segment))
        #expect(try Self.inode(staged) == Self.inode(clip.url))
        #expect(try Self.linkCount(clip.url) == 2)
        #expect(try Self.linkCount(segment) == 2)

        let items: [(String, URL)] = [
            ("buffer folder", storage.bufferDirectory), ("save jobs folder", storage.clipsDirectory),
            ("unsaved clips folder", storage.unsavedDirectory), ("generation folder", gen),
            ("init segment", initSegment), ("segment", segment), ("save job folder", job),
            ("linked init", linkedInit), ("linked segment", linkedSegment), ("copied segment", copiedSegment),
            ("concatenated source", source), ("committed clip", clip.url),
            ("Photos staging folder", staged.deletingLastPathComponent()), ("Photos staging link", staged),
        ]
        var report: [String] = []
        for (name, url) in items {
            #expect(fm.fileExists(atPath: url.path), "\(name) missing")
            let observed = FileProtectionPolicy.observedProtection(of: url)
            report.append("\(name)=\(observed?.rawValue ?? "nil")")
            if let observed {
                #expect(observed == FileProtectionPolicy.media, "\(name) has \(observed.rawValue)")
            }
        }
        // Visible in the test log: shows whether this file system reports Data Protection at all.
        print("FILE-PROTECTION-PROBE \(report.joined(separator: ", "))")
    }

    @Test("Launch re-applies the media class to kept clips and never deletes them")
    func launchReconcilesKeptClips() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        // A clip from an older version: written straight into the folder, no explicit class.
        try FileManager.default.createDirectory(at: storage.unsavedDirectory, withIntermediateDirectories: true)
        let old = storage.unsavedDirectory.appendingPathComponent("RewindCam_old.mov")
        try Data(count: 500).write(to: old, options: .atomic)

        #expect(storage.removeOrphans() == 0)
        #expect(storage.unsavedClips().map(\.name) == ["RewindCam_old.mov"])
        #expect(storage.unsavedClips().first?.bytes == 500)
        if let observed = FileProtectionPolicy.observedProtection(of: old) {
            #expect(observed == FileProtectionPolicy.media)
        }
    }

    @Test("Durable folders are excluded from backup, re-marked before each export; Caches folders are wiped")
    func backupPolicy() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        storage.removeOrphans()
        #expect(storage.durableDirectories == [storage.unsavedDirectory])
        #expect(storage.volatileDirectories == [storage.bufferDirectory, storage.clipsDirectory])
        for dir in storage.durableDirectories {
            var fresh = dir
            fresh.removeAllCachedResourceValues()
            #expect(try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                    "\(dir.lastPathComponent) must be excluded from backup")
        }

        // Some file operations reset the flag; every export marks the folder again.
        var dir = storage.unsavedDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try dir.setResourceValues(values)
        _ = try storage.partialClipURL(baseName: "RewindCam_B")
        dir.removeAllCachedResourceValues()
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        // Caches stays expendable: anything left there is removed on the next launch.
        for volatile in storage.volatileDirectories {
            try Data(count: 10).write(to: volatile.appendingPathComponent("leftover"))
        }
        #expect(storage.removeOrphans() == 2)
        for volatile in storage.volatileDirectories {
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: volatile.path)) ?? ["?"]).isEmpty)
        }
    }

    @Test("The app keeps the buffer and save jobs in Caches and unsaved clips in Application Support")
    func standardLayout() throws {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        let storage = FileBufferStorage.standard
        for dir in storage.volatileDirectories {
            #expect(dir.standardizedFileURL.path.hasPrefix(caches + "/"), "\(dir.path) is not in Caches")
        }
        for dir in storage.durableDirectories {
            #expect(dir.standardizedFileURL.path.hasPrefix(support + "/"), "\(dir.path) is not in Application Support")
            #expect(!dir.standardizedFileURL.path.hasPrefix(caches + "/"))
        }
    }
}
