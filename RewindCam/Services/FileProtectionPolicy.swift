import Foundation

/// The one place that decides the Data Protection class of RewindCam's media files.
/// See DESIGN.md §2, "File protection and backup".
///
/// Every media file (buffer, save jobs, Photos staging, unsaved clips) uses
/// `completeUntilFirstUserAuthentication`: readable and writable after the first unlock since boot,
/// including while the phone is locked. This is the iOS default, stated explicitly so a future
/// app-wide default (the Data Protection entitlement) can't silently make saves fail after a lock.
///
/// Not `.complete` or `.completeUnlessOpen`: a save that started before the lock keeps running in
/// background time, and after the lock it reopens the buffered segments, creates and reopens the
/// concatenated source, writes and reopens the export, and hands the clip to Photos. With `.complete`
/// every one of those fails about 10 s after the lock; with `.completeUnlessOpen` reopening a closed file does.
///
/// Applying the class is best effort and never blocks a save: if setting it fails, the file keeps the
/// platform default, which is the same class unless the app's default is changed. The Simulator does not
/// enforce Data Protection.
enum FileProtectionPolicy {
    /// The class for every file and folder RewindCam creates for media.
    static var media: URLFileProtection { .completeUntilFirstUserAuthentication }

    /// The same class as `FileManager` attributes spell it (`URLFileProtection` and `FileProtectionType`
    /// are distinct types with different raw strings).
    static var mediaFileProtectionType: FileProtectionType { .completeUntilFirstUserAuthentication }

    /// `FileManager` attributes that request `media`.
    static var attributes: [FileAttributeKey: Any] { [.protectionKey: mediaFileProtectionType] }

    /// Creates `directory` (and any missing parents) and sets `media` on it, so files created inside
    /// inherit it. Re-applied on every call (idempotent). With `excludedFromBackup`, also marks it
    /// excluded from iCloud/Finder backup; that flag can be reset by some file operations, so callers
    /// re-apply it before each use. Only directory creation can throw.
    static func prepareDirectory(_ directory: URL, excludedFromBackup: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        apply(to: directory)
        if excludedFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var dir = directory
            try? dir.setResourceValues(values)
        }
    }

    /// Sets `media` on an existing file or folder: one created by a copy (a new inode, which does not
    /// reliably inherit its folder's class), by a framework such as `AVAssetExportSession`, or by an
    /// atomic write (a temporary file renamed into place). A hard link shares its inode, and with it the
    /// class, with the original: setting it through either name changes both.
    /// Returns false if the file system refused; the file then keeps the class it had.
    @discardableResult
    static func apply(to url: URL) -> Bool {
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Copies `source` to `destination` and sets `media` on the copy.
    static func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        apply(to: destination)
    }

    /// The class the file system reports for `url`, read fresh (not from a cached resource value).
    /// nil where the volume does not report Data Protection.
    static func observedProtection(of url: URL) -> URLFileProtection? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.fileProtectionKey]))?.fileProtection
    }
}
