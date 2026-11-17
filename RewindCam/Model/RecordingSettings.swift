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

/// Persistence boundary for settings (mocked in tests with an isolated suite). It also keeps the one
/// piece of screen state that has to outlive the process: the brightness Dim must put back (issue #38).
protocol SettingsStore: AnyObject {
    func load() -> RecordingSettings
    func save(_ settings: RecordingSettings)
    /// What Dim must put back (issue #38). Written just before the system brightness goes down, cleared
    /// (`nil`) once it is back, so a value found at launch means the last run ended while dimmed (kill,
    /// crash, memory pressure) and the screen may still be dark (`AppModel`, "Dim").
    func loadDimRestore() -> DimRestore?
    func saveDimRestore(_ restore: DimRestore?)
}

/// The brightness Dim must put back, and the level the screen reported once dimmed.
struct DimRestore: Equatable, Sendable {
    /// The screen brightness from before Dim lowered it (0...1).
    var brightness: Double
    /// What the screen read back after Dim set `AppModel.dimmedBrightness` (a device may clamp or round
    /// it). "Still dimmed" means the screen is still at this level. nil until read, or if what was stored
    /// can't be read: `AppModel.dimmedBrightness` itself stands in.
    var dimmedReadBack: Double?
}

final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key: String
    private let dimRestoreKey: String
    private let dimReadBackKey: String

    init(defaults: UserDefaults = .standard, key: String = "recordingSettings.v1",
         dimRestoreKey: String = "dimRestoreBrightness.v1",
         dimReadBackKey: String = "dimRestoreDimmedReadBack.v1") {
        self.defaults = defaults
        self.key = key
        self.dimRestoreKey = dimRestoreKey
        self.dimReadBackKey = dimReadBackKey
    }

    func loadDimRestore() -> DimRestore? {
        guard let brightness = brightnessValue(forKey: dimRestoreKey) else { return nil }
        return DimRestore(brightness: brightness, dimmedReadBack: brightnessValue(forKey: dimReadBackKey))
    }

    func saveDimRestore(_ restore: DimRestore?) {
        if let restore {
            defaults.set(restore.brightness, forKey: dimRestoreKey)
            if let readBack = restore.dimmedReadBack {
                defaults.set(readBack, forKey: dimReadBackKey)
            } else {
                defaults.removeObject(forKey: dimReadBackKey)
            }
        } else {
            defaults.removeObject(forKey: dimRestoreKey)
            defaults.removeObject(forKey: dimReadBackKey)
        }
    }

    /// A stored brightness, or nil if missing, not a number or outside 0...1.
    private func brightnessValue(forKey key: String) -> Double? {
        guard let value = defaults.object(forKey: key) as? Double, value.isFinite, (0...1).contains(value)
        else { return nil }
        return value
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
