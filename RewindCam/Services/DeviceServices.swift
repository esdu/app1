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
    /// A screen that doesn't report exactly what was set (a clamped minimum, rounding; issue #38): every
    /// set stores `readBack(newValue)`. nil: what is set is what reads back.
    var readBack: (@MainActor (CGFloat) -> CGFloat)?
    private var level: CGFloat = 0.6
    var brightness: CGFloat {
        get { level }
        set { level = readBack?(newValue) ?? newValue }
    }
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

/// How urgently VoiceOver should speak an announcement.
enum AnnouncementPriority: Equatable, Sendable {
    /// Queued behind what VoiceOver is saying (save results, recoveries, warnings).
    case normal
    /// Interrupts and can't be interrupted: recording stopped, a save failed.
    case high
}

/// Speaks save results and state changes to VoiceOver users (issue #11; DESIGN.md "Accessibility").
/// `AppModel` calls it for every toast and, once per change, for phase changes and new warnings
/// (`AppModel.announceChanges()`), never on every status tick. Live: `UIAccessibility.post`
/// (`.announcement`); tests: `FakeAccessibilityAnnouncer` records what would have been spoken.
@MainActor
protocol AccessibilityAnnouncer: AnyObject {
    func announce(_ message: String, priority: AnnouncementPriority)
}

@MainActor
final class SystemAccessibilityAnnouncer: AccessibilityAnnouncer {
    func announce(_ message: String, priority: AnnouncementPriority) {
        // Without VoiceOver (or another assistive technology) the notification is simply ignored.
        let level: UIAccessibilityPriority = priority == .high ? .high : .default
        let text = NSAttributedString(string: message, attributes: [
            .accessibilitySpeechAnnouncementPriority: level.rawValue,
        ])
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

@MainActor
final class FakeAccessibilityAnnouncer: AccessibilityAnnouncer {
    struct Announcement: Equatable {
        let message: String
        let priority: AnnouncementPriority
    }

    private(set) var announcements: [Announcement] = []
    var messages: [String] { announcements.map(\.message) }

    func announce(_ message: String, priority: AnnouncementPriority) {
        announcements.append(Announcement(message: message, priority: priority))
    }

    func removeAll() { announcements.removeAll() }
}

/// Opens RewindCam's own page in the Settings app, where the user can allow the camera, microphone or
/// Photos. Reached through `AppModel.openAppSettings()`, which every "Open Settings" button calls
/// (`NoticeBanner`). Live: `UIApplication.openSettingsURLString`; tests: `FakeAppSettingsOpener`.
@MainActor
protocol AppSettingsOpener: AnyObject {
    func openAppSettings()
}

@MainActor
final class SystemAppSettingsOpener: AppSettingsOpener {
    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

@MainActor
final class FakeAppSettingsOpener: AppSettingsOpener {
    private(set) var openCount = 0
    func openAppSettings() { openCount += 1 }
}

/// Handle for one background-task assertion. Ending it twice is harmless.
struct BackgroundTaskToken: Hashable, Sendable {
    let id: Int
}

/// Asks iOS for extra time to finish work (export + Photos save) after the app leaves the screen.
/// Live: `UIApplication.beginBackgroundTask`; tests: `FakeBackgroundTasks` counts begin/end pairs.
@MainActor
protocol BackgroundTasks: AnyObject {
    func begin(name: String) -> BackgroundTaskToken
    func end(_ token: BackgroundTaskToken)
}

@MainActor
final class SystemBackgroundTasks: BackgroundTasks {
    private var identifiers: [BackgroundTaskToken: UIBackgroundTaskIdentifier] = [:]
    private var nextID = 0

    func begin(name: String) -> BackgroundTaskToken {
        nextID += 1
        let token = BackgroundTaskToken(id: nextID)
        // If time runs out, iOS requires the assertion to be ended before the handler returns.
        // The work itself carries on until the app is suspended; a clip that was already renamed
        // to `.mov` survives that (see DESIGN.md §2, "Save path").
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end(token) }
        }
        if identifier != .invalid {
            identifiers[token] = identifier
        }
        return token
    }

    func end(_ token: BackgroundTaskToken) {
        guard let identifier = identifiers.removeValue(forKey: token) else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

@MainActor
final class FakeBackgroundTasks: BackgroundTasks {
    private(set) var begun = 0
    private(set) var ended = 0
    private(set) var names: [String] = []
    private var active: Set<BackgroundTaskToken> = []
    private var nextID = 0

    /// Assertions begun and not yet ended.
    var activeCount: Int { active.count }

    func begin(name: String) -> BackgroundTaskToken {
        nextID += 1
        let token = BackgroundTaskToken(id: nextID)
        begun += 1
        names.append(name)
        active.insert(token)
        return token
    }

    /// Counts only the first end of each token, like the live implementation.
    func end(_ token: BackgroundTaskToken) {
        if active.remove(token) != nil { ended += 1 }
    }
}
