import CoreGraphics
import Foundation
import Testing
@testable import RewindCam

/// Issue #38: Dim and the system screen brightness. The overlay (`isDimmed`) is the user's choice; the
/// system brightness follows it only while the scene is `.active`, the level from before is kept in the
/// settings store while the screen is dimmed (so a relaunch after a kill can put it back), and waking
/// never overwrites a level the user or auto-brightness set meanwhile. `FakeScreenController` records the
/// brightness; the store is the harness's own `UserDefaults` suite. In the `AppModelTests` suite so it
/// shares its serialization and time limit.
@MainActor
extension AppModelTests {

    private func dimStore(_ h: ModelHarness) -> UserDefaultsSettingsStore {
        UserDefaultsSettingsStore(defaults: h.defaults)
    }

    /// Recording in an active scene, at brightness 0.7, with the start announcement already heard.
    private func recordingForDim(_ h: ModelHarness) async -> AppModel {
        h.screen.brightness = 0.7
        let model = h.makeModel()
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        #expect(model.phase == .recording)
        h.announcer.removeAll()
        return model
    }

    private func stopForDim(_ model: AppModel) async {
        model.stop()
        await model.waitForPipeline()
    }

    @Test("Dim: the level from before is stored while dimmed and cleared on wake")
    func dimStoresBrightnessUntilWake() async {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await recordingForDim(h)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)

        model.setDimmed(true)
        #expect(model.isDimmed)
        #expect(h.screen.brightness == AppModel.dimmedBrightness)
        #expect(dimStore(h).loadDimRestoreBrightness() == Double(CGFloat(0.7)))

        model.setDimmed(false)
        #expect(!model.isDimmed)
        #expect(h.screen.brightness == 0.7)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)
        #expect(model.settings == RecordingSettings(), "the settings themselves are untouched")
        await stopForDim(model)
    }

    @Test("Dim: .inactive puts the brightness back and keeps the overlay; .active dims again")
    func dimFollowsInactiveAndActive() async {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await recordingForDim(h)
        model.setDimmed(true)
        #expect(h.screen.brightness == AppModel.dimmedBrightness)

        // An incoming call, Control Center, an alert: iOS's own screen is drawn at the user's level.
        model.scenePhaseChanged(.inactive)
        #expect(model.isDimmed, "the overlay stays up")
        #expect(h.screen.brightness == 0.7)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil, "nothing left to restore after a kill now")
        #expect(model.phase == .recording, "capture keeps running")

        model.scenePhaseChanged(.active)
        #expect(model.isDimmed)
        #expect(h.screen.brightness == AppModel.dimmedBrightness)
        #expect(dimStore(h).loadDimRestoreBrightness() == Double(CGFloat(0.7)))

        model.setDimmed(false)
        #expect(h.screen.brightness == 0.7)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)
        #expect(h.announcer.announcements.isEmpty, "brightness changes are not announced")
        await stopForDim(model)
    }

    @Test("Dim: repeated inactive/active flips restore and re-dim each time, never losing the level")
    func dimSurvivesRepeatedSceneFlips() async {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await recordingForDim(h)
        model.setDimmed(true)
        for flip in 1...5 {
            model.scenePhaseChanged(.inactive)
            #expect(h.screen.brightness == 0.7, "flip \(flip): readable while inactive")
            #expect(dimStore(h).loadDimRestoreBrightness() == nil, "flip \(flip)")
            // A duplicate phase (SwiftUI can repeat one) changes nothing.
            model.scenePhaseChanged(.inactive)
            #expect(h.screen.brightness == 0.7, "flip \(flip): repeated .inactive")

            model.scenePhaseChanged(.active)
            #expect(h.screen.brightness == AppModel.dimmedBrightness, "flip \(flip): dimmed again")
            model.scenePhaseChanged(.active)
            #expect(h.screen.brightness == AppModel.dimmedBrightness, "flip \(flip): repeated .active")
            #expect(dimStore(h).loadDimRestoreBrightness() == Double(CGFloat(0.7)), "flip \(flip)")
            #expect(model.isDimmed, "flip \(flip)")
        }
        #expect(model.phase == .recording)
        #expect(h.announcer.announcements.isEmpty, "no announcement from any flip")

        model.setDimmed(false)
        #expect(h.screen.brightness == 0.7)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)
        await stopForDim(model)
    }

    @Test("Dim: a level changed while inactive (Control Center slider) is the one restored afterwards")
    func dimKeepsLevelChangedWhileInactive() async {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await recordingForDim(h)
        model.setDimmed(true)
        model.scenePhaseChanged(.inactive)
        h.screen.brightness = 0.3 // the user drags the slider in Control Center
        model.scenePhaseChanged(.active)
        #expect(h.screen.brightness == AppModel.dimmedBrightness)
        #expect(dimStore(h).loadDimRestoreBrightness() == Double(CGFloat(0.3)))
        model.setDimmed(false)
        #expect(h.screen.brightness == 0.3)
        await stopForDim(model)
    }

    @Test("Dim: .background wakes, restores the brightness and clears the stored level")
    func dimBackgroundRestoresAndClears() async {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await recordingForDim(h)
        model.setDimmed(true)

        // Straight to .background (no .inactive first) still restores.
        model.scenePhaseChanged(.background)
        #expect(!model.isDimmed)
        #expect(h.screen.brightness == 0.7)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)
        await model.waitForPipeline()

        // The usual order, .inactive then .background, restores once.
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        model.setDimmed(true)
        model.scenePhaseChanged(.inactive)
        h.screen.brightness = 0.5 // auto-brightness while inactive
        model.scenePhaseChanged(.background)
        #expect(!model.isDimmed)
        #expect(h.screen.brightness == 0.5, "not overwritten by the level from before")
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)
        await model.waitForPipeline()

        // Back in the foreground: awake, and the brightness is left alone.
        model.scenePhaseChanged(.inactive)
        model.scenePhaseChanged(.active)
        await model.waitForCapture()
        #expect(!model.isDimmed)
        #expect(h.screen.brightness == 0.5)
        await stopForDim(model)
    }

    @Test("Dim: a level the user or auto-brightness set during the dim is left alone on wake")
    func dimWakeKeepsChangedBrightness() async {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await recordingForDim(h)
        model.setDimmed(true)
        h.screen.brightness = 0.4
        model.setDimmed(false)
        #expect(!model.isDimmed)
        #expect(h.screen.brightness == 0.4)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)

        // Also when the change happens while dimmed in an active scene and then the scene goes inactive.
        model.setDimmed(true)
        #expect(dimStore(h).loadDimRestoreBrightness() == Double(CGFloat(0.4)))
        h.screen.brightness = 0.25
        model.scenePhaseChanged(.inactive)
        #expect(h.screen.brightness == 0.25)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)
        await stopForDim(model)
    }

    @Test("Dim: a relaunch after a kill while dimmed restores the stored level once and clears it")
    func dimRelaunchRestoresOnce() async {
        let h = ModelHarness()
        defer { h.cleanUp() }
        h.screen.brightness = 0.7
        // First run: dims, then the process is killed (no wake, no scene change).
        let killed = h.makeModel()
        killed.setDimmed(true)
        #expect(h.screen.brightness == AppModel.dimmedBrightness)
        #expect(dimStore(h).loadDimRestoreBrightness() == Double(CGFloat(0.7)))

        // Next launch: nothing happens before a window scene exists (the brightness can't be set yet).
        let model = h.makeModel()
        #expect(h.screen.brightness == AppModel.dimmedBrightness)
        #expect(!model.isDimmed)
        model.scenePhaseChanged(.active)
        #expect(h.screen.brightness == 0.7, "restored at the first foreground phase")
        #expect(dimStore(h).loadDimRestoreBrightness() == nil, "and cleared")
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(!model.isDimmed)

        // Once: a dark level the user picks afterwards is theirs.
        h.screen.brightness = AppModel.dimmedBrightness
        model.scenePhaseChanged(.inactive)
        model.scenePhaseChanged(.active)
        #expect(h.screen.brightness == AppModel.dimmedBrightness)
        await stopForDim(model)

        // And the launch after that has nothing to restore.
        let third = h.makeModel()
        third.scenePhaseChanged(.inactive)
        #expect(h.screen.brightness == AppModel.dimmedBrightness)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)
    }

    @Test("Dim: a relaunch whose first phase is .inactive restores too, and a later dim doesn't lose it")
    func dimRelaunchInactiveFirst() async {
        let h = ModelHarness()
        defer { h.cleanUp() }
        dimStore(h).saveDimRestoreBrightness(0.65)
        h.screen.brightness = AppModel.dimmedBrightness
        let model = h.makeModel()
        model.scenePhaseChanged(.inactive)
        #expect(h.screen.brightness == 0.65)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)

        // A model that dims before any scene phase (as tests do) first restores the killed run's level,
        // then remembers that one, never the 2 % the killed run left.
        let h2 = ModelHarness()
        defer { h2.cleanUp() }
        dimStore(h2).saveDimRestoreBrightness(0.65)
        h2.screen.brightness = AppModel.dimmedBrightness
        let model2 = h2.makeModel()
        model2.setDimmed(true)
        #expect(h2.screen.brightness == AppModel.dimmedBrightness)
        #expect(dimStore(h2).loadDimRestoreBrightness() == 0.65)
        model2.setDimmed(false)
        #expect(h2.screen.brightness == 0.65)
        #expect(dimStore(h2).loadDimRestoreBrightness() == nil)
    }

    @Test("Dim: a relaunch without a stored level leaves the brightness untouched")
    func dimRelaunchWithoutValueLeavesBrightness() async {
        for level in [0.4, Double(AppModel.dimmedBrightness)] {
            let h = ModelHarness()
            defer { h.cleanUp() }
            h.screen.brightness = CGFloat(level)
            let model = h.makeModel()
            #expect(h.screen.brightness == CGFloat(level))
            model.scenePhaseChanged(.active)
            #expect(h.screen.brightness == CGFloat(level), "level \(level)")
            await model.waitForCapture()
            #expect(h.screen.brightness == CGFloat(level), "level \(level)")
            #expect(dimStore(h).loadDimRestoreBrightness() == nil)
            await stopForDim(model)
        }
    }

    @Test("Dim: a relaunch after the brightness changed since the kill (e.g. a lock) leaves it and clears")
    func dimRelaunchAfterBrightnessChanged() async {
        let h = ModelHarness()
        defer { h.cleanUp() }
        dimStore(h).saveDimRestoreBrightness(0.7)
        h.screen.brightness = 0.5
        let model = h.makeModel()
        model.scenePhaseChanged(.active)
        #expect(h.screen.brightness == 0.5)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)
        await model.waitForCapture()
        await stopForDim(model)
    }

    @Test("Dim and Pause: pausing wakes and restores; scene flips while paused don't dim")
    func dimAndPause() async {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let model = await recordingForDim(h)
        model.setDimmed(true)
        model.pauseCapture()
        #expect(!model.isDimmed)
        #expect(h.screen.brightness == 0.7)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)
        await model.waitForCapture()
        #expect(model.phase == .userPaused)

        for _ in 1...3 {
            model.scenePhaseChanged(.inactive)
            model.scenePhaseChanged(.active)
            #expect(!model.isDimmed)
            #expect(h.screen.brightness == 0.7)
        }
        model.setDimmed(true) // refused while paused
        #expect(!model.isDimmed)
        #expect(h.screen.brightness == 0.7)
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)

        model.resumeCapture()
        await model.waitForCapture()
        #expect(model.phase == .recording)
        #expect(!model.isDimmed, "Resume doesn't dim")
        // Paused while the scene is inactive (brightness already back): nothing is dimmed on return.
        model.setDimmed(true)
        model.scenePhaseChanged(.inactive)
        model.pauseCapture()
        #expect(!model.isDimmed)
        #expect(h.screen.brightness == 0.7)
        model.scenePhaseChanged(.active)
        #expect(h.screen.brightness == 0.7, "a pause in between ended the dim")
        #expect(dimStore(h).loadDimRestoreBrightness() == nil)
        await model.waitForCapture()
        #expect(model.phase == .userPaused)
    }

    @Test("Dim: the stored level round-trips, is separate from the settings and ignores bad values")
    func dimRestoreStore() {
        let h = ModelHarness()
        defer { h.cleanUp() }
        let store = dimStore(h)
        var settings = RecordingSettings()
        settings.bufferSeconds = 60
        store.save(settings)
        #expect(store.loadDimRestoreBrightness() == nil)
        store.saveDimRestoreBrightness(0.45)
        #expect(store.loadDimRestoreBrightness() == 0.45)
        #expect(UserDefaultsSettingsStore(defaults: h.defaults).loadDimRestoreBrightness() == 0.45)
        #expect(store.load() == settings)
        store.saveDimRestoreBrightness(nil)
        #expect(store.loadDimRestoreBrightness() == nil)
        #expect(store.load() == settings)
        h.defaults.set(7.0, forKey: "dimRestoreBrightness.v1")
        #expect(store.loadDimRestoreBrightness() == nil, "out of range")
        h.defaults.set("bright", forKey: "dimRestoreBrightness.v1")
        #expect(store.loadDimRestoreBrightness() == nil, "not a number")
    }
}
