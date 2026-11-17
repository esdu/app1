import Foundation

// Issue #37 (DESIGN.md §2, "Orientation"). Capture stays fixed at the portrait angle, so turning the
// phone never touches the buffer; `save` samples this once, at the tap, and the exporter turns the clip.

extension AppModel {
    /// How a clip saved now is turned: the settled way the phone is held, and the camera in use.
    /// Read once at the tap; turning the phone during the post-roll or the export doesn't change it.
    var clipOrientationAtTap: ClipOrientation {
        ClipOrientation(device: environment.orientation.orientation, camera: settings.camera)
    }
}
