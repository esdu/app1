import Foundation
import UIKit

/// Thermal state source. Live: `ProcessInfo.thermalState`; tests: `FakeThermalMonitor`.
@MainActor
protocol ThermalMonitor: AnyObject {
    var level: ThermalLevel { get }
    var onChange: ((ThermalLevel) -> Void)? { get set }
}

@MainActor
final class SystemThermalMonitor: ThermalMonitor {
    private(set) var level = ThermalLevel(ProcessInfo.processInfo.thermalState)
    var onChange: ((ThermalLevel) -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let state = ThermalLevel(ProcessInfo.processInfo.thermalState)
            Task { @MainActor in self.update(state) }
        }
    }

    private func update(_ new: ThermalLevel) {
        guard new != level else { return }
        level = new
        onChange?(new)
    }
}

@MainActor
final class FakeThermalMonitor: ThermalMonitor {
    private(set) var level: ThermalLevel
    var onChange: ((ThermalLevel) -> Void)?
    init(_ level: ThermalLevel = .nominal) { self.level = level }
    func set(_ new: ThermalLevel) {
        level = new
        onChange?(new)
    }
}

@MainActor
protocol BatteryMonitor: AnyObject {
    /// 0...1, or nil when unknown (Simulator).
    var level: Float? { get }
    var isCharging: Bool { get }
}

@MainActor
final class SystemBatteryMonitor: BatteryMonitor {
    init() { UIDevice.current.isBatteryMonitoringEnabled = true }
    var level: Float? {
        let l = UIDevice.current.batteryLevel
        return l < 0 ? nil : l
    }
    var isCharging: Bool {
        let s = UIDevice.current.batteryState
        return s == .charging || s == .full
    }
}

@MainActor
final class FakeBatteryMonitor: BatteryMonitor {
    var level: Float?
    var isCharging = false
    init(level: Float? = nil) { self.level = level }
}

/// Screen brightness + idle timer (long-session mode).
@MainActor
protocol ScreenController: AnyObject {
    var brightness: CGFloat { get set }
    func setIdleTimerDisabled(_ disabled: Bool)
}

@MainActor
final class SystemScreenController: ScreenController {
    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }
    var brightness: CGFloat {
        get { screen?.brightness ?? 1 }
        set { screen?.brightness = newValue }
    }
    func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

@MainActor
final class FakeScreenController: ScreenController {
    var brightness: CGFloat = 0.6
    private(set) var idleTimerDisabled = false
    func setIdleTimerDisabled(_ disabled: Bool) { idleTimerDisabled = disabled }
}

@MainActor
protocol Haptics: AnyObject {
    func success()
    func failure()
}

@MainActor
final class SystemHaptics: Haptics {
    private let generator = UINotificationFeedbackGenerator()
    func success() { generator.notificationOccurred(.success) }
    func failure() { generator.notificationOccurred(.error) }
}

@MainActor
final class FakeHaptics: Haptics {
    private(set) var successes = 0
    private(set) var failures = 0
    func success() { successes += 1 }
    func failure() { failures += 1 }
}
