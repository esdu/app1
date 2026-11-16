/// A persistent problem the user should know about, with at most one action that fixes it.
/// `AppModel` derives notices from its state; `NoticeBanner` (ContentView) renders them.
///
/// Issue #3 adds the microphone notice (`AppModel.microphoneNotice`). Camera denied (#8) is meant to
/// reuse this type, the banner and `.openSettings` (adding a `.tryAgain` action for other start
/// failures), rather than adding a second "go to Settings" path.
struct AppNotice: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// "Open Settings": opens RewindCam's page in the Settings app via `AppModel.openAppSettings()`.
        /// The button's accessibility identifier is `openSettingsButton`.
        case openSettings
    }

    enum Severity: Equatable, Sendable {
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
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .openSettings: "openSettingsButton"
        }
    }
}
