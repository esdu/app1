/// A persistent problem the user should know about, with at most one action that fixes it.
/// `AppModel` derives notices from its state; `NoticeBanner` (ContentView) renders them.
///
/// Issue #3 adds the microphone notice (`AppModel.microphoneNotice`); issue #8 adds the start-failure
/// notice (`AppModel.startFailureNotice`: camera denied → `.openSettings`, other failures → `.tryAgain`).
/// Issue #15 adds the user-pause notice (`AppModel.userPausedNotice`, `.info`, no action).
/// There is one "go to Settings" path and one banner for all of them.
struct AppNotice: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// "Open Settings": opens RewindCam's page in the Settings app via `AppModel.openAppSettings()`.
        /// The button's accessibility identifier is `openSettingsButton`.
        case openSettings
        /// "Try Again": re-runs the normal start pipeline via `AppModel.retryStart()`.
        /// The button's accessibility identifier is `tryAgainButton`.
        case tryAgain
    }

    enum Severity: Equatable, Sendable {
        /// Nothing is wrong: a state the user chose, e.g. their own pause (issue #15) (blue).
        case info
        /// Recording works, but not as the user asked (orange).
        case warning
        /// Recording doesn't work (red).
        case error
    }

    /// Accessibility identifier of the banner; UI tests find the action button inside it.
    let id: String
    let systemImage: String
    let title: String
    let message: String
    let severity: Severity
    let action: Action?
}

extension AppNotice.Action {
    var title: String {
        switch self {
        case .openSettings: "Open Settings"
        case .tryAgain: "Try Again"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .openSettings: "openSettingsButton"
        case .tryAgain: "tryAgainButton"
        }
    }
}
