# RewindCam

[![iOS](https://github.com/esdu/app1/actions/workflows/ios.yml/badge.svg?branch=claude/keen-fermat-4r9wgs)](https://github.com/esdu/app1/actions/workflows/ios.yml)

A free, private, offline **pre-record camera** for catching a baby's spontaneous milestones: first
steps, first words, the laugh you didn't see coming.

The camera records all the time into a rolling buffer that never grows. When something happens,
tap **Save** (or press a volume button, or say "save that") and the last *N* seconds land in Photos.
Nothing leaves the phone: there is no network code, no accounts and no analytics.

| Recording | Saved | Settings | Dimmed |
|---|---|---|---|
| ![Recording](docs/screenshots/save-2-after-5s.png) | ![Saved toast](docs/screenshots/save-3-toast.png) | ![Settings](docs/screenshots/settings-2-open.png) | ![Dim mode](docs/screenshots/dim-2-dimmed.png) |

*Screenshots come from the UI tests in the Simulator. The colour bars are the synthetic test
source, because the Simulator has no camera.*

## Features

- **Rolling buffer** of 15, 30, 60, 90 or 120 s. Disk use is bounded: only the buffer plus a small margin
  is ever stored (see the [disk math](DESIGN.md#bounded-disk)).
- **Save** with a big on-screen button, or the **volume buttons** (`AVCaptureEventInteraction`, iOS 17.2+).
- **Post-roll**: keep recording 0, 5, 10 or 30 s after the trigger, so the clip covers before *and* after.
- **Photos** with add-only permission (asked at launch, not during the first save), a confirmation
  toast and a haptic.
- **No lost clips**: a saved clip is kept in the app (Application Support, excluded from backup) until
  Photos accepts it. If Photos access is denied or the import fails, a banner says so and offers
  **Retry**, also after a relaunch. Export and import keep running for a while if you lock the phone
  right after tapping Save (background task).
- **Quality**: 720p, 1080p, or 4K where the camera supports it; 30 or 60 fps; sound on or off; front or back camera.
- **Microphone denied**: recording carries on without sound. A banner says sound is off (and that
  the voice trigger can't listen, if it is on) because microphone access is denied, with an
  **Open Settings** button. "Record sound" stays as you set it, and sound comes back once access is allowed.
- **Camera denied**: a red "Camera access is off" banner says why RewindCam needs the camera, with an
  **Open Settings** button; nothing is recorded and Save is disabled (it says why). If the camera
  can't start for another reason (no camera, configuration failed), the banner offers **Try Again**.
  The app checks again whenever it comes back to the foreground, so allowing the camera in Settings
  and returning starts recording without a relaunch. Settings and the unsaved-clips Retry keep working.
- **Long sessions**: the screen stays awake. A **Dim** overlay drops brightness to 2 % and
  you tap to wake. The app watches thermal state and steps quality down (and tells you) when the
  phone gets hot. Battery level is shown.
- **Interruptions** (calls, another app taking the camera, backgrounding) pause cleanly and clear
  the buffer, and capture resumes on its own when the app comes back.
- **Pause / Resume**: RewindCam still starts recording on launch and resumes on its own, but you can
  tap **Pause** (above Save) to turn the camera off. If footage is buffered it asks first, because
  pausing discards the unsaved buffer; clips you saved, and clips waiting for Photos, are kept. While
  paused the badge says PAUSED, a blue banner explains it, Save, the volume buttons and the voice
  trigger refuse (and say why), Dim is off and the screen may lock. The pause holds when you leave the
  app and come back, after a trip to Settings, and through camera errors or interruptions ending,
  until you tap **Resume**.
- **Camera errors recover or say so**: after a capture-session error the app restarts the camera
  (at once, then backing off for about 30 s). If that doesn't work it stops, wakes the screen from Dim
  and shows "Not recording" with **Try Again**, instead of claiming to restart forever. A status
  check every 0.5 s also resumes recording if the camera came back without telling the app.
- **Frame watchdog**: if no new video frame reaches the buffer for 5 s while the app says it is
  recording (sound still arriving doesn't count), or frames arrive but nothing is written for 5 s, it
  says so ("No new video for 5 s. Restarting the camera…") and restarts the camera once. If that
  brings recording back, an orange banner says when the camera was restarted and that the footage from
  before is gone; if video stops again, it stops, wakes the screen from Dim and shows "Not recording"
  with **Try Again**. A save waiting for its post-roll is finished at once with the footage there is
  (the toast says the clip ends early), or fails with a message saying to save again.
- **Low-disk guard**: RewindCam checks free space before it starts buffering, every 5 s while it
  records, and when you tap Save. Without room for the buffer it doesn't start, and says how much to
  free and where, or to choose a shorter buffer or lower quality (lowering either in Settings starts
  recording once it fits). If space runs low while recording it stops cleanly, before writes fail;
  when only a save might not fit it keeps recording and warns. A save is never refused for space, only
  warned about. Settings shows free space and marks buffer lengths that don't fit. Clips waiting for
  Photos are never deleted to make room; the warnings say how much they take.
- **Orphan cleanup**: leftover buffer files and half-written exports from a crash or kill are removed
  on launch. Finished clips that didn't reach Photos are kept.
- **Voice trigger** (optional, off by default): say "save that". Recognition is **on-device
  only** (`requiresOnDeviceRecognition`). The app also measures battery drain per hour so you can
  see what the voice trigger costs.

## How it works

One `AVAssetWriter` with the `.mpeg4AppleHLS` profile cuts the stream into ~1 s fragmented-MP4
segments. They are kept in a ring on disk (`Caches/`), and the oldest are deleted once the buffer is
covered. On Save, the init segment and the retained segments are concatenated, trimmed to the exact
range with `AVMutableComposition`, and exported **without re-encoding** (passthrough) to `.mov`.
Full details, threading and buffer math are in **[DESIGN.md](DESIGN.md)**.

## Known limits

- **No background recording.** iOS doesn't let apps use the camera in the background. When
  RewindCam leaves the screen the buffer is cleared, and the app says so. Keep it open, with
  Dim on for long sessions.
- **Real-camera behaviour is not verified in CI.** CI runs on the Simulator, which has no camera,
  no volume buttons, no thermal changes and no battery. Everything except `CameraFrameSource`,
  `AVCaptureEventInteraction`, real Photos and the speech recogniser is tested through the
  synthetic source and fakes. See the manual checklist below.
- Changing a video setting, or a thermal step-down, **restarts the writer and clears the buffer**
  (segments from different encoder settings can't be joined without re-encoding).
- A Save resolves when the segment containing the tap is complete, about 1 s after the tap
  (plus any post-roll). The clip still ends exactly at the tap.
- Only one save can be pending at a time. A second tap during post-roll says "Already saving".
- The frame watchdog notices a stall 5 to 5.5 s after the last new frame; footage from before its
  restart is cleared like any other restart. It is tested with the synthetic source only: whether a
  real `AVCaptureSession` ever stalls this way, and whether a stop and start fixes it, is not verified.
- **Clips that didn't reach Photos** take their full size in the app's storage until a Retry succeeds.
  There is no in-app way to delete or share them yet; allow Photos access and tap Retry.
  (A small in-app list for them is proposed in [docs/decisions/clip-library.md](docs/decisions/clip-library.md).)
- **Clips that didn't reach Photos are not backed up** and don't move to a new or restored phone: they
  are excluded from iCloud/device backup until Photos has them. All media files use the iOS default
  Data Protection class ("available after first unlock"), set explicitly so a save can finish while the
  phone is locked; the stricter "Complete" class would make it fail. See DESIGN.md §2, "File protection
  and backup". The Simulator doesn't enforce Data Protection, so this is checked on a device only.
- A save is only safe once its export has finished (a few seconds after the tap, plus post-roll). If
  iOS kills the app before that (for example after a long time locked), that one clip is lost. If it
  is killed after Photos accepted a clip but before the app noticed, Retry can add it twice.
- Background time for finishing a save, the real Photos permission prompt and Photos import errors
  are not verified on a device yet.
- **Free space is an estimate.** The low-disk guard compares free space with nominal sizes (DESIGN.md
  "Free space"); a save can still fail if VBR peaks or other apps use the space meanwhile. iOS's
  "available for important usage" figure includes purgeable space, so it can be higher than
  Settings › General › iPhone Storage shows. Tested with a fake free-space value only; real full-phone
  behaviour is not verified on a device yet.
- The voice trigger is English (en-US) and needs a device that supports on-device recognition.
- **A pause lasts until Resume or until RewindCam is relaunched**: it isn't saved, so a relaunch (also
  after iOS ends the app in the background) records again, as before. While paused the camera session
  is off, so the volume buttons may change the volume instead of reaching RewindCam (not verified on a
  device). Pause and its races are tested with the synthetic source only.
- The camera-denied and start-failure paths are tested with the synthetic source (unit and UI tests);
  the real camera prompt and `CameraFrameSource`'s configuration failures are not verified on a device yet.
- With the microphone denied, clips have no sound track at all. The microphone paths of
  `CameraFrameSource` (denied prompt, a mic input that can't be added) are not verified on a device yet;
  CI simulates the denial with the synthetic source.
- UI tests run the synthetic source at 360×640 (the CI VM has no hardware encoder). Unit tests use
  320×180 at 15 fps so 300 s of footage encodes in seconds.

## Install on a real iPhone

You need a Mac with Xcode 26 or newer and an iPhone on iOS 17.2 or newer. A free Apple ID works
(apps signed with a free account expire after 7 days).

1. Install XcodeGen and generate the project:

   ```bash
   brew install xcodegen
   ```

   ```bash
   git clone https://github.com/esdu/app1.git && cd app1 && xcodegen generate
   ```

2. Open `RewindCam.xcodeproj`. Select the **RewindCam** target, then **Signing & Capabilities**:
   pick your **Team**, and if Xcode says the identifier is taken, change the **Bundle Identifier**
   (e.g. `com.yourname.rewindcam`).
3. Connect the iPhone and trust the Mac. On the phone, turn on
   **Settings › Privacy & Security › Developer Mode** and restart when asked.
4. Choose your iPhone as the run destination and press **Run** (⌘R).
5. On the phone, allow the developer under **Settings › General › VPN & Device Management** the first time.
6. Grant Camera and Microphone on first launch, then Photos (add-only), which is asked right after.

Command-line alternative (after `xcodegen generate`):

```bash
xcodebuild -project RewindCam.xcodeproj -scheme RewindCam -destination 'generic/platform=iOS' -allowProvisioningUpdates DEVELOPMENT_TEAM=YOURTEAMID PRODUCT_BUNDLE_IDENTIFIER=com.yourname.rewindcam build
```

## Manual test checklist (real device)

- [ ] **Volume buttons**: with the camera running, press volume up and then volume down. Each saves one
      clip, and the system volume HUD does not appear.
- [ ] **Clip contents**: a clip saved after 60 s with a 30 s buffer plays in Photos, lasts about 30 s,
      ends at the moment of the tap, is upright, and has sound (and none with "Record sound" off).
- [ ] **Post-roll**: with +10 s, the toast says "recording 10 s more" and the clip lasts about 40 s.
- [ ] **Front camera**: the clip is upright and mirrored like the preview.
- [ ] **4K / 60 fps**: offered only where supported, and clips play back smoothly.
- [ ] **Interruptions**: during a phone call, from Camera.app opened via Control Center, and with the
      app backgrounded and reopened, the banner explains, the buffer restarts, and no broken clip is saved.
- [ ] **Camera error / camera taken while dimmed**: record with Dim on. (1) Open Camera.app from
      Control Center, take a photo, close it: RewindCam's banner says another app is using the camera,
      and recording resumes on its own (the buffer counter climbs again) without waking it. (2) Trigger a
      media-services reset (Settings › Developer › Reset Media Services, where the Developer menu
      offers it) while RewindCam is open and dimmed: within a few seconds it is recording again, or, if the
      camera can't restart within about 30 s, the screen wakes and shows "Not recording" with
      **Try Again**, which starts recording. It never stays on "Camera error … Restarting…" with the
      counter at 0 s.
- [ ] **Frame watchdog**: hard to provoke on purpose. During long Dim sessions (and the media-services
      reset above), the app must never show "REC" with the buffer counter frozen for more than about
      5 s: it either recovers by itself (orange "The camera was restarted" banner with the time) or wakes
      the screen with "Not recording" and **Try Again**. A save made while it happens finishes with a
      clip (toast "It ends early") or a message, never a toast that stays on "Saving…".
- [ ] **Thermal**: warm the phone (4K60, in the sun, while charging). At "serious" the orange banner shows
      and the preset label drops; when the phone cools it returns to your setting.
- [ ] **2-hour session**: Dim on, unplugged. Recording is still running after 2 h, the screen never
      locked, Save still works, and storage in Settings › General › iPhone Storage › RewindCam does not grow.
- [ ] **Battery drain per hour**: run 1 h unplugged with voice off, then 1 h with voice on. Read
      the "Measured battery drain" row in Settings each time and note both %/h figures.
- [ ] **Voice trigger**: "save that" saves a clip from about 2 m away; normal chatter doesn't.
- [ ] **Orphans**: force-quit while recording, relaunch, and the app's storage drops back to about the buffer size.
- [ ] **Photos denied, then retry**: on a fresh install, choose "Don't Allow" at the Photos prompt. An
      orange banner explains it. Tap Save: the toast says the clip is kept, and the banner says
      "1 clip isn't in Photos yet". Force-quit and relaunch: the banner is still there. Allow
      Photos in Settings › RewindCam › Photos, tap **Retry**: the clip appears in Photos, plays fully,
      and the banner goes away.
- [ ] **Microphone denied with "Record sound" on**: on a fresh install, allow the camera and choose
      "Don't Allow" at the microphone prompt. Recording starts, the buffer counter climbs, and an orange
      "Sound is off" banner says microphone access is denied. Save after 30 s: the clip plays, has no
      sound, and is about as long as the buffer. In Settings, "Record sound" is still on. With the voice
      trigger on, its "Listening" row says the microphone is denied. Tap **Open Settings**: RewindCam's
      page opens. Allow the microphone and return (iOS may relaunch the app): the banner is gone and the
      next clip has sound.
- [ ] **Camera denied**: on a fresh install, choose "Don't Allow" at the camera prompt. A red
      "Camera access is off" banner explains why the app needs it; the badge says OFF, Save is
      greyed out (VoiceOver reads why), and a volume-button press shows "Can't save" instead of saving.
      The Settings sheet still opens. Tap **Open Settings**: RewindCam's page opens. Allow the camera and
      return (iOS may relaunch the app): recording starts without relaunching by hand, the banner is
      gone, and Save works.
- [ ] **Nearly full phone**: fill the phone until under 200 MB is free (e.g. record 4K video in
      Camera.app) and launch RewindCam with the default settings. A red "Not recording: not enough free
      space" banner says how much to free, Save is greyed out, and no write error appears. In Settings,
      free space is shown and the 30 s buffer is marked as not fitting; choose 15 s and 720p: recording
      starts (with an orange "Storage is low" banner if a save may not fit). Save once: the clip is saved
      or the toast explains why not, never silently. Then, while recording, fill the phone further:
      within about 5 s of free space falling under 64 MB recording stops with the red banner. Free space
      and tap **Try Again** (or leave and return): recording starts. Clips waiting for Photos are never deleted.
- [ ] **Pause / Resume**: record 10 s, tap **Pause**: it asks before discarding the buffer; confirm.
      The camera indicator goes off, the badge says PAUSED, the blue banner explains, Save is greyed
      out, Dim is disabled, and the screen locks after the usual auto-lock time. Press a volume button:
      no clip is saved (the volume changes, or a "Can't save" toast appears). Switch to another app and
      back, and open Settings and come back: still paused. With Camera.app opened from Control Center
      while paused, closing it doesn't start RewindCam. On a fresh install, go to the Home Screen while
      the camera permission prompt is up, come back and answer it: recording starts once, with no
      "Camera access is off" flash. Right after a launch, tap Pause while the badge still says STARTING:
      it stays paused with no camera indicator. Tap **Resume**: REC returns and Save works. Force-quit
      while paused and relaunch: it records (the pause isn't kept).
- [ ] **Lock during save**: with +10 s post-roll, tap Save and lock the phone at once. After 30 s,
      unlock: the clip is in Photos (or, if not, offered for Retry), never silently gone.
- [ ] **Locked export (file protection)**: at 4K60 with a 120 s buffer and +30 s post-roll, record
      2 min, tap Save and lock the phone at once (passcode set, "Require Passcode: Immediately"). After
      2 min, unlock: the clip is in Photos or offered for Retry, never "Export failed". Repeat with Photos
      denied: lock, wait, unlock, relaunch: the kept clip is still offered and Retry adds it, and it plays.

## Development

- `project.yml` → `xcodegen generate` (never edit the `.pbxproj` by hand).
- Swift 6 (strict concurrency), SwiftUI, AVFoundation; minimum iOS 17.2.
- `-UITestMode` launch argument: synthetic camera, fake photo library in `Documents/FakePhotoLibrary`,
  fresh settings, no kept clips. Add `-UITestPhotosFailOnce` to make the first Photos save fail, or
  `-UITestDenyMicrophone` to make the synthetic source behave as if microphone access were denied.
  `-UITestDenyCamera` makes every start fail as if camera access were denied, until **Open Settings** is
  tapped (which stands in for allowing it there); `-UITestNoCamera` makes every start fail with "no camera".
  `-UITestLowDisk` makes free space read 90 MB: too little for the default buffer, enough for 15 s at 720p.
- CI ([`.github/workflows/ios.yml`](.github/workflows/ios.yml)): newest macOS runner and newest
  Xcode, iPhone simulator picked dynamically, `xcodebuild test`, then the unit tests four more times as a
  flake check. Per-test timeouts are on (180 s default, 300 s maximum), so a hung test fails by name
  instead of running into the 30-minute job timeout. The `.xcresult` bundle, screenshots, a summary,
  `xcodebuild.log`, `stress.log` and the app's simulator log (`simulator.log`) are always uploaded.
  Screenshots are also published to the hidden git ref `refs/ci/screenshots` (`git fetch origin refs/ci/screenshots`).
- Privacy manifest ([`RewindCam/Resources/PrivacyInfo.xcprivacy`](RewindCam/Resources/PrivacyInfo.xcprivacy)):
  no tracking, no collected data; declares the required-reason APIs the app uses (`UserDefaults`
  `CA92.1`, disk space `E174.1`). A unit test checks it is in the built app bundle.

## Task checklist

- [x] DESIGN.md: architecture and buffer math
- [x] Minimal green pipeline (XcodeGen, macOS 26 runner, newest Xcode, dynamic simulator, artifacts)
- [x] Rolling buffer engine: HLS-profile fMP4 segments, ring eviction, bounded disk
- [x] Save: concatenate → trim → passthrough `.mov`; early save; post-roll
- [x] Interruptions: buffer resets cleanly, no corrupt clips
- [x] Thermal step-down policy
- [x] Settings persistence
- [x] App model + SwiftUI UI (Save button, toast, haptic, settings, dim mode, battery)
- [x] Volume buttons via `AVCaptureEventInteraction` (needs a real device to verify)
- [x] UI tests with screenshots (`-UITestMode`)
- [x] Orphan cleanup on launch
- [x] Final README: screenshots, limits, device install
- [x] Stretch: on-device voice trigger ("save that") behind a setting, with measured battery drain

## License

MIT — see [LICENSE](LICENSE).
