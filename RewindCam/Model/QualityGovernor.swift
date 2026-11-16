import Foundation

/// Our own copy of `ProcessInfo.ThermalState` so the policy is testable and `Comparable`.
enum ThermalLevel: Int, Comparable, Sendable, CaseIterable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very hot"
        }
    }
}

/// Pure policy: which preset to actually record at, given the user's choice and heat.
enum QualityGovernor {
    static func effectivePreset(user: QualityPreset, thermal: ThermalLevel) -> QualityPreset {
        switch thermal {
        case .nominal, .fair:
            return user
        case .serious:
            return QualityPreset(resolution: user.resolution.lower ?? user.resolution, frameRate: .fps30)
        case .critical:
            return .lowest
        }
    }

    /// User-facing explanation when the governor lowered quality, else `nil`.
    static func message(user: QualityPreset, effective: QualityPreset, thermal: ThermalLevel) -> String? {
        guard effective != user else { return nil }
        let heat = thermal == .critical ? "Phone is very hot" : "Phone is hot"
        return "\(heat) — recording at \(effective) until it cools down."
    }
}
