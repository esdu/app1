import SwiftUI

@main
struct RewindCamApp: App {
    /// When the unit-test bundle is injected into the app, don't start the camera pipeline.
    private static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @State private var model: AppModel?

    init() {
        if !Self.isUnitTestHost {
            _model = State(initialValue: AppModel(environment: .current()))
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView(model: model)
            } else {
                Text("RewindCam unit-test host")
            }
        }
    }
}

private struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ContentView()
            .environment(model)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase, initial: true) { _, phase in
                model.scenePhaseChanged(phase)
            }
    }
}
