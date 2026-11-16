import SwiftUI

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

            VStack(spacing: 10) {
                StatusBar()
                Banners()
                Spacer()
                ToastView()
                Spacer()
                Controls(showSettings: $showSettings)
                Text("Keep RewindCam open — iOS can't record in the background.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("backgroundNotice")
                if model.isUITest {
                    Text("Fake library: \(model.fakeLibraryCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityIdentifier("fakeLibraryCount")
                        .accessibilityValue("\(model.fakeLibraryCount)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

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

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            RecordingBadge()
            Spacer(minLength: 4)
            Text("Buffer \(model.settings.bufferSeconds) s")
                .accessibilityIdentifier("bufferLabel")
                .pill()
            Text(model.activePreset.description)
                .accessibilityIdentifier("presetLabel")
                .pill()
            BatteryLabel()
        }
        .font(.footnote.weight(.semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.top, 4)
    }
}

private struct RecordingBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recording = model.phase == .recording
        HStack(spacing: 6) {
            Circle()
                .fill(recording ? Color.red : Color.gray)
                .frame(width: 10, height: 10)
            Text(recording ? "REC \(model.readySeconds) s" : phaseLabel)
        }
        .pill()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recordingBadge")
    }

    private var phaseLabel: String {
        switch model.phase {
        case .idle: "IDLE"
        case .starting: "STARTING"
        case .recording: "REC"
        case .paused: "PAUSED"
        case .failed: "ERROR"
        }
    }
}

private struct BatteryLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let level = model.batteryLevel
        HStack(spacing: 3) {
            Image(systemName: symbol(level))
            Text(level.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
        }
        .pill()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(level.map { "Battery \(Int($0 * 100)) percent" } ?? "Battery unknown")
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

private struct Banners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            if let message = model.thermalMessage {
                Banner(icon: "thermometer.high", text: message, tint: .orange)
                    .accessibilityIdentifier("thermalBanner")
            }
            switch model.phase {
            case .paused(let why):
                Banner(icon: "pause.circle.fill", text: why + " The buffer was cleared.", tint: .yellow)
                    .accessibilityIdentifier("pausedBanner")
            case .failed(let why):
                Banner(icon: "exclamationmark.triangle.fill", text: why, tint: .red)
                    .accessibilityIdentifier("errorBanner")
            default:
                EmptyView()
            }
            if let error = model.status.lastError {
                Banner(icon: "exclamationmark.circle", text: error, tint: .red)
            }
        }
    }
}

private struct Banner: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(tint.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.8), lineWidth: 1))
    }
}

private struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            Label(toast.message, systemImage: toast.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.black.opacity(0.75), in: Capsule())
                .overlay(Capsule().stroke(toast.isError ? Color.red : Color.green, lineWidth: 1.5))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("toast")
                .id(toast.id)
                .transition(.opacity)
        }
    }
}

private struct Controls: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool

    var body: some View {
        HStack(alignment: .center) {
            RoundIconButton(systemImage: "moon.fill", label: "Dim screen") {
                model.setDimmed(true)
            }
            .accessibilityIdentifier("dimButton")

            Spacer()

            Button {
                model.save()
            } label: {
                VStack(spacing: 2) {
                    if model.isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("SAVE").font(.title2.weight(.heavy))
                    }
                    Text(saveSubtitle)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .frame(width: 128, height: 128)
                .background(Circle().fill(Color.red))
                .overlay(Circle().stroke(.white, lineWidth: 4))
                .shadow(radius: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save")
            .accessibilityHint("Saves the last \(model.settings.bufferSeconds) seconds to Photos")
            .accessibilityIdentifier("saveButton")

            Spacer()

            RoundIconButton(systemImage: "gearshape.fill", label: "Settings") {
                showSettings = true
            }
            .accessibilityIdentifier("settingsButton")
        }
        .padding(.horizontal, 8)
    }

    private var saveSubtitle: String {
        let post = model.settings.postRollSeconds
        return post > 0 ? "last \(model.settings.bufferSeconds) s\n+ \(post) s after" : "last \(model.settings.bufferSeconds) s"
    }
}

private struct RoundIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct DimOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(model.phase == .recording ? Color.red : Color.gray).frame(width: 8, height: 8)
                    Text(model.phase == .recording ? "Recording · \(model.readySeconds) s ready" : "Not recording")
                }
                Text("Tap anywhere to wake")
                    .font(.footnote)
                Text("Volume buttons still save")
                    .font(.caption2)
                    .opacity(0.7)
            }
            .foregroundStyle(.white.opacity(0.55))
        }
        .contentShape(Rectangle())
        .onTapGesture { model.setDimmed(false) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Screen dimmed. Tap to wake.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("dimOverlay")
    }
}

private extension View {
    func pill() -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
    }
}
