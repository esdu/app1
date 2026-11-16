import Foundation

enum VideoResolution: String, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case uhd4K = "4K"

    var id: String { rawValue }
    var label: String { rawValue }

    /// Sensor-native (landscape) dimensions.
    var dimensions: (width: Int32, height: Int32) {
        switch self {
        case .hd720: (1280, 720)
        case .hd1080: (1920, 1080)
        case .uhd4K: (3840, 2160)
        }
    }

    /// One step down, or `nil` when already at the lowest resolution.
    var lower: VideoResolution? {
        switch self {
        case .hd720: nil
        case .hd1080: .hd720
        case .uhd4K: .hd1080
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

enum FrameRate: Int, Codable, CaseIterable, Sendable, Identifiable {
    case fps30 = 30
    case fps60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}

enum CameraPosition: String, Codable, CaseIterable, Sendable, Identifiable {
    case back, front
    var id: String { rawValue }
    var label: String { self == .back ? "Back" : "Front" }
}

struct QualityPreset: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    var resolution: VideoResolution
    var frameRate: FrameRate

    static let lowest = QualityPreset(resolution: .hd720, frameRate: .fps30)

    var description: String { "\(resolution.label) \(frameRate.label)" }

    /// Target H.264 average bitrate (bits/s). Pinned so disk use is predictable (see DESIGN.md).
    var videoBitrate: Int {
        switch (resolution, frameRate) {
        case (.hd720, .fps30): 5_000_000
        case (.hd720, .fps60): 7_500_000
        case (.hd1080, .fps30): 10_000_000
        case (.hd1080, .fps60): 15_000_000
        case (.uhd4K, .fps30): 35_000_000
        case (.uhd4K, .fps60): 50_000_000
        }
    }
}

struct RecordingSettings: Codable, Equatable, Sendable {
    static let bufferChoices = [15, 30, 60, 90, 120]
    static let postRollChoices = [0, 5, 10, 30]

    var bufferSeconds: Int = 30
    var postRollSeconds: Int = 0
    var resolution: VideoResolution = .hd1080
    var frameRate: FrameRate = .fps30
    var audioEnabled: Bool = true
    var camera: CameraPosition = .back
    var voiceTriggerEnabled: Bool = false

    var preset: QualityPreset { QualityPreset(resolution: resolution, frameRate: frameRate) }

    init() {}

    // Tolerant decoding: unknown/missing keys fall back to defaults so an app
    // update never wipes the user's other settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingSettings()
        bufferSeconds = (try? c.decode(Int.self, forKey: .bufferSeconds)).flatMap {
            Self.bufferChoices.contains($0) ? $0 : nil } ?? d.bufferSeconds
        postRollSeconds = (try? c.decode(Int.self, forKey: .postRollSeconds)).flatMap {
            Self.postRollChoices.contains($0) ? $0 : nil } ?? d.postRollSeconds
        resolution = (try? c.decode(VideoResolution.self, forKey: .resolution)) ?? d.resolution
        frameRate = (try? c.decode(FrameRate.self, forKey: .frameRate)) ?? d.frameRate
        audioEnabled = (try? c.decode(Bool.self, forKey: .audioEnabled)) ?? d.audioEnabled
        camera = (try? c.decode(CameraPosition.self, forKey: .camera)) ?? d.camera
        voiceTriggerEnabled = (try? c.decode(Bool.self, forKey: .voiceTriggerEnabled)) ?? d.voiceTriggerEnabled
    }
}

/// Persistence boundary for settings (mocked in tests with an isolated suite).
protocol SettingsStore: AnyObject {
    func load() -> RecordingSettings
    func save(_ settings: RecordingSettings)
}

final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "recordingSettings.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> RecordingSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(RecordingSettings.self, from: data)
        else { return RecordingSettings() }
        return settings
    }

    func save(_ settings: RecordingSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
