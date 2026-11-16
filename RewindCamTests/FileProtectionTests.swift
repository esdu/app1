import Foundation
import Testing
@testable import RewindCam

/// File protection and backup policy (DESIGN.md §2, "File protection and backup").
///
/// The Simulator records Data Protection classes (CI's iOS 26 Simulator reports them) but does not
/// enforce them: a locked Simulator still reads every file. So these tests check, for every kind of
/// media file the app creates:
/// - the class the policy requests, and that every file reads back with it (strictly wherever the file
///   system reports classes, which is the case on CI's Simulator and on devices);
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

    /// True where the file system reports a Data Protection class (devices, and CI's Simulator).
    static var fileSystemReportsProtection: Bool {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        guard (try? Data(count: 1).write(to: probe)) != nil else { return false }
        FileProtectionPolicy.apply(to: probe)
        return FileProtectionPolicy.observedProtection(of: probe) != nil
    }

    /// Every kind of media file the app creates, made through the app's own code paths.
    private struct MediaFiles {
        let items: [(name: String, url: URL)]
        let initSegment: URL
        let segment: URL
        let linkedInit: URL
        let linkedSegment: URL
        let copiedSegment: URL
        let clip: URL
        let staged: URL

        init(_ storage: FileBufferStorage) throws {
            storage.removeOrphans() // launch: creates and prepares every folder

            // Ring generation, written like RollingRecorder does (plain, non-atomic writes).
            let gen = storage.bufferDirectory.appendingPathComponent("gen-1", isDirectory: true)
            try FileProtectionPolicy.prepareDirectory(gen)
            initSegment = gen.appendingPathComponent("init.mp4")
            segment = gen.appendingPathComponent("seg-000001.m4s")
            try Data(count: 100).write(to: initSegment)
            try Data(count: 1_000).write(to: segment)

            // Save job: hard links of the ring files, plus a copy (the link-failure fallback).
            let job = storage.clipsDirectory.appendingPathComponent("save-1", isDirectory: true)
            try FileProtectionPolicy.prepareDirectory(job)
            linkedInit = job.appendingPathComponent("init.mp4")
            linkedSegment = job.appendingPathComponent("seg-000001.m4s")
            try RollingRecorder.linkOrCopy(initSegment, to: linkedInit)
            try RollingRecorder.linkOrCopy(segment, to: linkedSegment)
            copiedSegment = job.appendingPathComponent("seg-copy.m4s")
            try FileProtectionPolicy.copyItem(at: segment, to: copiedSegment)

            // Concatenated source, as ClipExporter writes it.
            let source = job.appendingPathComponent("source.mp4")
            try ClipExporter.concatenate([linkedInit, linkedSegment], into: source)

            // Export: an atomic write (temporary file renamed into place) stands in for a framework-created file.
            let partial = try storage.partialClipURL(baseName: "RewindCam_P")
            try Data(count: 1_100).write(to: partial, options: .atomic)
            let committed = try storage.commitPartialClip(partial)
            clip = committed.url
            staged = try storage.stageForPhotos(committed)

            items = [
                ("buffer folder", storage.bufferDirectory), ("save jobs folder", storage.clipsDirectory),
                ("unsaved clips folder", storage.unsavedDirectory), ("generation folder", gen),
                ("init segment", initSegment), ("segment", segment), ("save job folder", job),
                ("linked init", linkedInit), ("linked segment", linkedSegment), ("copied segment", copiedSegment),
                ("concatenated source", source), ("committed clip", clip),
                ("Photos staging folder", staged.deletingLastPathComponent()), ("Photos staging link", staged),
            ]
        }
    }

    @Test("Media uses 'until first unlock': lock-safe for background saves, never Complete or Complete-unless-open")
    func mediaClassIsLockSafe() {
        #expect(FileProtectionPolicy.media == .completeUntilFirstUserAuthentication)
        #expect(FileProtectionPolicy.media != .complete)
        #expect(FileProtectionPolicy.media != .completeUnlessOpen)
        // What FileManager is asked to set is the same class, in FileManager's spelling.
        #expect(FileProtectionPolicy.mediaFileProtectionType == .completeUntilFirstUserAuthentication)
        let requested = FileProtectionPolicy.attributes[.protectionKey] as? FileProtectionType
        #expect(requested == .completeUntilFirstUserAuthentication)
    }

    @Test("Every media file exists; hard links are the same file (one class), the copy is a separate file")
    func everyMediaFileIsCreatedAndLinksShareTheirInode() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try MediaFiles(storage)
        for (name, url) in files.items {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(name) missing")
            // Wherever a class is reported at all, it is the media class.
            if let observed = FileProtectionPolicy.observedProtection(of: url) {
                #expect(observed == FileProtectionPolicy.media, "\(name) has \(observed.rawValue)")
            }
        }
        #expect(try Self.inode(files.linkedInit) == Self.inode(files.initSegment))
        #expect(try Self.inode(files.linkedSegment) == Self.inode(files.segment))
        #expect(try Self.inode(files.copiedSegment) != Self.inode(files.segment))
        #expect(try Self.inode(files.staged) == Self.inode(files.clip))
        #expect(try Self.linkCount(files.clip) == 2)
        #expect(try Self.linkCount(files.segment) == 2)
    }

    /// Strict read-back. Runs wherever the file system reports Data Protection classes (CI's Simulator
    /// does; it records classes but doesn't enforce them). Only a file system that reports no class at
    /// all skips it.
    @Test("Where Data Protection is reported, every media file reads back as 'until first unlock'",
          .enabled(if: FileProtectionTests.fileSystemReportsProtection,
                   "this file system reports no Data Protection class"))
    func everyMediaFileReadsBackTheMediaClass() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try MediaFiles(storage)
        for (name, url) in files.items {
            let observed = FileProtectionPolicy.observedProtection(of: url)
            #expect(observed == FileProtectionPolicy.media, "\(name) has \(observed?.rawValue ?? "no class")")
        }
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
