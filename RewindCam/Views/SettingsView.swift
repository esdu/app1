import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Buffer length", selection: bufferSeconds) {
                        ForEach(RecordingSettings.bufferChoices, id: \.self) { Text("\($0) s").tag($0) }
                    }
                    .adaptivePickerStyle()
                    .accessibilityIdentifier("bufferPicker")
                    // Free space and whether this buffer fits (issue #10).
                    LabeledContent("Free space", value: model.availableDiskBytes.map { BufferMath.formatted(bytes: $0) } ?? "Unknown")
                        .accessibilityIdentifier("freeSpaceRow")
                    if !model.unsavedClips.isEmpty {
                        LabeledContent("Clips waiting for Photos",
                                       value: "\(model.unsavedClips.count) · \(BufferMath.formatted(bytes: model.unsavedClipBytes))")
                            .accessibilityIdentifier("unsavedSpaceRow")
                    }
                    // Measured buffer + saves in progress, and the most they can take (issue #14).
                    LabeledContent("Temporary video",
                                   value: "\(BufferMath.formatted(bytes: model.workingSet.temporaryBytes)) "
                                       + "of at most \(BufferMath.formatted(bytes: model.temporaryMediaCapBytes))")
                        .accessibilityIdentifier("workingSetRow")
                    DiskFitNote()
                } header: {
                    Text("Rewind buffer")
                } footer: {
                    Text("Save keeps the last \(model.settings.bufferSeconds) seconds. "
                         + "The buffer uses at most \(BufferMath.formatted(bytes: model.estimatedBufferBytes)) "
                         + "of storage at \(model.activePreset.description), and never grows."
                         + tooLongFooter)
                }

                Section {
                    Picker("Post-roll", selection: postRollSeconds) {
                        ForEach(RecordingSettings.postRollChoices, id: \.self) { s in
                            Text(s == 0 ? "Off" : "+\(s) s").tag(s)
                        }
                    }
                    .adaptivePickerStyle()
                    .accessibilityIdentifier("postRollPicker")
                } header: {
                    Text("Keep recording after Save")
                } footer: {
                    Text("Post-roll adds footage after you press Save, so the clip covers before and after the moment.")
                }

                Section("Video") {
                    Picker("Resolution", selection: resolution) {
                        ForEach(model.supportedResolutions) { Text($0.label).tag($0) }
                    }
                    .adaptivePickerStyle()
                    .accessibilityIdentifier("resolutionPicker")
                    Picker("Frame rate", selection: frameRate) {
                        ForEach(FrameRate.allCases) { Text($0.label).tag($0) }
                    }
                    .adaptivePickerStyle()
                    .accessibilityIdentifier("frameRatePicker")
                    Picker("Camera", selection: camera) {
                        ForEach(CameraPosition.allCases) { Text($0.label).tag($0) }
                    }
                    .adaptivePickerStyle()
                    .accessibilityIdentifier("cameraPicker")
                    Toggle("Record sound", isOn: audioEnabled)
                        .accessibilityIdentifier("audioToggle")
                    if let notice = model.microphoneNotice {
                        // Same notice as the main screen's banner; the toggle keeps the user's choice.
                        NoteLabel(text: notice.message, systemImage: notice.systemImage, color: .orange)
                            .accessibilityIdentifier("microphoneSettingsNote")
                        if notice.action == .openSettings {
                            Button(AppNotice.Action.openSettings.title) { model.openAppSettings() }
                        }
                    }
                    if model.activePreset != model.settings.preset {
                        NoteLabel(text: "Recording at \(model.activePreset.description) while the phone is hot.",
                                  systemImage: "thermometer.high", color: .orange)
                    }
                }

                Section {
                    LabeledContent("Phone temperature", value: model.thermalLevel.label)
                    LabeledContent("Battery", value: model.batteryLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unknown")
                } header: {
                    Text("Long sessions")
                } footer: {
                    Text("The screen stays awake while RewindCam is open. Tap the moon to dim it; recording continues. "
                         + "If the phone gets hot, RewindCam lowers the quality and tells you. Changing video settings clears the buffer.")
                }

                Section {
                    Toggle("Say \u{201C}save that\u{201D} to save", isOn: voiceTriggerEnabled)
                        .disabled(!model.isVoiceAvailable)
                        .accessibilityIdentifier("voiceToggle")
                    if model.settings.voiceTriggerEnabled {
                        LabeledContent("Listening", value: model.voiceListeningLabel)
                            .accessibilityIdentifier("voiceListening")
                    }
                } header: {
                    Text("Voice trigger")
                } footer: {
                    Text(model.isVoiceAvailable
                         ? "Speech is recognised on this iPhone only (on-device recognition is required, never the server). "
                           + "It costs extra battery: compare the measured drain below with it on and off."
                         : "Not available: this device can't recognise speech on-device, and RewindCam never sends audio to a server.")
                }

                Section {
                    Text(model.batteryDrain.summary)
                        .font(.footnote.monospacedDigit())
                        .accessibilityIdentifier("batteryDrain")
                } header: {
                    Text("Measured battery drain (this session)")
                } footer: {
                    Text("Measured from the battery level while recording and unplugged. Restarts when quality or the voice trigger changes.")
                }

                Section {
                    Label("Volume buttons save too, while the camera is running.", systemImage: "speaker.wave.2")
                        .font(.footnote)
                }

                Section("Privacy") {
                    Text("RewindCam works entirely offline. It has no accounts and no analytics, "
                         + "and it never uploads anything. Clips go only to your photo library, with add-only access.")
                        .font(.footnote)
                }

                // What RewindCam is not (issue #12; the same sentence is near the top of README.md).
                Section {
                    Text("RewindCam is a camera, not a baby monitor, and doesn't replace supervising your child.")
                        .font(.footnote)
                        .accessibilityIdentifier("supervisionNote")
                }
            }
            .onAppear { model.refreshDiskSpace() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("doneButton")
                }
            }
        }
    }

    /// Buffer lengths marked as not fitting the free space at the current quality.
    private var tooLongFooter: String {
        let tooLong = model.bufferChoicesThatDontFit
        guard !tooLong.isEmpty else { return "" }
        let list = tooLong.map { "\($0)\u{00A0}s" }.joined(separator: ", ") // "15 s" never wraps
        return " Too long for the free space at \(model.activePreset.description): \(list)."
    }

    // Explicit bindings: each set goes through `AppModel.updateSettings` (persist + apply).
    private var bufferSeconds: Binding<Int> {
        Binding(get: { model.settings.bufferSeconds }, set: { v in model.updateSettings { $0.bufferSeconds = v } })
    }
    private var postRollSeconds: Binding<Int> {
        Binding(get: { model.settings.postRollSeconds }, set: { v in model.updateSettings { $0.postRollSeconds = v } })
    }
    private var resolution: Binding<VideoResolution> {
        Binding(get: { model.settings.resolution }, set: { v in model.updateSettings { $0.resolution = v } })
    }
    private var frameRate: Binding<FrameRate> {
        Binding(get: { model.settings.frameRate }, set: { v in model.updateSettings { $0.frameRate = v } })
    }
    private var camera: Binding<CameraPosition> {
        Binding(get: { model.settings.camera }, set: { v in model.updateSettings { $0.camera = v } })
    }
    private var voiceTriggerEnabled: Binding<Bool> {
        Binding(get: { model.settings.voiceTriggerEnabled }, set: { v in model.updateSettings { $0.voiceTriggerEnabled = v } })
    }
    private var audioEnabled: Binding<Bool> {
        Binding(get: { model.settings.audioEnabled }, set: { v in model.updateSettings { $0.audioEnabled = v } })
    }
}

/// Says whether the chosen buffer fits the free space at the current quality, and whether a save does
/// (issue #10, `DiskSpacePolicy`). Nothing when both fit or free space is unknown.
private struct DiskFitNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let note {
            NoteLabel(text: note.text, systemImage: note.systemImage, color: note.color)
                .accessibilityIdentifier("diskFitNote")
        }
    }

    private var note: (text: String, systemImage: String, color: Color)? {
        let seconds = model.settings.bufferSeconds
        let preset = model.activePreset.description
        let policy = model.diskPolicy
        let check = model.diskSpaceCheck(bufferSeconds: seconds)
        let toFree = BufferMath.formatted(bytes: check.bytesToFree)
        let where_ = AppModel.storageHint
        switch check.level {
        case .tooLow:
            let needs = BufferMath.formatted(bytes: policy.requiredBytesToBuffer)
            let text = "Doesn't fit: \(seconds) s at \(preset) needs about \(needs) free. "
                + "Free up about \(toFree) (\(where_)), or choose a shorter buffer or lower quality."
            return (text, "externaldrive.badge.xmark", .red)
        case .saveMayNotFit:
            let save = BufferMath.formatted(bytes: policy.requiredBytesToSave)
            let text = "The buffer fits, but a save can need up to \(save) more and may not fit. "
                + "Free up about \(toFree) (\(where_))."
            return (text, "externaldrive.badge.exclamationmark", .orange)
        case .enough:
            return nil
        }
    }
}

/// A warning in a Settings row: the icon carries the colour, the text stays in the primary colour, so it
/// keeps full contrast (orange or red text on the grouped background is below 4.5:1). Issue #11.
private struct NoteLabel: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Segmented controls normally; at accessibility text sizes their segments would truncate ("1…"),
    /// so the choice becomes a menu that shows the full value (issue #11).
    func adaptivePickerStyle() -> some View {
        modifier(AdaptivePickerStyle())
    }
}

private struct AdaptivePickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.pickerStyle(.menu)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}
