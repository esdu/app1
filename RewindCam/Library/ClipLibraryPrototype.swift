import Foundation

// DISABLED PROTOTYPE for issue #16 ("Evaluate a private clip library on top of durable save recovery").
//
// Nothing in the app constructs or calls anything in this file: it is not on `AppEnvironment`, not
// used by `AppModel`, and not reachable from any view. It exists only so `ClipLibraryPrototypeTests`
// can check, against real files, that a small library could be built on #1's durable store
// (`BufferStorage`, `UnsavedClips/`, `stageForPhotos`) without a second durability implementation.
// Production behaviour is unchanged: Photos-first, and a clip is deleted once Photos accepts it.
// The decision and the proposed follow-up are in docs/decisions/clip-library.md.

/// Who owns a finished clip once Photos has accepted it (docs/decisions/clip-library.md, "Policies").
enum ClipOwnershipPolicy: String, CaseIterable, Sendable {
    /// Today's production behaviour (#1): the app keeps a clip only until Photos has it.
    case recoveryOnly
    /// Photos-first, but the user may choose "Keep locally" for a clip; only that clip is retained.
    case keepLocallyOptIn
    /// Every clip stays in the app; Photos is an optional extra copy.
    case localFirst

    /// Whether a clip that Photos just accepted stays in the app.
    func retainsAfterPhotos(userChoseKeep: Bool) -> Bool {
        switch self {
        case .recoveryOnly: false
        case .keepLocallyOptIn: userChoseKeep
        case .localFirst: true
        }
    }
}

/// A read model and a few explicit operations over #1's records and files. **Disabled prototype.**
///
/// * Clips not yet in Photos are exactly `BufferStorage.unsavedClips()` (finished `.mov` files in
///   `UnsavedClips/`; `*.partial.mov` exports are never listed).
/// * Clips the user chose to keep after Photos accepted them are moved (an atomic rename on the same
///   volume: same inode, same protection class) into `keptDirectory`, outside `UnsavedClips/`, so #1's
///   Retry list keeps meaning "not in Photos yet" and never re-adds a kept clip.
/// * Photos is always handed a disposable hard link (`stageForPhotos`), so `shouldMoveFile` can't
///   remove the copy the app keeps. Sharing uses the same kind of link.
/// * Nothing is ever deleted except by `addToPhotos` under a policy that does not retain (today's
///   behaviour), or by an explicit, confirmed `delete`.
struct ClipLibraryPrototype: Sendable {
    /// The prototype is not wired into the app. Closing #16 does not change this.
    static let isEnabledInApp = false

    enum Status: String, Equatable, Sendable {
        /// In `UnsavedClips/`: the only copy; Photos doesn't have it yet.
        case notInPhotos
        /// In `keptDirectory`: Photos accepted it and the user chose to keep a local copy too.
        case inPhotosKeptLocally
    }

    struct Entry: Equatable, Identifiable, Sendable {
        let url: URL
        let bytes: Int64
        /// When the clip was saved, read from its name (`RewindCam_<date>_<time>[-n].mov`, set once at
        /// commit). Not a file timestamp: reading those is a required-reason API (privacy manifest).
        let createdAt: Date?
        let status: Status

        /// Unique within the library. The name is chosen once, at commit (`commitPartialClip`), and kept
        /// across the move to `keptDirectory` unless that folder already has the name.
        var id: String { "\(status.rawValue)/\(name)" }
        var name: String { url.lastPathComponent }
        /// The same file as #1's record type, so #1's staging helpers apply to it.
        var clip: UnsavedClip { UnsavedClip(url: url, bytes: bytes) }
    }

    enum PhotosOutcome: Equatable, Sendable {
        /// Photos has it and the local copy was deleted (today's behaviour).
        case addedAndRemoved
        /// Photos has it and the local copy is kept (now, or still, in `keptDirectory`).
        case addedAndKept(Entry)
        /// Photos has it, but moving the local copy to `keptDirectory` failed. The clip stays in
        /// `UnsavedClips/` and will be offered again: a possible duplicate in Photos, never a loss.
        case addedButKeepFailed(String)
        /// Photos (or staging) failed. Nothing changed; the local copy is untouched.
        case failed(String)
    }

    /// An explicit delete must name the entry and, for a clip Photos doesn't have, acknowledge that it
    /// is the only copy. A UI would build this from a confirmation dialog.
    struct DeleteConfirmation: Equatable, Sendable {
        let entryID: String
        let acknowledgesOnlyCopy: Bool
    }

    enum DeleteError: Error, Equatable {
        /// The confirmation names a different entry.
        case notConfirmed
        /// The clip isn't in Photos and the confirmation didn't acknowledge losing the only copy.
        case onlyCopyNotAcknowledged
        /// Not a completed clip in the library (already deleted, an export in progress, a staging link…).
        case notInLibrary
    }

    let storage: any BufferStorage
    /// Where clips kept after a successful Photos import live (in the app: next to `UnsavedClips/` in
    /// Application Support). Never inside Caches.
    let keptDirectory: URL
    let policy: ClipOwnershipPolicy

    // MARK: Listing

    /// Completed clips only, sorted by name (names start with the save date). Partial exports,
    /// save jobs and staging links are never listed.
    func entries() -> [Entry] {
        let waiting = storage.unsavedClips().map { entry($0.url, status: .notInPhotos) }
        let kept = Self.finishedClips(in: keptDirectory).map { entry($0, status: .inPhotosKeptLocally) }
        return (waiting + kept).sorted { ($0.name, $0.status.rawValue) < ($1.name, $1.status.rawValue) }
    }

    /// Bytes held by the library, split by status: what #10/#14 would have to count as durable.
    func storageUse() -> (notInPhotos: Int64, keptLocally: Int64) {
        var notInPhotos: Int64 = 0
        var keptLocally: Int64 = 0
        for e in entries() {
            switch e.status {
            case .notInPhotos: notInPhotos += e.bytes
            case .inPhotosKeptLocally: keptLocally += e.bytes
            }
        }
        return (notInPhotos, keptLocally)
    }

    // MARK: Playback and sharing

    /// The file to play (`AVPlayer(url:)` in a UI). Read-only; nothing is copied.
    func playbackURL(for entry: Entry) -> URL { entry.url }

    /// A disposable hard link (a copy if linking fails) in `clipsDirectory/share-<uuid>/`, for a share
    /// sheet. Whatever the receiver does with it can't touch the kept file; launch cleanup removes it.
    func shareItem(for entry: Entry) throws -> URL {
        let dir = storage.clipsDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileProtectionPolicy.prepareDirectory(dir)
        let item = dir.appendingPathComponent(entry.name)
        do {
            try RollingRecorder.linkOrCopy(entry.url, to: item)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return item
    }

    /// Removes a share item's folder once the share sheet is dismissed.
    func discardShareItem(_ item: URL) {
        try? FileManager.default.removeItem(at: item.deletingLastPathComponent())
    }

    // MARK: Photos

    /// Hands Photos a hard link of the clip (`stageForPhotos`). On success, the policy and the user's
    /// choice decide whether the local copy is deleted (today's behaviour) or kept. On failure nothing
    /// changes. A clip already kept locally is never deleted here (a re-add, e.g. after the user removed
    /// it from Photos).
    func addToPhotos(_ entry: Entry, library: any PhotoLibrary, keepLocalCopy: Bool) async -> PhotosOutcome {
        let staged: URL
        do {
            staged = try storage.stageForPhotos(entry.clip)
        } catch {
            return .failed(error.localizedDescription)
        }
        defer { storage.discardStaging(staged) }
        do {
            try await library.saveVideo(at: staged)
        } catch {
            return .failed(error.localizedDescription)
        }
        switch entry.status {
        case .inPhotosKeptLocally:
            return .addedAndKept(entry)
        case .notInPhotos:
            guard policy.retainsAfterPhotos(userChoseKeep: keepLocalCopy) else {
                storage.removeUnsavedClip(entry.clip)
                return .addedAndRemoved
            }
            do {
                return .addedAndKept(try moveToKept(entry))
            } catch {
                return .addedButKeepFailed(error.localizedDescription)
            }
        }
    }

    // MARK: Deletion

    /// What a confirmation dialog would say before deleting `entry`.
    static func deletePrompt(for entry: Entry) -> String {
        switch entry.status {
        case .notInPhotos:
            "This clip isn't in Photos. Deleting it removes the only copy, and it can't be undone."
        case .inPhotosKeptLocally:
            "Deletes RewindCam's copy. The clip stays in Photos."
        }
    }

    /// Deletes a completed clip, and only with a matching confirmation. Throws instead of guessing.
    func delete(_ entry: Entry, confirmation: DeleteConfirmation) throws {
        guard confirmation.entryID == entry.id else { throw DeleteError.notConfirmed }
        // Re-read the library: only a file listed right now (a finished clip in one of the two
        // folders) can be deleted, never a path the caller made up or an export in progress.
        guard let current = entries().first(where: { $0.id == entry.id }) else { throw DeleteError.notInLibrary }
        if current.status == .notInPhotos && !confirmation.acknowledgesOnlyCopy {
            throw DeleteError.onlyCopyNotAcknowledged
        }
        try FileManager.default.removeItem(at: current.url)
    }

    // MARK: Private

    private func entry(_ url: URL, status: Status) -> Entry {
        Entry(url: url, bytes: FileBufferStorage.fileSize(url), createdAt: Self.saveDate(fromName: url.lastPathComponent),
              status: status)
    }

    /// The save date encoded by `ClipExporter.defaultBaseName` (local time, to the second), or nil for
    /// any other name.
    static func saveDate(fromName name: String) -> Date? {
        let prefix = "RewindCam_"
        let stamp = "yyyy-MM-dd_HH-mm-ss"
        guard name.hasPrefix(prefix), name.count >= prefix.count + stamp.count else { return nil }
        let text = String(name.dropFirst(prefix.count).prefix(stamp.count))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'_'HH-mm-ss"
        return f.date(from: text)
    }

    /// Moves a clip from `UnsavedClips/` into `keptDirectory` with a rename (same volume: one atomic
    /// step, same inode, same protection class), never overwriting a kept clip.
    private func moveToKept(_ entry: Entry) throws -> Entry {
        let fm = FileManager.default
        try FileProtectionPolicy.prepareDirectory(keptDirectory, excludedFromBackup: true)
        let base = entry.url.deletingPathExtension().lastPathComponent
        var destination = keptDirectory.appendingPathComponent(entry.name)
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = keptDirectory.appendingPathComponent("\(base)-\(n).mov")
            n += 1
        }
        try fm.moveItem(at: entry.url, to: destination)
        FileProtectionPolicy.apply(to: destination)
        return self.entry(destination, status: .inPhotosKeptLocally)
    }

    private static func finishedClips(in directory: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter(UnsavedClipFiles.isFinished)
    }
}
