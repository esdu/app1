import Foundation

/// Where the rolling buffer, in-flight saves and clips that haven't reached Photos live.
/// Tests point it at temp folders. See DESIGN.md §2, "Folders".
///
/// | Folder | Location | Holds | On launch |
/// |---|---|---|---|
/// | `bufferDirectory` | `Caches/RewindBuffer` | the rolling ring (one folder per writer generation) | wiped |
/// | `clipsDirectory` | `Caches/RewindClips` | save job folders (`save-*`) and Photos staging links (`photos-*`) | wiped |
/// | `unsavedDirectory` | `Application Support/UnsavedClips`, excluded from backup | finished clips not yet in Photos (`*.mov`) and exports in progress (`*.partial.mov`) | `*.partial.mov` deleted, `*.mov` kept |
protocol BufferStorage: Sendable {
    var bufferDirectory: URL { get }
    var clipsDirectory: URL { get }
    /// Durable home of finished clips until Photos has them. Never in Caches, never auto-deleted.
    var unsavedDirectory: URL { get }
    /// Deletes leftovers from a previous process that can't be a finished clip, and creates the folders.
    /// Returns the number of items removed.
    @discardableResult func removeOrphans() -> Int
    func availableCapacity() -> Int64?
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
    /// Creates `unsavedDirectory` if needed and marks it excluded from iCloud/iTunes backup
    /// (clips can be large and are meant to be transient; a failure to mark it never blocks a save).
    func prepareUnsavedDirectory() throws {
        try FileManager.default.createDirectory(at: unsavedDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = unsavedDirectory
        try? dir.setResourceValues(values)
    }

    /// Where an export in progress should write: `<unsaved>/<baseName>.partial.mov` (any stale one is removed).
    func partialClipURL(baseName: String) throws -> URL {
        try prepareUnsavedDirectory()
        let url = unsavedDirectory.appendingPathComponent(baseName + UnsavedClipFiles.partialSuffix)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// Renames a complete export from `.partial.mov` to `.mov`, never overwriting an existing clip
    /// (`name.mov`, then `name-2.mov`, …).
    func commitPartialClip(_ partial: URL) throws -> UnsavedClip {
        let fm = FileManager.default
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
    func stageForPhotos(_ clip: UnsavedClip) throws -> URL {
        let dir = clipsDirectory.appendingPathComponent("photos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent(clip.name)
        do {
            try RollingRecorder.linkOrCopy(clip.url, to: staged)
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

    /// Wipes the ring and save job folders (Caches), and deletes stray `.partial.mov` exports.
    /// Finished clips in `unsavedDirectory` are never removed here: they are offered for retry.
    @discardableResult
    func removeOrphans() -> Int {
        let fm = FileManager.default
        var removed = 0
        for dir in [bufferDirectory, clipsDirectory] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in items where (try? fm.removeItem(at: item)) != nil {
                removed += 1
            }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? prepareUnsavedDirectory()
        let kept = (try? fm.contentsOfDirectory(at: unsavedDirectory, includingPropertiesForKeys: nil)) ?? []
        for item in kept where UnsavedClipFiles.isPartial(item) && (try? fm.removeItem(at: item)) != nil {
            removed += 1
        }
        return removed
    }

    func availableCapacity() -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

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
