import Foundation

/// Where the rolling buffer, in-flight saves and clips that haven't reached Photos live.
/// Tests point it at temp folders. See DESIGN.md §2, "Folders".
///
/// | Folder | Location | Holds | On launch |
/// |---|---|---|---|
/// | `bufferDirectory` | `Caches/RewindBuffer` | the rolling ring (one folder per writer generation) | wiped |
/// | `clipsDirectory` | `Caches/RewindClips` | save job folders (`save-*`) and Photos staging links (`photos-*`) | wiped |
/// | `unsavedDirectory` | `Application Support/UnsavedClips`, excluded from backup | finished clips not yet in Photos (`*.mov`) and exports in progress (`*.partial.mov`) | `*.partial.mov` deleted, `*.mov` kept |
///
/// Every folder and file here uses `FileProtectionPolicy.media` (available after first unlock), so a save
/// can finish while the phone is locked. See DESIGN.md §2, "File protection and backup".
protocol BufferStorage: Sendable {
    var bufferDirectory: URL { get }
    var clipsDirectory: URL { get }
    /// Durable home of finished clips until Photos has them. Never in Caches, never auto-deleted.
    var unsavedDirectory: URL { get }
    /// Deletes leftovers from a previous process that can't be a finished clip, and creates the folders.
    /// Returns the number of items removed.
    @discardableResult func removeOrphans() -> Int
}

/// A finished clip that is kept in `unsavedDirectory` until Photos accepts it.
struct UnsavedClip: Equatable, Identifiable, Sendable {
    let url: URL
    let bytes: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum UnsavedClipFiles {
    /// An export still being written. Renamed to `.mov` only when complete, so a `.mov` is always whole.
    static let partialSuffix = ".partial.mov"

    static func isPartial(_ url: URL) -> Bool { url.lastPathComponent.hasSuffix(partialSuffix) }
    static func isFinished(_ url: URL) -> Bool { url.pathExtension == "mov" && !isPartial(url) }
}

// MARK: - Unsaved clips (finished, not yet in Photos)

extension BufferStorage {
    /// Creates `unsavedDirectory` if needed, with the media protection class, and marks it excluded
    /// from iCloud/Finder backup (clips can be large and are meant to be transient until Photos has them;
    /// a failure to set either never blocks a save). Re-applied before every export.
    func prepareUnsavedDirectory() throws {
        try FileProtectionPolicy.prepareDirectory(unsavedDirectory, excludedFromBackup: true)
    }

    /// Where an export in progress should write: `<unsaved>/<baseName>.partial.mov` (any stale one is removed).
    func partialClipURL(baseName: String) throws -> URL {
        try prepareUnsavedDirectory()
        let url = unsavedDirectory.appendingPathComponent(baseName + UnsavedClipFiles.partialSuffix)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// Renames a complete export from `.partial.mov` to `.mov`, never overwriting an existing clip
    /// (`name.mov`, then `name-2.mov`, …). The export was written by `AVAssetExportSession`, so the
    /// media protection class is set on it explicitly first; the rename keeps the inode, and the class.
    func commitPartialClip(_ partial: URL) throws -> UnsavedClip {
        let fm = FileManager.default
        FileProtectionPolicy.apply(to: partial)
        let file = partial.lastPathComponent
        let base = file.hasSuffix(UnsavedClipFiles.partialSuffix)
            ? String(file.dropLast(UnsavedClipFiles.partialSuffix.count))
            : partial.deletingPathExtension().lastPathComponent
        var destination = unsavedDirectory.appendingPathComponent(base + ".mov")
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = unsavedDirectory.appendingPathComponent("\(base)-\(n).mov")
            n += 1
        }
        try fm.moveItem(at: partial, to: destination)
        return UnsavedClip(url: destination, bytes: Self.fileSize(destination))
    }

    /// Finished clips waiting for Photos, sorted by name (names start with the save date).
    /// Partial exports are not listed.
    func unsavedClips() -> [UnsavedClip] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: unsavedDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.filter(UnsavedClipFiles.isFinished)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { UnsavedClip(url: $0, bytes: Self.fileSize($0)) }
    }

    /// Hard-links the clip into a fresh `clipsDirectory/photos-<uuid>/` folder (copies if linking fails),
    /// so `PhotoLibrary.saveVideo` may move or consume the file without touching the kept copy.
    /// The link is the same inode as the kept clip, so it has the same protection class; a copy gets
    /// the media class set explicitly (`RollingRecorder.linkOrCopy`).
    /// A copy (issue #14) is made only if `space` grants its size above `floor`; otherwise this throws
    /// `StorageSpaceError.noRoomToCopy` and the kept clip stays for Retry.
    func stageForPhotos(_ clip: UnsavedClip, space: TemporarySpace? = nil, floor: Int64 = 0) throws -> URL {
        let dir = clipsDirectory.appendingPathComponent("photos-\(UUID().uuidString)", isDirectory: true)
        try FileProtectionPolicy.prepareDirectory(dir)
        let staged = dir.appendingPathComponent(clip.name)
        do {
            try RollingRecorder.linkOrCopy(clip.url, to: staged, space: space, floor: floor)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return staged
    }

    /// Removes the staging folder created by `stageForPhotos` (whether or not Photos took the file).
    func discardStaging(_ staged: URL) {
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }

    /// Deletes a kept clip. Only called after Photos reported success.
    func removeUnsavedClip(_ clip: UnsavedClip) {
        try? FileManager.default.removeItem(at: clip.url)
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

// MARK: - Working set (issue #14)

/// What RewindCam's media files take on disk right now, measured by enumerating the folders (not
/// estimated). Each physical file counts once: a hard link shares its data with the file it links
/// (same device and inode), so a save's links to ring segments, and a Photos staging link to a kept
/// clip, add nothing; copies, `source.mp4` and exports do. See DESIGN.md §2, "Bounded disk".
struct MediaWorkingSet: Equatable, Sendable {
    /// `RewindBuffer/`: the ring (every generation folder).
    var ringBytes: Int64 = 0
    /// `RewindClips/save-*`: what save jobs hold besides ring files: links to segments the ring has
    /// evicted since (post-roll), copies where linking failed, and the concatenated `source.mp4`.
    var saveJobBytes: Int64 = 0
    /// `UnsavedClips/*.partial.mov`: exports being written.
    var exportBytes: Int64 = 0
    /// `RewindClips/photos-*`: Photos staging copies (a staging link to a kept clip is 0).
    var stagingBytes: Int64 = 0
    /// `UnsavedClips/*.mov`: finished clips waiting for Photos. Durable, not temporary: reported
    /// separately and never deleted to make room.
    var keptClipBytes: Int64 = 0

    /// Everything temporary: what `BufferMath.temporaryMediaCapBytes` bounds.
    var temporaryBytes: Int64 { ringBytes + saveJobBytes + exportBytes + stagingBytes }
}

extension BufferStorage {
    /// Measures `MediaWorkingSet` from the files on disk. Kept clips are visited first, then the ring,
    /// so a link is attributed to the file it shares data with.
    func measureWorkingSet() -> MediaWorkingSet {
        var seen = Set<FileIdentity>()
        var set = MediaWorkingSet()
        func add(_ url: URL, to keyPath: WritableKeyPath<MediaWorkingSet, Int64>) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
               let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value {
                guard seen.insert(FileIdentity(device: device, inode: inode)).inserted else { return }
            }
            set[keyPath: keyPath] += size
        }
        let durable = Self.allItems(in: unsavedDirectory)
        for url in durable where UnsavedClipFiles.isFinished(url) { add(url, to: \.keptClipBytes) }
        for url in Self.allItems(in: bufferDirectory) { add(url, to: \.ringBytes) }
        // `RewindClips/` holds one folder per save job (`save-*`) or Photos staging (`photos-*`).
        let folders = (try? FileManager.default.contentsOfDirectory(at: clipsDirectory, includingPropertiesForKeys: nil)) ?? []
        let staging = folders.filter { $0.lastPathComponent.hasPrefix("photos-") }
        for folder in folders where !staging.contains(folder) {
            for url in [folder] + Self.allItems(in: folder) { add(url, to: \.saveJobBytes) }
        }
        for url in durable where UnsavedClipFiles.isPartial(url) { add(url, to: \.exportBytes) }
        for folder in staging {
            for url in Self.allItems(in: folder) { add(url, to: \.stagingBytes) }
        }
        return set
    }

    private static func allItems(in directory: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }
    }
}

/// A physical file: hard links share it.
private struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

// MARK: - File system implementation

struct FileBufferStorage: BufferStorage {
    /// Volatile root (Caches in the app): buffer and save jobs.
    let root: URL
    /// Durable root (Application Support in the app): clips that haven't reached Photos.
    let durableRoot: URL

    init(root: URL, durableRoot: URL? = nil) {
        self.root = root
        self.durableRoot = durableRoot ?? root
    }

    /// Caches for the buffer and save jobs, Application Support for unsaved clips.
    static var standard: FileBufferStorage {
        let fm = FileManager.default
        return FileBufferStorage(root: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                                 durableRoot: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    var bufferDirectory: URL { root.appendingPathComponent("RewindBuffer", isDirectory: true) }
    var clipsDirectory: URL { root.appendingPathComponent("RewindClips", isDirectory: true) }
    var unsavedDirectory: URL { durableRoot.appendingPathComponent("UnsavedClips", isDirectory: true) }

    /// Expendable folders: in Caches (never backed up, may be purged by iOS), wiped on every launch.
    var volatileDirectories: [URL] { [bufferDirectory, clipsDirectory] }
    /// Folders holding user saves: outside Caches, excluded from backup, never wiped.
    var durableDirectories: [URL] { [unsavedDirectory] }

    /// Wipes the ring and save job folders (Caches), and deletes stray `.partial.mov` exports.
    /// Finished clips in `unsavedDirectory` are never removed here: they are offered for retry.
    /// Also (re)applies the media protection class to every folder and to each kept clip, so files
    /// written by an older version, or touched by a failed Photos import, end up with the intended class.
    @discardableResult
    func removeOrphans() -> Int {
        let fm = FileManager.default
        var removed = 0
        for dir in volatileDirectories {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in items where (try? fm.removeItem(at: item)) != nil {
                removed += 1
            }
            try? FileProtectionPolicy.prepareDirectory(dir)
        }
        try? prepareUnsavedDirectory()
        let kept = (try? fm.contentsOfDirectory(at: unsavedDirectory, includingPropertiesForKeys: nil)) ?? []
        for item in kept {
            if UnsavedClipFiles.isPartial(item) {
                if (try? fm.removeItem(at: item)) != nil { removed += 1 }
            } else if UnsavedClipFiles.isFinished(item) {
                FileProtectionPolicy.apply(to: item)
            }
        }
        return removed
    }

    /// Free space on the volume holding these folders (issue #10). Read through `AppEnvironment.diskCapacity`.
    var capacity: VolumeDiskCapacity { VolumeDiskCapacity(volumeURL: root) }

    /// Recursive on-disk size of a directory (allocated bytes of regular files).
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    static func files(in url: URL, withExtension ext: String) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == ext }
    }
}
