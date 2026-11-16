import Foundation

/// Wall-clock time source, injectable for tests.
protocol WallClock: Sendable {
    func now() -> Date
}

struct SystemWallClock: WallClock {
    func now() -> Date { Date() }
}

final class FakeWallClock: WallClock, @unchecked Sendable {
    private let time: Locked<Date>
    init(_ start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) { time = Locked(start) }
    func now() -> Date { time.current }
    func advance(by seconds: TimeInterval) { time.withLock { $0 += seconds } }
}

/// Measures battery drain (% per hour) over the current recording session, so the cost of
/// features like the voice trigger can be read off on a real device. Restarts whenever
/// the phone is charging or the measured configuration changes.
struct BatteryDrainMeter: Equatable {
    struct Sample: Equatable {
        let date: Date
        let level: Float
    }

    static let minimumDuration: TimeInterval = 10 * 60

    private(set) var configuration: String = ""
    private(set) var start: Sample?
    private(set) var latest: Sample?

    mutating func reset(configuration: String) {
        self.configuration = configuration
        start = nil
        latest = nil
    }

    mutating func record(level: Float?, isCharging: Bool, at date: Date) {
        guard let level, !isCharging else {
            start = nil
            latest = nil
            return
        }
        let sample = Sample(date: date, level: level)
        if start == nil { start = sample }
        latest = sample
    }

    var elapsed: TimeInterval {
        guard let start, let latest else { return 0 }
        return latest.date.timeIntervalSince(start.date)
    }

    /// Percentage points per hour, once at least `minimumDuration` has been observed.
    var percentPerHour: Double? {
        guard let start, let latest, elapsed >= Self.minimumDuration else { return nil }
        return Double(start.level - latest.level) * 100 / (elapsed / 3600)
    }

    var summary: String {
        guard start != nil else { return "Measuring starts when the phone is unplugged." }
        let minutes = Int(elapsed / 60)
        guard let rate = percentPerHour else { return "Measuring… \(minutes) min so far (needs 10 min)." }
        return String(format: "%.1f %%/h over %d min (%@)", rate, minutes, configuration)
    }
}
