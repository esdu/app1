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
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("bufferPicker")
                } header: {
                    Text("Rewind buffer")
                } footer: {
                    Text("Save keeps the last \(model.settings.bufferSeconds) seconds. "
                         + "The buffer uses at most \(BufferMath.formatted(bytes: model.estimatedBufferBytes)) "
                         + "of storage at \(model.activePreset.description), and never grows.")
                }

                Section {
                    Picker("Post-roll", selection: postRollSeconds) {
                        ForEach(RecordingSettings.postRollChoices, id: \.self) { s in
                            Text(s == 0 ? "Off" : "+\(s) s").tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
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
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("resolutionPicker")
                    Picker("Frame rate", selection: frameRate) {
                        ForEach(FrameRate.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("frameRatePicker")
                    Picker("Camera", selection: camera) {
                        ForEach(CameraPosition.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("cameraPicker")
                    Toggle("Record sound", isOn: audioEnabled)
                        .accessibilityIdentifier("audioToggle")
                    if let notice = model.microphoneNotice {
                        // Same notice as the main screen's banner; the toggle keeps the user's choice.
                        Label(notice.message, systemImage: notice.systemImage)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("microphoneSettingsNote")
                        if notice.action == .openSettings {
                            Button(AppNotice.Action.openSettings.title) { model.openAppSettings() }
                        }
                    }
                    if model.activePreset != model.settings.preset {
                        Label("Recording at \(model.activePreset.description) while the phone is hot.",
                              systemImage: "thermometer.high")
                            .foregroundStyle(.orange)
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
            }
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
