import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Live camera preview backed by `AVCaptureVideoPreviewLayer`.
///
/// Issue #37: the layer uses the same fixed portrait angle as the recorded buffers
/// (`CaptureGeometry.portraitRotationAngle`). The interface is portrait-only, so the screen turns with the
/// phone and a portrait-upright picture is a window onto the scene: upright relative to the scene however
/// the phone is held, as in the system Camera app with its controls locked. The angle is set again whenever
/// the layer's connection may have been rebuilt: after each reconfiguration of the session (camera, quality
/// or sound change; `CameraFrameSource.didConfigureNotification`), on joining a window, and on layout.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        func attach(_ session: AVCaptureSession) {
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            // Selector-based: removed automatically when the view goes away. Posted on the main queue.
            NotificationCenter.default.addObserver(self, selector: #selector(sessionDidConfigure(_:)),
                                                   name: CameraFrameSource.didConfigureNotification, object: session)
            applyRotation()
        }

        @objc private func sessionDidConfigure(_ note: Notification) { applyRotation() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyRotation()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyRotation()
        }

        private func applyRotation() {
            CaptureGeometry.applyPortraitRotation(to: previewLayer.connection)
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.attach(session)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Shows whatever the active source can preview: the camera layer or synthetic snapshots.
struct PreviewSurface: View {
    let model: AppModel

    var body: some View {
        if model.isUserPaused {
            // Paused (issue #15): no frozen last frame that could pass for a live picture.
            Color.black
        } else if let session = model.captureSession {
            CameraPreview(session: session)
        } else if let image = model.previewImage {
            // Overlay + clip so an aspect-fill image never widens the layout beyond the screen.
            Color.black
                .overlay {
                    Image(decorative: image.value, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
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
