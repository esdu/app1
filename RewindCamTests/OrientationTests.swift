import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import RewindCam

// Issue #37: clips saved with the phone held sideways play upright. Capture stays at the fixed portrait
// angle (the buffer survives any turn of the phone); the orientation at the save tap becomes the exported
// track's `preferredTransform`. CI has no camera or accelerometer: the decision logic is pure and tested
// here, the exporter is checked on real files, and the model is driven with `FakeOrientationSensor`.

/// Gravity with the phone turned `degrees` clockwise from portrait (upright, not tilted back).
private func gravity(turnedClockwise degrees: Double) -> Gravity {
    let a = degrees * .pi / 180
    return Gravity(x: sin(a), y: -cos(a), z: 0)
}

/// Which way the scene's "up" points in a buffer, in y-down image coordinates, worked out from the
/// physics alone (no code under test): turning the phone clockwise by k quarters turns the scene
/// anticlockwise by k on its screen. The back camera's buffer shows the scene as the screen does (a
/// window). The front camera's own image is the scene seen from the phone, so left and right are swapped
/// compared with the screen's mirror view; mirroring the connection swaps them back.
private func sceneUpInBuffer(_ device: DeviceOrientation, camera: CameraPosition, mirrored: Bool) -> CGPoint {
    var up = CGPoint(x: 0, y: -1)
    for _ in 0..<device.clockwiseQuarterTurns { up = CGPoint(x: up.y, y: -up.x) } // a quarter anticlockwise
    if camera == .front { up.x = -up.x }
    if mirrored { up.x = -up.x }
    return up
}

private func applyLinear(_ t: CGAffineTransform, _ p: CGPoint) -> CGPoint {
    CGPoint(x: t.a * p.x + t.c * p.y, y: t.b * p.x + t.d * p.y)
}

@Suite("Orientation policy (issue #37)")
struct OrientationPolicyTests {

    @Test("Each way of holding the phone is recognised, also tilted back on a stand")
    func classifiesEachOrientation() {
        for held in DeviceOrientation.allCases {
            for current in DeviceOrientation.allCases {
                for tilt in [0.0, 30, 60] {
                    #expect(OrientationClassifier.classify(.held(held, tiltBack: tilt), current: current) == held,
                            "\(held) tilted \(tilt)° from \(current)")
                }
            }
        }
    }

    @Test("Lying (nearly) flat decides nothing: the current orientation stays")
    func flatKeepsCurrent() {
        for tilt in [90.0, 75] {
            #expect(OrientationClassifier.classify(.held(.landscapeLeft, tiltBack: tilt), current: .portrait) == nil)
        }
        // 65° back still leaves enough of gravity in the screen's plane.
        #expect(OrientationClassifier.classify(.held(.landscapeLeft, tiltBack: 65), current: .portrait) == .landscapeLeft)
    }

    @Test("Hysteresis: the orientation changes only 15° past the 45° midpoint, either way")
    func hysteresis() {
        #expect(OrientationClassifier.classify(gravity(turnedClockwise: 50), current: .portrait) == .portrait)
        #expect(OrientationClassifier.classify(gravity(turnedClockwise: 59), current: .portrait) == .portrait)
        #expect(OrientationClassifier.classify(gravity(turnedClockwise: 61), current: .portrait) == .landscapeRight)
        #expect(OrientationClassifier.classify(gravity(turnedClockwise: 40), current: .landscapeRight) == .landscapeRight)
        #expect(OrientationClassifier.classify(gravity(turnedClockwise: 29), current: .landscapeRight) == .portrait)
        #expect(OrientationClassifier.classify(gravity(turnedClockwise: -61), current: .portrait) == .landscapeLeft)
        #expect(OrientationClassifier.classify(gravity(turnedClockwise: -50), current: .portrait) == .portrait)
        #expect(OrientationClassifier.classify(gravity(turnedClockwise: 145), current: .landscapeRight) == .landscapeRight)
        #expect(OrientationClassifier.classify(gravity(turnedClockwise: 160), current: .landscapeRight) == .portraitUpsideDown)
    }

    @Test("A new orientation counts only once held for 0.5 s; a brief tilt is ignored")
    func trackerSettles() {
        var t = OrientationTracker()
        #expect(t.settled(at: 0) == .portrait)
        // A brief tilt (0.3 s) and back.
        t.receive(.held(.landscapeLeft), at: 1.0)
        t.receive(.held(.landscapeLeft), at: 1.3)
        #expect(t.settled(at: 1.3) == .portrait)
        t.receive(.held(.portrait), at: 1.4)
        #expect(t.settled(at: 5) == .portrait, "the tilt never settled")
        // Held: settles 0.5 s after the turn, even between samples.
        t.receive(.held(.landscapeLeft), at: 6.0)
        #expect(t.settled(at: 6.49) == .portrait)
        #expect(t.settled(at: 6.5) == .landscapeLeft)
        t.receive(.held(.landscapeLeft), at: 6.6)
        #expect(t.settled(at: 6.6) == .landscapeLeft)
        // Laid flat: nothing changes, however long.
        t.receive(.held(.portrait, tiltBack: 88), at: 7)
        t.receive(.held(.portrait, tiltBack: 88), at: 20)
        #expect(t.settled(at: 20) == .landscapeLeft)
        // Flicker between two new orientations never settles while neither lasts 0.5 s.
        for (i, o) in [DeviceOrientation.landscapeRight, .portraitUpsideDown, .landscapeRight, .portraitUpsideDown]
            .enumerated() {
            t.receive(.held(o), at: 30 + Double(i) * 0.3)
        }
        #expect(t.settled(at: 31.1) == .landscapeLeft)
        #expect(t.settled(at: 31.5) == .portraitUpsideDown, "the last one, held 0.5 s")
    }

    @Test("Live sensor: samples are stamped on its clock and settle without the accelerometer")
    @MainActor
    func sensorSettlesOnItsClock() {
        let clock = FakeDelayScheduler()
        let sensor = MotionOrientationSensor(clock: clock, usesAccelerometer: false)
        sensor.start() // no accelerometer: nothing runs
        #expect(sensor.orientation == .portrait)
        sensor.receive(.held(.landscapeRight))
        clock.advance(by: 0.4)
        sensor.receive(.held(.landscapeRight))
        #expect(sensor.orientation == .portrait)
        clock.advance(by: 0.2)
        #expect(sensor.orientation == .landscapeRight)
    }

    @Test("The clip's turn puts the scene's up at the top, for every orientation, camera and mirroring")
    func transformMatchesPhysics() {
        let natural = CGSize(width: 1080, height: 1920)
        for device in DeviceOrientation.allCases {
            for camera in CameraPosition.allCases {
                for mirrored in [false, true] {
                    let clip = ClipOrientation(device: device, camera: camera, bufferMirrored: mirrored)
                    let up = applyLinear(clip.transform(naturalSize: natural),
                                         sceneUpInBuffer(device, camera: camera, mirrored: mirrored))
                    #expect(abs(up.x) < 1e-9 && abs(up.y + 1) < 1e-9,
                            "\(device) \(camera) mirrored \(mirrored): scene up shows as \(up)")
                }
            }
        }
    }

    @Test("The app's front camera is mirrored, so it turns its clips exactly as the back camera does")
    func frontCameraAsCaptured() {
        #expect(!CaptureGeometry.isMirrored(.back))
        #expect(CaptureGeometry.isMirrored(.front))
        for device in DeviceOrientation.allCases {
            let front = ClipOrientation(device: device, camera: .front)
            let back = ClipOrientation(device: device, camera: .back)
            #expect(front.bufferMirrored)
            #expect(front.clockwiseQuarterTurns == back.clockwiseQuarterTurns, "\(device)")
            #expect(front.clockwiseQuarterTurns == device.clockwiseQuarterTurns, "\(device)")
        }
        #expect(ClipOrientation.upright.transform(naturalSize: CGSize(width: 1080, height: 1920)) == .identity)
    }

    @Test("The transform maps the frame exactly onto the display size (landscape for a sideways phone)")
    func transformFillsDisplayRect() {
        let natural = CGSize(width: 1080, height: 1920)
        for device in DeviceOrientation.allCases {
            for camera in CameraPosition.allCases {
                let clip = ClipOrientation(device: device, camera: camera)
                let rect = CGRect(origin: .zero, size: natural).applying(clip.transform(naturalSize: natural))
                let display = clip.displaySize(naturalSize: natural)
                #expect(rect.origin == .zero, "\(device) \(camera): \(rect)")
                #expect(rect.size == display, "\(device) \(camera): \(rect)")
                #expect((display.width > display.height) == device.isLandscape, "\(device) \(camera): \(display)")
            }
        }
    }
}

/// Real exports: the saved `.mov` carries the turn, for each orientation and camera.
@Suite("Orientation: exported clips (issue #37)", .serialized, .timeLimit(.minutes(5)))
struct OrientationExportTests {

    /// What a 180×320 (portrait, like the camera's buffers) clip must carry.
    private static func expected(_ device: DeviceOrientation) -> (transform: CGAffineTransform, display: CGSize) {
        switch device {
        case .portrait: (CGAffineTransform.identity, CGSize(width: 180, height: 320))
        case .landscapeRight: (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 320, ty: 0), CGSize(width: 320, height: 180))
        case .portraitUpsideDown: (CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 180, ty: 320), CGSize(width: 180, height: 320))
        case .landscapeLeft: (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 180), CGSize(width: 320, height: 180))
        }
    }

    @Test("Each orientation and camera: preferredTransform, display size, and every frame decodes",
          arguments: CameraPosition.allCases)
    func exportCarriesTransform(camera: CameraPosition) async throws {
        let h = RecorderHarness(buffer: 3, audio: true, width: 180, height: 320)
        for device in DeviceOrientation.allCases {
            h.source.generate(seconds: 2)
            // The writer hands over the init and segments asynchronously: a save before any exists finds
            // nothing buffered. Wait for one, as a camera's user does for the badge.
            try await h.waitForSegments(through: h.now - 1.2)
            let ticket = h.recorder.beginSave(postRoll: 0)
            h.source.generate(seconds: 2)
            let bundle = try await h.awaitBundle(ticket)
            defer { bundle.discard() }
            let clip = try await ClipExporter.export(bundle, orientation: ClipOrientation(device: device, camera: camera))

            let asset = AVURLAsset(url: clip.url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let transform = try await track.load(.preferredTransform)
            let natural = try await track.load(.naturalSize)
            let (wantTransform, wantDisplay) = Self.expected(device)
            #expect(natural == CGSize(width: 180, height: 320), "frames stay the portrait buffer (\(device))")
            #expect(transform == wantTransform, "\(camera) \(device): \(transform)")
            let shown = CGRect(origin: .zero, size: natural).applying(transform)
            #expect(shown.origin == .zero, "\(camera) \(device): \(shown)")
            #expect(shown.size == wantDisplay, "\(camera) \(device): \(shown)")
            expectHealthyClip(try await inspectClip(clip.url), frameRate: h.frameRate, audio: true)
        }
    }
}

/// The model samples the orientation at the tap; turning the phone never touches the buffer.
@MainActor
extension AppModelTests {

    private func savedTrack(_ h: ModelHarness) async throws -> (transform: CGAffineTransform, natural: CGSize, duration: Double) {
        let url = try #require(h.library.clips().last)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let transform = try await track.load(.preferredTransform)
        let natural = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        return (transform, natural, duration)
    }

    @Test("Turning the phone keeps the buffer; the clip is turned for the tap, not the post-roll")
    func turningKeepsBufferAndTapDecides() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let sensor = FakeOrientationSensor(.portrait)
        var environment = h.makeEnvironment()
        environment.orientation = sensor
        let model = AppModel(environment: environment)
        model.updateSettings { $0.postRollSeconds = 5 }
        model.start()
        await model.waitForPipeline()
        #expect(model.phase == .recording)

        h.source.generate(seconds: 6)
        let generation = model.recorder.status().generation
        let starts = h.source.startCount

        // Turned to landscape while recording: nothing restarts.
        sensor.orientation = .landscapeLeft
        h.source.generate(seconds: 2)
        await model.waitForPipeline()
        #expect(model.recorder.status().generation == generation, "no new writer generation")
        #expect(h.source.startCount == starts, "the source wasn't restarted")
        #expect(model.phase == .recording)

        let task = try #require(model.save())
        // Turned back during the post-roll: the clip keeps the orientation of the tap.
        sensor.orientation = .portrait
        h.source.generate(seconds: 7)
        await task.value

        #expect(h.library.clips().count == 1, "toast: \(String(describing: model.toast))")
        let saved = try await savedTrack(h)
        #expect(saved.natural == CGSize(width: 320, height: 180))
        let want = ClipOrientation(device: .landscapeLeft, camera: .back).transform(naturalSize: saved.natural)
        #expect(saved.transform == want, "got \(saved.transform)")
        #expect(saved.transform == CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 320))
        // The 6 s from before the turn are in it: 8 s + 5 s post-roll.
        #expect((12.0...14.0).contains(saved.duration), "duration \(saved.duration)")
        #expect(model.recorder.status().generation == generation)

        model.stop()
        await model.waitForPipeline()
    }

    @Test("Front camera in landscape right: turned like the back camera; portrait stays untouched")
    func frontCameraLandscapeRight() async throws {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let sensor = FakeOrientationSensor(.landscapeRight)
        var environment = h.makeEnvironment()
        environment.orientation = sensor
        let model = AppModel(environment: environment)
        model.updateSettings { $0.camera = .front }
        model.start()
        await model.waitForPipeline()
        #expect(model.phase == .recording)

        h.source.generate(seconds: 4)
        let first = try #require(model.save())
        h.source.generate(seconds: 2)
        await first.value
        let landscape = try await savedTrack(h)
        #expect(landscape.transform == CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0),
                "got \(landscape.transform)")
        #expect(CGRect(origin: .zero, size: landscape.natural).applying(landscape.transform).size
                == CGSize(width: 180, height: 320))

        sensor.orientation = .portrait
        h.source.generate(seconds: 2)
        let second = try #require(model.save())
        h.source.generate(seconds: 2)
        await second.value
        #expect(h.library.clips().count == 2)
        var transforms: [CGAffineTransform] = []
        for url in h.library.clips() {
            let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
            transforms.append(try await track.load(.preferredTransform))
        }
        #expect(transforms.filter { $0 == .identity }.count == 1, "one portrait clip: \(transforms)")

        model.stop()
        await model.waitForPipeline()
    }
}
