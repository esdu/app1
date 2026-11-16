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
    private var audioEnabled: Binding<Bool> {
        Binding(get: { model.settings.audioEnabled }, set: { v in model.updateSettings { $0.audioEnabled = v } })
    }
}
