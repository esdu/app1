import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Live camera preview backed by `AVCaptureVideoPreviewLayer`.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Shows whatever the active source can preview: the camera layer or synthetic snapshots.
struct PreviewSurface: View {
    let model: AppModel

    var body: some View {
        if let session = model.captureSession {
            CameraPreview(session: session)
        } else if let image = model.previewImage {
            Image(decorative: image.value, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            Color.black
        }
    }
}

/// Hosts `AVCaptureEventInteraction` (iOS 17.2+) so the volume buttons trigger a save
/// while the capture session is running.
struct CaptureButtonsInteraction: UIViewRepresentable {
    let onPress: @MainActor () -> Void

    @MainActor
    final class Coordinator {
        var onPress: @MainActor () -> Void
        init(onPress: @escaping @MainActor () -> Void) { self.onPress = onPress }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPress: onPress) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        let interaction = AVCaptureEventInteraction { event in
            // Fire once per press, on release.
            guard event.phase == .ended else { return }
            MainActor.assumeIsolated { coordinator.onPress() }
        }
        interaction.isEnabled = true
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPress = onPress
    }
}
