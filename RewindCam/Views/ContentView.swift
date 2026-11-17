import SwiftUI

// Accessibility (issue #11; DESIGN.md "Accessibility"):
// * Every text uses a text style and scales with Dynamic Type. Where a fixed shape has to hold it (the
//   status pills, the round icon buttons, the Save circle) the size is capped at an accessibility size
//   and the element shows the large content viewer; everything else scales freely.
// * The banner stack scrolls when it doesn't fit (`BannerArea`), so at the largest sizes it never
//   pushes the Save row off screen or overlaps it.
// * Text sits on a dark base (scrims, black pill and banner backgrounds), so it keeps at least 4.5:1
//   contrast over any footage; button fills are darkened system colours with white text (≥ 5:1).
// * VoiceOver: one element per pill, banner text and toast, with labels that read as sentences;
//   buttons stay separately focusable; state changes and save results are announced by `AppModel`.

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.supportsCaptureButtons {
                CaptureButtonsInteraction { model.save(trigger: .volumeButton) }
                    .ignoresSafeArea()
            }

            PreviewSurface(model: model)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // Scrims keep the controls legible over any footage.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 300)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(spacing: 10) {
                StatusBar()
                    .fixedSize(horizontal: false, vertical: true)
                // Takes the room left by the fixed-height rows first, and scrolls when that's not enough.
                BannerArea()
                    .layoutPriority(1)
                Spacer(minLength: 0)
                ToastView()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Controls(showSettings: $showSettings)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Keep RewindCam open — iOS can't record in the background.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    // A reminder, not news: capped so it can't crowd out the banners at the largest sizes.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("backgroundNotice")
                if model.isUITest {
                    Text("Fake library: \(model.fakeLibraryCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .accessibilityIdentifier("fakeLibraryCount")
                        .accessibilityValue("\(model.fakeLibraryCount)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            // While dimmed, VoiceOver reaches only the overlay (wake, or its Save action), not the
            // controls hidden under it.
            .accessibilityHidden(model.isDimmed)

            if model.isDimmed {
                DimOverlay()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(model)
        }
    }
}

/// Text-on-colour fills that keep white text at ≥ 4.5:1 (the system red, orange and blue don't).
enum ContrastPalette {
    static let red = Color(red: 0.75, green: 0.10, blue: 0.10)
    static let orange = Color(red: 0.66, green: 0.31, blue: 0.0)
    static let blue = Color(red: 0.0, green: 0.35, blue: 0.80)
    /// Disabled Save: dark enough for its white "not recording" subtitle over bright footage.
    static let disabledFill = Color(white: 0.12).opacity(0.92)
}

private struct StatusBar: View {
    var body: some View {
        // One row when it fits; at large text sizes two rows (state + battery, then buffer + quality).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                RecordingBadge()
                Spacer(minLength: 4)
                BufferPill()
                PresetPill()
                BatteryLabel()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    RecordingBadge()
                    Spacer(minLength: 4)
                    BatteryLabel()
                }
                HStack(spacing: 8) {
                    BufferPill()
                    PresetPill()
                    Spacer(minLength: 0)
                }
            }
        }
        .font(.footnote.weight(.semibold).monospacedDigit())
        // Pills hold one line each. A long phase label ("STARTING") shrinks a little instead of wrapping.
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .foregroundStyle(.white)
        // Capped: a status bar can't grow without bound. Long-press shows the large content viewer.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.top, 4)
    }
}

private struct BufferPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let seconds = model.settings.bufferSeconds
        Text("Buffer \(seconds) s")
            .pill()
            .accessibilityLabel("Buffer length \(seconds) seconds")
            .accessibilityShowsLargeContentViewer()
            .accessibilityIdentifier("bufferLabel")
    }
}

private struct PresetPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preset = model.activePreset
        let lowered = preset != model.settings.preset
        Text(preset.description)
            .pill()
            .accessibilityLabel("\(preset.resolution.label), \(preset.frameRate.rawValue) frames per second"
                + (lowered ? ", lowered while the phone is hot" : ""))
            .accessibilityShowsLargeContentViewer()
            .accessibilityIdentifier("presetLabel")
    }
}

private struct RecordingBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recording = model.phase == .recording
        HStack(spacing: 6) {
            if model.phase == .userPaused {
                Image(systemName: "pause.fill")
                    .font(.caption2)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(recording ? Color.red : Color.gray)
                    .frame(width: 10, height: 10)
            }
            Text(recording ? "REC \(model.readySeconds) s" : phaseLabel)
        }
        .pill()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(recording ? Self.secondsReady(model.readySeconds) : "")
        .accessibilityAddTraits(recording ? .updatesFrequently : [])
        .accessibilityShowsLargeContentViewer {
            Label(recording ? "REC \(model.readySeconds) s" : phaseLabel,
                  systemImage: model.phase == .userPaused ? "pause.fill" : "record.circle")
        }
        .accessibilityIdentifier("recordingBadge")
    }

    static func secondsReady(_ seconds: Int) -> String {
        seconds == 1 ? "1 second ready" : "\(seconds) seconds ready"
    }

    /// What VoiceOver reads: words, not the badge's abbreviations ("REC", "OFF").
    private var accessibilityLabel: String {
        switch model.phase {
        case .idle: "Not recording"
        case .starting: "Starting"
        case .recording: "Recording"
        case .paused: "Recording paused"
        case .cameraDenied: "Not recording, camera access is off"
        case .failed: "Not recording, camera error"
        case .outOfSpace: "Not recording, not enough free space"
        // Not to be confused with an interruption's PAUSED (issue #15).
        case .userPaused: "Paused by you"
        }
    }

    private var phaseLabel: String {
        switch model.phase {
        case .idle: "IDLE"
        case .starting: "STARTING"
        case .recording: "REC"
        case .paused: "PAUSED"
        case .cameraDenied: "OFF"
        case .failed: "ERROR"
        case .outOfSpace: "NO SPACE"
        case .userPaused: "PAUSED"
        }
    }
}

private struct BatteryLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let level = model.batteryLevel
        let percent = level.map { Int(($0 * 100).rounded()) }
        HStack(spacing: 3) {
            Image(systemName: symbol(level))
            // Unknown (Simulator): the icon alone; VoiceOver says "Battery level unknown".
            if let percent {
                Text("\(percent)%")
            }
        }
        .pill()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent.map { "Battery \($0) percent" + (model.isCharging ? ", charging" : "") }
            ?? "Battery level unknown")
        .accessibilityShowsLargeContentViewer {
            Label(percent.map { "\($0)%" } ?? "Battery level unknown", systemImage: symbol(level))
        }
        .accessibilityIdentifier("batteryLabel")
    }

    private func symbol(_ level: Float?) -> String {
        if model.isCharging { return "battery.100percent.bolt" }
        guard let level else { return "battery.50percent" }
        switch level {
        case ..<0.15: return "battery.0percent"
        case ..<0.4: return "battery.25percent"
        case ..<0.65: return "battery.50percent"
        case ..<0.9: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// The banners at their natural height when they fit; otherwise a scroll view in the room that is left
/// (large text, or several banners at once), so they never run into the Save row.
private struct BannerArea: View {
    var body: some View {
        ViewThatFits(in: .vertical) {
            Banners()
            ScrollView {
                Banners()
            }
            .scrollBounceBehavior(.basedOnSize)
            // Shows there is more to read below the visible banners.
            .scrollIndicatorsFlash(onAppear: true)
            .accessibilityIdentifier("bannerScroll")
        }
    }
}

private struct Banners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            if let message = model.thermalMessage {
                Banner(icon: "thermometer.high", text: message, tint: .orange)
                    .accessibilityIdentifier("thermalBanner")
            }
            // The user paused (issue #15): what that means, and that it lasts until Resume.
            if let notice = model.userPausedNotice {
                NoticeBanner(notice: notice)
            }
            if case .paused(let why) = model.phase {
                Banner(icon: "pause.circle.fill", text: why + " The buffer was cleared.", tint: .yellow)
                    .accessibilityIdentifier("pausedBanner")
            }
            // Camera denied (Open Settings) or another start failure (Try Again).
            if let notice = model.startFailureNotice {
                NoticeBanner(notice: notice)
            }
            // Video stopped and the camera was restarted on its own (frame watchdog, issue #9).
            if let notice = model.stallNotice {
                NoticeBanner(notice: notice)
            }
            // Recording, but free space is low enough that a save may not fit (issue #10).
            if let notice = model.diskSpaceNotice {
                NoticeBanner(notice: notice)
            }
            if let error = model.status.lastError {
                Banner(icon: "exclamationmark.circle", text: error, tint: .red)
            }
            if let notice = model.microphoneNotice {
                NoticeBanner(notice: notice)
            }
            if !model.unsavedClips.isEmpty {
                UnsavedClipsBanner()
            } else if model.photosAccessGranted == false {
                Banner(icon: "photo.badge.exclamationmark", text: AppModel.photosDeniedHint, tint: .orange)
                    .accessibilityIdentifier("photosDeniedBanner")
            }
        }
    }
}

/// Renders an `AppNotice`: icon, title, message and its action button (e.g. **Open Settings**).
/// Reusable for any notice; the banner's identifier is `notice.id`, the button's is
/// `notice.action.accessibilityIdentifier` (`openSettingsButton`). VoiceOver reads the title and
/// message as one element (the icon is decorative), and the button is a separate element.
struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    let notice: AppNotice

    var body: some View {
        let tint: Color = switch notice.severity {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
        let buttonFill: Color = switch notice.severity {
        case .error: ContrastPalette.red
        case .warning: ContrastPalette.orange
        case .info: ContrastPalette.blue
        }
        BannerLayout {
            Image(systemName: notice.systemImage)
                .accessibilityHidden(true)
        } text: {
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .fontWeight(.semibold)
                Text(notice.message)
                    .font(.caption)
            }
        } button: {
            if let action = notice.action {
                Button {
                    perform(action)
                } label: {
                    Text(action.title)
                        .fontWeight(.bold)
                }
                .bannerButton(fill: buttonFill)
                .accessibilityIdentifier(action.accessibilityIdentifier)
            }
        }
        .bannerBackground(tint)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(notice.id)
    }

    private func perform(_ action: AppNotice.Action) {
        switch action {
        case .openSettings: model.openAppSettings()
        case .tryAgain: model.retryStart()
        }
    }
}

/// Clips that were exported but haven't reached Photos (denied, failed, or interrupted). Kept on disk
/// until Retry succeeds.
private struct UnsavedClipsBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.unsavedClips.count
        BannerLayout {
            Image(systemName: "tray.and.arrow.up.fill")
                .accessibilityHidden(true)
        } text: {
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? "1 clip isn't in Photos yet." : "\(count) clips aren't in Photos yet.")
                    .fontWeight(.semibold)
                if let problem = model.photosProblem {
                    Text(problem)
                        .font(.caption)
                }
            }
        } button: {
            Button {
                model.retryUnsavedClips()
            } label: {
                if model.isRetryingUnsaved {
                    ProgressView().tint(.white)
                } else {
                    Text("Retry").fontWeight(.bold)
                }
            }
            .bannerButton(fill: ContrastPalette.orange)
            .disabled(model.isRetryingUnsaved)
            .accessibilityLabel("Retry saving to Photos")
            .accessibilityValue(model.isRetryingUnsaved ? "In progress" : "")
            .accessibilityIdentifier("retryUnsavedButton")
        }
        .bannerBackground(.orange)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unsavedBanner")
    }
}

/// Icon, text and an optional button side by side; at accessibility text sizes the button goes under
/// the text, so a long button title ("Open Settings") can't squeeze the text into a sliver.
private struct BannerLayout<Icon: View, Content: View, Action: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let icon: Icon
    let text: Content
    let button: Action

    init(@ViewBuilder icon: () -> Icon, @ViewBuilder text: () -> Content, @ViewBuilder button: () -> Action) {
        self.icon = icon()
        self.text = text()
        self.button = button()
    }

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(alignment: .top, spacing: 10) {
                icon
                text
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
            button
        }
    }
}

private struct Banner: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .bannerBackground(tint)
            .accessibilityElement(children: .combine)
    }
}

private struct ToastView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            if let toast = model.toast {
                Label(toast.message, systemImage: toast.isError ? "xmark.octagon.fill"
                      : toast.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22)
                        .stroke(toast.isError ? Color.red : toast.isWarning ? Color.orange : Color.green,
                                lineWidth: 1.5))
                    // The toast is spoken by `AppModel.showToast`; this keeps it readable at the largest
                    // sizes without taking the whole screen.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("toast")
                    .id(toast.id)
                    .transition(.opacity)
            }
        }
        // A short cross-fade, and none at all with Reduce Motion.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.toast?.id)
    }
}

private struct Controls: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    /// The Save circle grows with the text inside it, up to a size that still fits beside the two round
    /// buttons on the smallest supported iPhone (375 pt wide: 60 + 168 + 60 + gaps).
    @ScaledMetric(relativeTo: .title2) private var scaledSaveDiameter: CGFloat = 128

    var body: some View {
        VStack(spacing: 14) {
            PauseResumeButton()
            mainRow
        }
    }

    private var saveDiameter: CGFloat { min(max(scaledSaveDiameter, 128), 168) }

    private var mainRow: some View {
        // Nothing is buffered unless recording, so Save is disabled and says why (issue #8).
        let unavailable = model.saveUnavailableReason
        return HStack(alignment: .center) {
            RoundIconButton(systemImage: "moon.fill", label: "Dim screen",
                            hint: model.isUserPaused ? "Not available while paused."
                                : "Darkens the screen. Recording continues; tap anywhere to wake.") {
                model.setDimmed(true)
            }
            // Nothing to keep the screen on for while the user has paused (issue #15).
            .disabled(model.isUserPaused)
            .opacity(model.isUserPaused ? 0.4 : 1)
            .accessibilityIdentifier("dimButton")

            Spacer(minLength: 8)

            Button {
                model.save()
            } label: {
                VStack(spacing: 2) {
                    if model.isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("SAVE")
                            .font(.title2.weight(.heavy))
                            .lineLimit(1)
                    }
                    Text(unavailable == nil ? saveSubtitle : unavailableSubtitle)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .minimumScaleFactor(0.6)
                // Capped so it fits the circle; VoiceOver and the large content viewer read "Save".
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(18)
                .foregroundStyle(.white)
                .frame(width: saveDiameter, height: saveDiameter)
                .background(Circle().fill(unavailable == nil ? ContrastPalette.red : ContrastPalette.disabledFill))
                .overlay(Circle().stroke(.white.opacity(unavailable == nil ? 1 : 0.45), lineWidth: 4))
                .shadow(radius: 8)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(unavailable != nil)
            .accessibilityLabel("Save")
            // Read right after "Save, dimmed": why it can't save now. Saving: that it is busy.
            .accessibilityValue(unavailable ?? (model.isSaving ? "Saving" : ""))
            .accessibilityHint(unavailable == nil ? saveHint : "")
            .accessibilityShowsLargeContentViewer {
                Label("Save", systemImage: "record.circle")
            }
            .accessibilityIdentifier("saveButton")

            Spacer(minLength: 8)

            RoundIconButton(systemImage: "gearshape.fill", label: "Settings", hint: nil) {
                showSettings = true
            }
            .accessibilityIdentifier("settingsButton")
        }
        .padding(.horizontal, 8)
    }

    private var unavailableSubtitle: String {
        switch model.phase {
        case .starting, .idle: "starting…"
        case .userPaused: "paused"
        default: "not recording"
        }
    }

    private var saveSubtitle: String {
        let post = model.settings.postRollSeconds
        return post > 0 ? "last \(model.settings.bufferSeconds) s\n+ \(post) s after" : "last \(model.settings.bufferSeconds) s"
    }

    private var saveHint: String {
        let post = model.settings.postRollSeconds
        return "Saves the last \(model.settings.bufferSeconds) seconds to Photos"
            + (post > 0 ? ", and keeps recording \(post) seconds more." : ".")
    }
}

/// Pause / Resume (issue #15). Pause asks first when it would discard footage (`pauseDiscardWarning`);
/// Resume is the only way out of the pause, so it is prominent while paused.
private struct PauseResumeButton: View {
    @Environment(AppModel.self) private var model
    @State private var confirmPause = false

    var body: some View {
        let paused = model.isUserPaused
        Button {
            if paused {
                model.resumeCapture()
            } else if model.pauseDiscardWarning != nil {
                confirmPause = true
            } else {
                model.pauseCapture()
            }
        } label: {
            Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .background(Capsule().fill(paused ? ContrastPalette.blue : Color.black.opacity(0.65)))
                .overlay(Capsule().stroke(.white.opacity(paused ? 0.9 : 0.5), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(paused ? "Resume recording" : "Pause recording")
        .accessibilityHint(paused
            ? "Turns the camera back on and starts filling the buffer again."
            : "Turns the camera off and discards the unsaved buffer. Saved clips are kept.")
        .accessibilityIdentifier(paused ? "resumeButton" : "pauseButton")
        .confirmationDialog("Pause recording?", isPresented: $confirmPause, titleVisibility: .visible) {
            Button("Pause and discard buffer", role: .destructive) { model.pauseCapture() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text(model.pauseDiscardWarning ?? "")
        }
    }
}

private struct RoundIconButton: View {
    let systemImage: String
    let label: String
    let hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                // The 60 pt circle holds the symbol up to this size; long-press shows it larger.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Circle().fill(.black.opacity(0.65)))
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: systemImage)
        }
    }
}

/// While dimmed, VoiceOver sees one button: double-tap wakes the screen, and a **Save** custom action
/// saves without waking it (the volume buttons save too).
private struct DimOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recording = model.phase == .recording
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 12) {
                Label {
                    Text(recording ? "Recording · \(model.readySeconds) s ready" : "Not recording")
                } icon: {
                    Circle().fill(recording ? Color.red : Color.gray).frame(width: 8, height: 8)
                }
                Text("Tap anywhere to wake")
                    .font(.footnote)
                Text("Volume buttons still save")
                    .font(.caption2)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            // Dim on purpose, but still ≥ 4.5:1 on the overlay's near-black.
            .foregroundStyle(.white.opacity(0.6))
        }
        .contentShape(Rectangle())
        .onTapGesture { model.setDimmed(false) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Screen dimmed")
        .accessibilityValue(recording ? "Recording, " + RecordingBadge.secondsReady(model.readySeconds)
            : "Not recording")
        .accessibilityHint("Double-tap to wake the screen. The Save action, and the volume buttons, save without waking it.")
        .accessibilityAddTraits([.isButton, .isModal])
        .accessibilityAction { model.setDimmed(false) }
        .accessibilityAction(named: "Save") { model.save() }
        .accessibilityIdentifier("dimOverlay")
    }
}

private extension View {
    func pill() -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.65), in: Capsule())
    }

    /// Banner text on a near-black base with a tint on top: white text keeps ≥ 4.5:1 over any footage.
    func bannerBackground(_ tint: Color) -> some View {
        font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.8))
                    .overlay(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.35)))
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.8), lineWidth: 1))
    }

    /// White on a darkened fill (≥ 5:1); `.large` makes it at least 44 pt tall. Takes its width before
    /// the text beside it, and shrinks a little rather than overflow at the largest sizes.
    func bannerButton(fill: Color) -> some View {
        buttonStyle(.borderedProminent)
            .tint(fill)
            .controlSize(.large)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .layoutPriority(1)
    }
}
