import Foundation
import Photos

enum PhotoLibraryError: LocalizedError {
    case accessDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied: "RewindCam can't add to Photos. Allow it in Settings › RewindCam › Photos."
        case .saveFailed(let why): "Couldn't save to Photos: \(why)"
        }
    }
}

/// Destination for finished clips. The real one uses add-only Photos access.
protocol PhotoLibrary: Sendable {
    /// Asks for add-only access if it hasn't been decided yet. The app calls this at launch, before
    /// the first save, so the system prompt never decides the fate of a clip.
    func requestAddAccess() async -> Bool
    /// Takes ownership of the file at `url` (it may be moved, even if the call fails). `AppModel`
    /// passes a disposable hard link (`BufferStorage.stageForPhotos`), never the only copy.
    func saveVideo(at url: URL) async throws
}

struct SystemPhotoLibrary: PhotoLibrary {
    func requestAddAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited: return true
        case .notDetermined:
            let s = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return s == .authorized || s == .limited
        default: return false
        }
    }

    func saveVideo(at url: URL) async throws {
        guard await requestAddAccess() else { throw PhotoLibraryError.accessDenied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
            }
        } catch {
            throw PhotoLibraryError.saveFailed(error.localizedDescription)
        }
    }
}

/// Used by `-UITestMode` and unit tests: "Photos" is a folder in Documents.
/// It can be told to deny access or to fail the next saves, to exercise the keep-and-retry path.
struct FakePhotoLibrary: PhotoLibrary {
    private struct State {
        var denied = false
        var failures: [String] = []
        var accessRequests = 0
    }

    let directory: URL
    private let state = Locked(State())

    init(directory: URL) {
        self.directory = directory
    }

    static var documents: FakePhotoLibrary {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return FakePhotoLibrary(directory: docs.appendingPathComponent("FakePhotoLibrary", isDirectory: true))
    }

    /// Behaves like a user who chose "Don't Allow" (or access is restricted).
    func setDenied(_ denied: Bool) { state.withLock { $0.denied = denied } }

    /// The next `messages.count` saves throw `saveFailed(message)`, in order.
    func failNextSaves(_ messages: [String]) { state.withLock { $0.failures = messages } }

    /// How many times the app asked for add access.
    var accessRequests: Int { state.withLock { $0.accessRequests } }

    func requestAddAccess() async -> Bool {
        state.withLock { (s: inout State) -> Bool in
            s.accessRequests += 1
            return !s.denied
        }
    }

    func saveVideo(at url: URL) async throws {
        let failure = state.withLock { (s: inout State) -> PhotoLibraryError? in
            if s.denied { return .accessDenied }
            if !s.failures.isEmpty { return .saveFailed(s.failures.removeFirst()) }
            return nil
        }
        if let failure { throw failure }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        try fm.moveItem(at: url, to: dest)
    }

    func clips() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "mov" }.sorted { $0.path < $1.path }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
