# RewindCam — Design

RewindCam is a private, offline "pre-record" camera. It records all the time into a
rolling buffer of fixed length. When something happens, the user taps **Save** (or
presses a volume button) and the last *N* seconds, plus an optional post-roll, go to
Photos as one clip. The app has no network code, no accounts and no analytics.

## 1. Architecture

```
            ┌──────────────────────┐   CMSampleBuffer (video/audio)    ┌────────────────────────┐
            │ FrameSource          │ ────────────────────────────────▶ │ RollingRecorder        │
            │  • CameraFrameSource │        (SampleSink protocol)      │  AVAssetWriter         │
            │  • SyntheticFrame-   │                                   │  .mpeg4AppleHLS, 1 s   │
            │    Source            │ ── events (interrupted, …) ──┐    │  fMP4 segments ─▶ ring │
            └──────────────────────┘                              │    └──────────┬─────────────┘
                                                                  ▼               │ SegmentBundle
┌──────────────┐  settings / thermal / battery   ┌──────────────────────────┐    ▼
│ SwiftUI views│ ◀──────────────────────────────▶│ AppModel (@MainActor)    │ ─▶ ClipExporter
└──────────────┘                                 │  orchestrates everything │    (concat → trim →
                                                 └────────────┬─────────────┘     passthrough .mov)
                                                              ▼                         │
                                     PhotoLibrary (protocol)  ◀─────────────────────────┘
                                       • SystemPhotoLibrary (PHPhotoLibrary, add-only)
                                       • FakePhotoLibrary   (Documents/FakePhotoLibrary)
```

| Layer | Type | Testable via |
|---|---|---|
| Capture | `FrameSource` protocol: `CameraFrameSource` (AVCaptureSession) and `SyntheticFrameSource` (test-pattern `CVPixelBuffer`s + silent PCM) | `SyntheticFrameSource` in manual mode (frames generated as fast as the encoder takes them, with synthetic timestamps) |
| Buffer | `RollingRecorder` (writer + segment files) and `SegmentRing` (pure eviction policy) | unit tests, no camera needed |
| Export | `ClipExporter`: concatenate init + segments, trim with `AVMutableComposition`, passthrough export to `.mov` | unit tests load the result with `AVURLAsset` and decode every frame |
| Side effects | `PhotoLibrary`, `BufferStorage`, `BackgroundTasks`, `MediaClock`, `ThermalMonitor`, `BatteryMonitor`, `SettingsStore` (all protocols) | fakes in tests and in `-UITestMode` |
| UI | SwiftUI; `AppModel` is the single source of truth | XCUITest with `-UITestMode` |

### Threading (Swift 6 strict concurrency)

* `AppModel` and all views are `@MainActor`.
* `RollingRecorder` owns one serial `DispatchQueue`. Sources call `consume(_:kind:)`
  from their own capture queue, and it hops onto the recorder queue with `queue.sync`. That gives
  natural back-pressure (the synthetic source in tests cannot outrun the encoder) and keeps the
  writer single-threaded. The writer's segment delegate never blocks: it copies the `Data` and
  `async`s back onto the recorder queue.
* Classes that guard their state with a queue or lock are marked `@unchecked Sendable`, and the
  reason is written next to each one.

## 2. Rolling buffer

### Why HLS-profile fMP4 segments

The preferred design from the brief is kept: **one** `AVAssetWriter` with
`outputFileTypeProfile = .mpeg4AppleHLS` and `preferredOutputSegmentInterval = 1 s`.
The writer hands back an *initialization segment* (`ftyp`+`moov`) once, then one
*separable segment* (`moof`+`mdat`) per ~1 s through
`assetWriter(_:didOutputSegmentData:segmentType:segmentReport:)`.

* Each segment is a self-contained, independently decodable chunk that starts on a keyframe. The
  encoder is configured with `AVVideoMaxKeyFrameIntervalDurationKey = 1` and frame
  reordering off, so segments are ≈ 1 s and dropping the oldest one never breaks decoding of the rest.
* Eviction is just `unlink()` of the oldest file. Nothing is rewritten, so the cost per second is constant
  no matter how long the session runs (a 2-hour session does the same work every second as
  a 2-minute one).
* `init + segₖ + segₖ₊₁ + … + segₙ`, concatenated byte for byte, is a valid fragmented MP4
  that `AVURLAsset` can open. No re-encode is needed.

Alternatives I rejected: (a) rotating whole `.mov` files every *k* seconds needs two writers that overlap
to avoid gaps at the seams, and the save granularity is *k*; (b) keeping raw `CMSampleBuffer`s in RAM
costs too much memory at 4K and 120 s; (c) `AVCaptureMovieFileOutput` can't segment.

### Ring policy (`SegmentRing`, pure value type)

The ring keeps the **minimal suffix of segments whose total duration ≥ buffer length**. On
every new segment it drops the oldest segment while the remaining ones still cover the buffer.
It also enforces a hard **byte cap**: if bytes exceed the cap (an encoder overshoot), it drops the oldest
segment even if coverage falls below the buffer length. Retained duration is therefore in
`[N, N + one segment)`, about `N + 1 s`, and disk use for the ring is `≤ cap`.

### Save (pre-roll + post-roll)

1. On tap, the recorder notes `tap = PTS of the newest video frame`, and sets
   `end = tap + postRoll` and `start = tap − N`.
2. The save job immediately **hard-links** the retained segment files that overlap `[start, end]`
   into its own job folder (`link(2)` is O(1)). Later eviction from the ring then can't touch them,
   and the ring keeps evicting as usual. Each new segment that overlaps the range is linked as well.
3. The job completes when a segment whose end ≥ `end` has been written. A segment is only
   emitted when the *next* one starts, so the wait is about `postRoll + ≤1 s`. That is how the
   clip includes the moment of the tap itself.
4. `ClipExporter` streams `init + segments` into one `.mp4`, opens it with `AVURLAsset`, maps
   `[start, end]` onto the asset's track time range (a translation by the first segment's start,
   so it works whatever the writer's internal timeline origin is), inserts that range into an
   `AVMutableComposition`, and exports with `AVAssetExportPresetPassthrough` to `.mov`. Passthrough
   needs no re-encode, and the edit list makes the trim frame-accurate.
5. The export is written to `UnsavedClips/<name>.partial.mov` in Application Support and renamed
   to `<name>.mov` only when it is complete, so a `.mov` there is always whole. The job folder is
   then deleted. From here on the `.mov` is the clip's only copy, and it is durable.
6. Photos (add-only) gets a **hard link** of the `.mov`, staged in `Caches/RewindClips/photos-<uuid>/`.
   Photos may move or consume that link, even when it fails, without touching the kept copy. Only when
   Photos reports success is the `.mov` deleted (no extra bytes: the link shares the data).
7. If Photos fails (access denied or restricted, `performChanges` error such as low storage), the
   `.mov` stays. The user gets an error toast and a banner, "1 clip isn't in Photos yet", with the
   reason and a **Retry** button. Retry offers every kept clip again, oldest first, and stops at the first
   failure. The banner and the clips survive relaunches.

If less than *N* seconds is buffered (e.g. 4 s after launch), the clip is whatever exists.
Only one save can be pending at a time. A second tap during post-roll shows "Already saving".

### Save path: durability

The aim is that once Save has produced a clip, nothing but a successful Photos import deletes it.

* **Photos permission** is requested once per launch, right after the camera starts (camera and
  microphone prompts come first), not during the first save. The request is not awaited by the
  start/stop pipeline. If it is denied, a banner says how to allow it, and saves still keep their clips.
* **Background time.** Each save (from the tap to the end of the Photos import) and each Retry runs inside
  a `UIApplication.beginBackgroundTask` assertion, behind the `BackgroundTasks` protocol on
  `AppEnvironment` (`FakeBackgroundTasks` in tests counts begin/end pairs). Locking the phone or switching
  apps during post-roll resolves the save early (§ Interruptions) and the export and import then
  continue in background time. If iOS ends that time, the assertion is ended in its expiration
  handler; a clip already renamed to `.mov` survives suspension or termination and is offered on the
  next launch.
* **Launch cleanup** (`BufferStorage.removeOrphans`, run once per process before capture starts):
  deletes the ring, every save job folder and Photos staging folder in `Caches/RewindClips/`, and any
  stray `*.partial.mov`. It never deletes a finished `*.mov` in `UnsavedClips/`; those are listed for Retry.
* **What can still be lost**: a save whose process dies before its export finished (during
  post-roll or the few seconds of export). Its job folder holds only hard-linked segments with no
  manifest, and it is removed on the next launch. Finishing such jobs on relaunch would need a
  manifest written next to the segments; it is not implemented.
* **Duplicates over loss**: if the process dies after Photos accepted a clip but before the kept `.mov`
  was deleted, the clip is offered again and a Retry adds it to Photos a second time.

### Folders

| Folder | Location | Contents | Lifetime |
|---|---|---|---|
| `RewindBuffer/` | Caches | the ring: one `gen-N/` folder per writer generation (`init.mp4`, `seg-*.m4s`) | wiped on launch, interruption and quality change |
| `RewindClips/save-<uuid>/` | Caches | one save job: hard-linked `init.mp4` and segments, then `source.mp4` while exporting | deleted when the export ends (success or failure); wiped on launch |
| `RewindClips/photos-<uuid>/` | Caches | a hard link of a kept clip, handed to Photos | deleted after each Photos attempt; wiped on launch |
| `UnsavedClips/` | Application Support, excluded from backup | `*.partial.mov` (export in progress), `*.mov` (finished, not yet in Photos) | `.partial.mov` deleted on launch; `.mov` deleted only after Photos accepts it |

`BufferStorage` (`FileBufferStorage`) owns these paths. Tests point it at temp folders, and the
model tests treat "a new `AppModel` on the same storage" as a relaunch.

### Interruptions and generations

Every time the writer is (re)created, a new **generation** starts. That happens on the first frame, after an interruption, after
a settings change, or after a thermal step-down. A generation has its own init segment and its own
ring directory, because segments from different inits can't be concatenated.
On interruption (call, another app takes the camera, backgrounding, runtime error):

* the writer is cancelled, and a partial segment is never emitted, so no corrupt data can reach a clip;
* a pending save resolves right away with the segments already linked, or fails with
  "nothing buffered" if there are none;
* the ring directory is deleted and the buffer shows 0 s until frames arrive again.

The trade-off: a quality change (user or thermal) clears the buffer. That is simple and always
correct. The UI says so.

### Bounded disk

Bitrates are pinned per preset (`AVVideoAverageBitRateKey`), so disk use is predictable:

| Preset | Video | + AAC 64 kb/s | MB/s | 15 s | 30 s | 60 s | 90 s | 120 s |
|---|---|---|---|---|---|---|---|---|
| 720p30  | 5 Mb/s  | 5.064 Mb/s  | 0.633 | 9.5 MB | 19.0 MB | 38.0 MB | 57.0 MB | 76.0 MB |
| 720p60  | 7.5 Mb/s | 7.564 Mb/s | 0.946 | 14.2 MB | 28.4 MB | 56.7 MB | 85.1 MB | 113.5 MB |
| 1080p30 | 10 Mb/s | 10.064 Mb/s | 1.258 | 18.9 MB | 37.7 MB | 75.5 MB | 113.2 MB | 151.0 MB |
| 1080p60 | 15 Mb/s | 15.064 Mb/s | 1.883 | 28.2 MB | 56.5 MB | 113.0 MB | 169.5 MB | 226.0 MB |
| 4K30    | 35 Mb/s | 35.064 Mb/s | 4.383 | 65.7 MB | 131.5 MB | 263.0 MB | 394.4 MB | 526.0 MB |
| 4K60    | 50 Mb/s | 50.064 Mb/s | 6.258 | 93.9 MB | 187.7 MB | 375.5 MB | 563.2 MB | 751.0 MB |

(MB = 10⁶ bytes; size = bitrate ÷ 8 × seconds.)

**Ring cap** (`BufferMath.ringCapBytes`) = `rate × (N + 3 s margin) × 1.5`. The 1.5 covers VBR
peaks and container overhead, and the 3 s covers the extra segment held plus the one being written.
Example: 1080p30 with 120 s gives 1.258 MB/s × 123 s × 1.5 ≈ **232 MB**.

**Worst case during a save**: ring cap + post-roll segments (≤ 30 s × rate, hard-linked)
+ concatenated temp file (≤ clip) + exported `.mov` (≤ clip, in `UnsavedClips/`). For 4K60, 120 s and
30 s post-roll that is about 1.15 GB + 0.19 GB + 2 × 0.94 GB ≈ 3.2 GB for a few seconds. For the default (1080p30, 30 s,
no post-roll) it is about 60 MB + 2 × 38 MB ≈ 136 MB. The segments and the temp file are deleted as
soon as the export finishes; the `.mov` as soon as Photos has the clip. The Photos staging link adds no
bytes.

**Unsaved clips** are outside that bound: each clip that didn't reach Photos keeps its full size
(≤ (N + post-roll) × rate, e.g. 38 MB for the default, ≈ 0.94 GB for 4K60 with 120 s + 30 s) in
Application Support until a Retry succeeds. They are counted in `BufferStorage.unsavedClips()`
(`UnsavedClip.bytes`). The app never deletes them on its own; there is no in-app delete yet.

**Orphans**: `Caches/RewindBuffer/`, `Caches/RewindClips/` and stray `UnsavedClips/*.partial.mov`
are removed on every launch, before capture starts. They can only hold leftovers from a previous
process (crash, kill, OOM). Finished clips in `UnsavedClips/` are kept (see "Save path: durability").

## 3. Quality and thermal policy (`QualityGovernor`)

| Thermal state | Effective preset |
|---|---|
| nominal, fair | the user's preset |
| serious | one resolution step down (4K→1080p→720p) **and** 30 fps |
| critical | 720p30 |

The governor is a pure function, and `AppModel` applies it when `ProcessInfo.thermalState` changes.
The user's own setting is never overwritten. When the phone cools to fair or nominal, the user's preset comes back.
Each change restarts the writer (new generation), and the UI shows a banner such as
"Phone is hot — recording at 720p 30 fps".

## 4. Long sessions

* `UIApplication.isIdleTimerDisabled = true` while the camera runs.
* **Dim**: a black overlay at 92 % opacity, with screen brightness set to 0.02 (the previous value is restored when you tap to
  wake). The camera keeps recording under the overlay, and the volume buttons still save.
* Battery level and state come from `UIDevice` and are shown in the status bar ("—" in the Simulator).
* Background: iOS doesn't let third-party apps use the camera in the background, so the
  session stops and the buffer is cleared. The UI says so up front ("Keep RewindCam open — iOS
  can't record in the background"). On return to the foreground, capture restarts on its own.

## 5. Testing strategy

* **Unit tests** run the real `RollingRecorder` and `ClipExporter`, fed by a `SyntheticFrameSource` in
  *manual* mode. Frames carry synthetic timestamps, so 300 s of "recording" takes seconds and the
  results are deterministic (no wall clock is involved: every time value is a media timestamp).
* **UI tests** launch with `-UITestMode`: `SyntheticFrameSource` in real-time mode at a reduced
  resolution (the CI VM has no hardware encoder), a `FakePhotoLibrary` that writes into
  `Documents/FakePhotoLibrary`, and a fresh `UserDefaults` suite. A hidden-in-production label shows
  the fake library's clip count so XCUITest can check it. `FakePhotoLibrary` can deny access or fail
  the next saves; `-UITestPhotosFailOnce` makes the first save fail so a UI test can tap Retry.
* **Not covered by CI**: `CameraFrameSource`, `AVCaptureEventInteraction` (volume buttons),
  real thermal behaviour, real Photos (permission prompt, denial, `performChanges` errors),
  background-task time after locking the phone, and battery drain. See the manual checklist in the README.

## 6. Voice trigger (stretch)

* `SpeechVoiceTrigger` uses `SFSpeechRecognizer` (en-US) with
  `requiresOnDeviceRecognition = true`. If the device doesn't report
  `supportsOnDeviceRecognition`, the toggle is disabled. Audio never goes to a server.
* No second microphone session: a `SampleFanOut` sink passes the capture session's own audio
  samples to the recogniser (`SFSpeechAudioBufferRecognitionRequest.appendAudioSampleBuffer`).
  With voice on and "Record sound" off, the mic is captured for recognition only, and the
  recorder's writer still has no audio track.
* The recognition request is recycled every 50 s, after each final result or error, and after every trigger
  (so the transcript is cleared and the phrase can't fire twice). There is a 3 s cooldown.
* **One task at a time, by identity.** Each recognition request/task gets a generation number that
  its result handler carries. Only callbacks from the current generation may fire the trigger or
  recycle the task; recycling (and `stop()`) bumps the generation first, so the replaced task's late
  callbacks (its cancellation error, the final result from `endAudio()`, partials still containing
  the phrase) are ignored instead of cancelling the new task in a loop. `SFSpeechRecognizer` sits
  behind a small `RecognitionEngine` protocol and the 50 s timer reads an injected `WallClock`, so
  `SpeechVoiceTriggerTests` drive these callbacks with a fake engine. The real recogniser is still
  only exercised on a device.
* Phrase matching (`VoicePhrase`) is a pure function on word boundaries: "save that" and "save this".
* **Battery cost** can't be measured in CI (the Simulator has no battery). The app measures it instead:
  `BatteryDrainMeter` records battery level against an injected `WallClock` while recording
  unplugged, and Settings shows `%/h` labelled with the active configuration
  (e.g. "1080p 30 fps, voice on"). The meter restarts on any configuration change, so the
  on and off figures can be compared directly on a device.
