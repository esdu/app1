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
    func requestAddAccess() async -> Bool
    /// Takes ownership of the file at `url` (it may be moved).
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
struct FakePhotoLibrary: PhotoLibrary {
    let directory: URL

    static var documents: FakePhotoLibrary {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return FakePhotoLibrary(directory: docs.appendingPathComponent("FakePhotoLibrary", isDirectory: true))
    }

    func requestAddAccess() async -> Bool { true }

    func saveVideo(at url: URL) async throws {
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
