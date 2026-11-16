import Foundation

/// Where the rolling buffer and in-flight clips live; mocked with temp dirs in tests.
protocol BufferStorage: Sendable {
    var bufferDirectory: URL { get }
    var clipsDirectory: URL { get }
    /// Deletes everything left over from a previous process. Returns the number of items removed.
    @discardableResult func removeOrphans() -> Int
    func availableCapacity() -> Int64?
}

struct FileBufferStorage: BufferStorage {
    let root: URL

    static var caches: FileBufferStorage {
        FileBufferStorage(root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    }

    var bufferDirectory: URL { root.appendingPathComponent("RewindBuffer", isDirectory: true) }
    var clipsDirectory: URL { root.appendingPathComponent("RewindClips", isDirectory: true) }

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
