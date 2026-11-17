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
| Side effects | `PhotoLibrary`, `BufferStorage`, `BackgroundTasks`, `MediaClock`, `ThermalMonitor`, `BatteryMonitor`, `SettingsStore`, `AppSettingsOpener`, `DelayScheduler`, `DiskCapacityProvider` (all protocols) | fakes in tests and in `-UITestMode` |
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
`[N, N + one segment)`, about `N + 1 s`, and disk use for the ring is `≤ cap`. The cap holds even for a
single segment (issue #14): a newest segment that alone is over it is dropped too. The recorder refuses
such a fragment before it reaches the ring (see "Bounded disk" → "Queued fragment data"), so this only
matters when the cap shrinks in place; what the ring keeps is always one contiguous run.

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
model tests treat "a new `AppModel` on the same storage" as a relaunch. Each folder's protection
class and backup policy are in "File protection and backup" below.

### File protection and backup

**Decision.** Every media file and folder uses Data Protection class
`completeUntilFirstUserAuthentication` ("available after first unlock"), the iOS default for app files.
It is now set explicitly through one helper, `FileProtectionPolicy`, instead of being left implicit.
Nothing uses `.complete` or `.completeUnlessOpen`. The durable folder `UnsavedClips/` is excluded from
backup; the expendable folders stay in Caches, which iOS never backs up. This keeps #1's goal: a save
started before the phone locks can finish, or at least keep its clip, while the phone is locked.

**What iOS does on lock.** Locking the phone sends RewindCam to the background. iOS doesn't let it use
the camera there, so capture stops: the writer is cancelled, the ring folder is deleted, and a pending
save resolves early with what is already linked (§ Interruptions). From then on no buffer file is
written. The save itself keeps running inside its `beginBackgroundTask` assertion (typically about 30 s,
not guaranteed), and *after* the lock it must:

1. reopen the hard-linked `init.mp4` and segments (same inodes as the ring files) to concatenate them;
2. create `source.mp4`, close it, then reopen it with `AVURLAsset`;
3. have `AVAssetExportSession` create and write `<name>.partial.mov`, then reopen it to read the duration;
4. rename it to `.mov`, hard-link it into `photos-<uuid>/`, and let Photos read (and move) that link.

What each class allows after the lock ([Apple: Encrypting your app's files](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files),
[`FileProtectionType`](https://developer.apple.com/documentation/foundation/fileprotectiontype),
[Apple Platform Security: Data Protection classes](https://support.apple.com/guide/security/secb010e978a/web)):

| Class | After the phone locks | Steps 1–4 |
|---|---|---|
| `.complete` | the class key is discarded about 10 s after the lock; no file in the class can be read or written, even one already open | all fail if the save outlasts those ~10 s (post-roll, a long or 4K export) |
| `.completeUnlessOpen` | files can be created and an open file stays usable, but a closed file can't be reopened | 1, 2 (reopen), 3 (reopen) and 4 (Photos opens the file) fail |
| `.completeUntilFirstUserAuthentication` | readable and writable from the first unlock after boot until shutdown, locked or not | all work |

So `.complete` or `.completeUnlessOpen` would turn "lock the phone during a save" from "the clip is in
Photos or kept for Retry" into "export failed" (#5, "Considered and left out"). Launch and recovery need
no more than that: RewindCam has no background modes, so iOS never runs it before the first unlock, and
launch cleanup and the Retry list only read names and sizes (file-system metadata, which the class
doesn't protect).

**Inventory.**

| Files | Where | Created by | Kind | Needed while locked | Class: how it is ensured | Backup | Cleanup |
|---|---|---|---|---|---|---|---|
| ring generation `gen-N/` | `Caches/RewindBuffer/` | `RollingRecorder` via `FileProtectionPolicy.prepareDirectory` | disposable | no new writes, but its files are the save job's inodes | set on the folder | no (Caches) | on interruption, quality change, launch |
| `init.mp4`, `seg-*.m4s` | `gen-N/` | `Data.write` (plain, not atomic) from the writer delegate | disposable | yes, through the save job's links (step 1) | inherited from `gen-N/` | no (Caches) | evicted by the ring; launch |
| save job `save-<uuid>/` with linked `init.mp4` and segments | `Caches/RewindClips/` | `prepareDirectory` + `linkOrCopy` | disposable (save in flight) | yes (step 1) | a hard link *is* the ring file (same inode, same class); the copy fallback is a new file and gets the class set explicitly (`FileProtectionPolicy.copyItem`) | no (Caches) | when the export ends; launch |
| `source.mp4` | `save-<uuid>/` | `ClipExporter.concatenate` (`createFile` + `FileHandle`) | disposable | yes (step 2) | inherited from `save-<uuid>/` | no (Caches) | when the export ends; launch |
| `<name>.partial.mov` | `Application Support/UnsavedClips/` | `AVAssetExportSession` | disposable until renamed | yes (step 3) | inherited from `UnsavedClips/`, then set explicitly in `commitPartialClip` (framework-created file) | excluded | on export failure; launch |
| `<name>.mov` | `UnsavedClips/` | rename of the partial (same inode, class kept) | **committed user save** | yes (step 4: the save's own Photos import) | set before the rename; re-applied to every kept clip at launch (`removeOrphans`) | excluded | only after Photos reports success, never otherwise |
| `photos-<uuid>/<name>.mov` | `Caches/RewindClips/` | `stageForPhotos` (`prepareDirectory` + `linkOrCopy`) | disposable link (the kept `.mov` is what matters) | yes (step 4) | the link is the kept clip's inode; copy fallback set explicitly | no (Caches) | after each Photos attempt; launch |
| folders `UnsavedClips/`, `RewindBuffer/`, `RewindClips/` | | `FileProtectionPolicy.prepareDirectory` | folders | yes | set explicitly, re-applied at every launch | `UnsavedClips/` excluded, re-marked before every export | never removed |

Photos-owned copies are never touched: once Photos accepts a clip, the app only deletes its own `.mov`.

**How the class is ensured, and checked.**

* *Folders* get the class explicitly, and files created inside inherit their folder's class (Apple DTS:
  "Files written to a directory default to that directory's data protection",
  [forum thread 706258](https://developer.apple.com/forums/thread/706258)). Plain `Data.write`,
  `createFile` and `FileHandle` writes rely on this.
* *Hard links* share one inode, so one class. They are never treated as separate copies, and setting
  the class through either name changes both. Tests check inode numbers and link counts.
* *Copies* (the link-failure fallback) are new files, which developers report don't reliably inherit,
  so they get the class set explicitly.
* *Atomic writes and framework output* (a temporary file renamed into place, or whatever
  `AVAssetExportSession` does internally) may take their class from wherever the temporary file was
  created. The app makes no atomic writes to media, and `commitPartialClip` sets the class on the export
  before renaming it. A rename (`moveItem` within one volume) keeps the inode and its class.
* Setting a class is best effort (`FileProtectionPolicy.apply` returns false and never fails a save).
  If it fails, the file keeps the platform default, which is the same class. Being explicit matters if
  the app-wide default is ever raised (the Data Protection capability, entitlement
  `com.apple.developer.default-data-protection`): RewindCam's folders would keep the lock-safe class
  instead of silently breaking saves after a lock.
* `FileProtectionTests` creates every file kind above through the real code paths (ring writes,
  `linkOrCopy`, the copy fallback, `concatenate`, an atomic write committed with `commitPartialClip`,
  `stageForPhotos`) and reads back `URLResourceValues.fileProtection`; wherever the file system reports a
  class, it must be the media class. A strict variant requires every file to report the media class; it
  runs wherever classes are reported at all. *Observed in CI* (iOS 26.5 Simulator): the Simulator
  reports classes, and every file kind above read back as `completeUntilFirstUserAuthentication`. That
  checks the metadata only, and since this class is also the default it can't tell inheritance from
  default. **The Simulator does not enforce Data Protection**: a "locked" Simulator still reads every
  file. Lock behaviour is a device check (README checklist).

**Errors.** With this class a protected-data error can only happen before the first unlock, when
RewindCam can't run. If one happened anyway (for example after a future class change), it surfaces as a
failed export ("Export failed: …"; the partial is deleted and nothing claims success) or as a failed
Photos import (the `.mov` is kept and offered for Retry). No error path deletes a committed `.mov`.

**Backup.**

* `Caches/RewindBuffer/` and `Caches/RewindClips/` hold only disposable data. iCloud Backup excludes
  Caches ([Apple: Optimizing your app's data for iCloud backup](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)),
  iOS may purge it when storage is low, and the app wipes it at launch anyway.
* `Application Support/UnsavedClips/` holds committed saves, so it is outside Caches and never
  auto-deleted. It is marked `isExcludedFromBackup` (on the folder, which covers its contents; Apple notes
  that some file operations reset the flag, so it is re-marked at launch and before every export).
  Why excluded: clips are large (up to ~0.9 GB each) and are meant to stay only until Photos has them;
  Photos is where the user's backup (iCloud Photos or a device backup) takes over.
* The user's side of that: a clip still waiting in RewindCam is **not** in a device backup and does not
  move to a new or restored phone. The banner and Retry exist to get it into Photos; the README says so.

**Risks and trade-offs.**

* "Available after first unlock" means a phone that was unlocked once since boot and then locked (and,
  say, stolen) still holds the class key in memory. Kept clips are the most sensitive files here and the
  ones that can stay longest.
  *Possible follow-up, not enabled:* raise kept `.mov` files to `.complete` after their first Photos
  attempt fails, and lower them again before a Retry. Costs: a Retry started just before a lock fails
  after ~10 s (the clip is kept, nothing lost); the class can only be changed while unlocked; and a Photos
  import that holds a link to the same inode could end up with a `.complete` file. It is a trade-off for
  the owner to choose, not a silent default.
* Photos imports with `shouldMoveFile`, so it moves the staged hard link and may change the shared
  inode's attributes. The app never sets anything on a clip Photos has accepted (it only deletes its own
  name) and re-applies the media class to kept clips at launch.
* `isExcludedFromBackup` is a hint, not a guarantee (Apple).
* Background time (about 30 s, at the system's discretion) still limits a save after a lock, whatever
  the class: a save killed before its rename loses that clip (§ Save path: durability).
* None of this has been checked on a device yet.

### Interruptions and generations

Every time the writer is (re)created, a new **generation** starts. That happens on the first frame, after an interruption, after
a settings change, or after a thermal step-down. A generation has its own init segment and its own
ring directory, because segments from different inits can't be concatenated.
On interruption (call, another app takes the camera, backgrounding, runtime error):

* the writer is cancelled, and a partial segment is never emitted, so no corrupt data can reach a clip;
* a pending save resolves right away with the segments already linked, or fails with
  "nothing buffered" if there are none (when video stops without any interruption, the frame watchdog
  settles it the same way, see "Frame watchdog");
* the ring directory is deleted and the buffer shows 0 s until frames arrive again.

The trade-off: a quality change (user or thermal) clears the buffer. That is simple and always
correct. The UI says so.

### What the source delivers (microphone denied)

`FrameSource.start` returns an `ActiveCapture`: whether audio samples will actually reach the sink,
and if not although they were requested, why (`.microphoneDenied`, or `.microphoneUnavailable` when
there is no mic or its input or output can't be added). Only a missing camera throws. `AppModel.bringUp`
suspends the recorder, starts the source, and only then configures the writer, with an audio input
only if "Record sound" is on **and** `audioCaptured` is true. This matters because a segmenting
`AVAssetWriter` with an audio input that never receives samples stalls: in CI (Simulator), 6 s of
video into such a writer produced no segment at all, with real-time inputs as in the app and with
non-real-time ones, so the buffer stayed at 0 s and every save failed with "Nothing is buffered yet". The
same frames without the audio input produce segments (`RecorderTests.writerAudioInputWithoutSamples`
keeps both as a regression test). When sound or the voice trigger wanted
the microphone and didn't get it, `AppModel.microphoneNotice` produces an `AppNotice` ("Sound is off",
"The voice trigger can't listen", or both) rendered by `NoticeBanner` with an **Open Settings** button;
the voice trigger isn't started and its Settings row says why; the settings themselves are untouched.
`AppNotice`/`NoticeBanner` and `AppModel.openAppSettings()` (via the `AppSettingsOpener` protocol on
`AppEnvironment`, `FakeAppSettingsOpener` in tests) are the one "go to Settings" path, reused for camera
access below. The next start re-reads the permission, so allowing the mic and returning restores sound.

### Start failures (camera denied)

`FrameSource.start` throws only when video can't be captured. `AppModel.bringUp` hands the error to
`startFailed`, which stops the source (a failed reconfigure may leave a half-built session), lets the
screen lock again and sets one of two phases:

* `.cameraDenied` for `FrameSourceError.cameraAccessDenied`: `startFailureNotice` is a red
  "Camera access is off" `AppNotice` that says why the app needs the camera, with **Open Settings**
  (the same `AppNotice.Action.openSettings` as the microphone notice);
* `.failed(message)` for anything else (`.noCamera`, `.configurationFailed`): the notice shows the
  message with **Try Again** (`AppNotice.Action.tryAgain` → `AppModel.retryStart()`).

There is no separate restart path. Recovery is always a new `bringUp` queued on the pipeline by
`start()`: Try Again (ignored unless the last start failed, so a double tap makes one attempt), or
`scenePhaseChanged(.active)`, which starts when not running *or* when the last start failed. Leaving
for the Settings app normally goes through `.background` (stop) and back (start); the explicit
failed-phase check covers an `.active` without a background trip, e.g. right after a permission prompt.
While a start has failed, source events are ignored (nothing to pause or resume) and
`saveUnavailableReason` disables Save; it is non-nil in every phase but `.recording`, because the
recorder is suspended and holds nothing then. A save from the volume buttons shows it as a toast.
Runtime recovery (next section) reuses this: when its restarts give up it calls `startFailed`, so
leaving that state is again only a new `bringUp`.

### Event ordering and recovery (issue #4)

Capture state changes from two places, and each has exactly one path:

* **Session mutations** (start, stop, reconfigure, recovery attempts) go through
  `AppModel.schedulePipeline`, which runs one piece of work at a time, in order. `pipelineDepth`
  counts work queued or running.
* **Source events** (`FrameSourceEvent`, emitted on any thread) go through one ordered channel: the
  handler given to `FrameSource.setEventHandler` only yields into an `AsyncStream`, and a single
  main-actor task created in `AppModel.init` consumes it and calls `handle(_:)`. Events are therefore
  handled in emission order (the old one-`Task`-per-event forwarding could swap an `.interrupted`
  and its `.interruptionEnded`, leaving the recorder suspended while the session ran).
  `handle` records the event in `sourceInterruption`; if no pipeline work is pending it applies it at
  once (`applySourceState()`: suspend + `.paused(message)`, or resume + `.recording`), otherwise the
  last piece of pipeline work applies it when it finishes, so an event never lands in the middle of a
  start or stop. While a start has failed (`phase.isStartFailure`) events are ignored: the source was
  stopped and only `start()` leaves that phase. Tests wait on the channel with
  `waitForCaptureEvents()` (a barrier item) and `waitForCapture()` (pipeline and channel until both
  are idle).

**Recovery entry point: `AppModel.recoverCapture(_ reason: CaptureRecoveryReason)`.** It suspends the
recorder, sets `.paused(reason.pausedMessage)` ("Camera error: … Restarting…"), and, unless a
recovery is already running (whose budget then continues), starts one (`recovery`, with an id).
Each attempt runs on the pipeline and calls `FrameSource.resumeRunning()`, which starts the session
again with its current configuration if it is stopped, and emits `.interruptionEnded` and returns
true whenever it runs afterwards, including when it never stopped (the old code returned silently in
that case, and never retried when `startRunning()` didn't take). Attempts follow `RestartBackoff`, a
pure value: immediately, then after 1, 2, 4, 8 and 15 s (6 attempts, about 30 s). Timers use
`environment.scheduler` (`DelayScheduler`; `FakeDelayScheduler` in tests, so no test sleeps). Each
timer and attempt checks the recovery id and `automaticCaptureAllowed`, so a stop, background, new
start or ordinary interruption (which iOS ends itself) supersedes it without a race. When the
budget is spent the model wakes the screen from Dim, plays the failure haptic and calls
`startFailed(.restartFailed(...))`: capture stops, the idle timer is re-enabled and the phase is
`.failed("The camera stopped (…) and couldn't be restarted.")` with Try Again. Callers: a
runtime-error event (`.runtimeError`), the safety net (`.sourceStopped`) and the frame watchdog
(`.stalled`, next section), whose restart action in `restartSource(for:)` is a full stop and start
(a stalled source still "runs"), not a second restart path.

**Safety net: `AppModel.reconcileCapture()`**, run by `statusTick()` every 0.5 s (the status loop,
also on `environment.scheduler`). It compares `FrameSource.runState` (`.running`, `.interrupted`,
`.stopped`; for the camera, `isRunning`/`isInterrupted`) with phase and recorder:
running but the recorder suspended or the phase paused → resume; interrupted while recording → pause;
stopped while recording or paused, with no recovery running → `recoverCapture(.sourceStopped)`. It
does nothing while pipeline work runs or capture isn't wanted. The frame watchdog runs right after it.

**User pause (#15):** every automatic path (event application, `recoverCapture`, recovery timers and
attempts, the safety net, the frame watchdog, the free-space check) checks `automaticCaptureAllowed`,
which is `wantsRunning && !isUserPaused`; "User pause" below adds capture generations on top. There
is still one event stream and one restart path.

`SyntheticFrameSource` simulates all of it: `simulateRuntimeError(_:sessionStops:)` (case (a): the
session keeps running; (b): it stops), `setResumeFailures(n)` (the next n restarts fail),
`setRunStateSilently(_:)` (a missed notification), `resumeCount`. Not covered by CI: whether a real
`AVCaptureSession` after a runtime error or a media-services reset behaves as modelled (README checklist).

### User pause (issue #15)

RewindCam still starts recording on launch and resumes on its own when it returns to the foreground.
On top of that the user can **Pause** (the capsule above Save) and **Resume**. An explicit pause is
authoritative: nothing automatic ends it, only Resume.

* **Intent.** `wantsRunning` is the lifecycle's wish (false in the background); `isUserPaused` is the
  user's. `automaticCaptureAllowed` = `wantsRunning && !isUserPaused` gates every automatic path, and
  `start()` itself does nothing while paused, so launch-time `.active`, foreground, Try Again
  (`retryStart`) and the out-of-space settings retry can't override it. `Phase.userPaused` is a phase
  of its own, distinct from `.paused(reason)` (an interruption iOS ends, or a recovery under way):
  badge "PAUSED" with a pause icon (VoiceOver: "Paused by you"), and a blue `AppNotice`
  (`userPausedNotice`) saying the camera is off, the unsaved buffer was discarded, saved clips and
  clips waiting for Photos are kept, and that it lasts until Resume. `tearDown` keeps `.userPaused`
  when the app is backgrounded while paused, so the trip doesn't turn it into "Paused — iOS can't
  record in the background".
* **Pause** (`pauseCapture()`) does everything that matters synchronously, before any `await`: bumps
  the capture generation, ends any recovery (its timers then find no current recovery), disarms the
  frame watchdog, clears the stall and disk notices, stops the voice trigger, suspends the recorder
  (the rolling buffer is deleted; a save waiting for its post-roll is settled with what is there and
  its export carries on), wakes the screen from Dim, re-enables the idle timer and sets `.userPaused`.
  Then it queues `tearDown` on the pipeline, which stops the source after whatever session work is
  running. If footage is buffered the button asks first ("Pause recording?": the last N s haven't been
  saved and will be discarded; saved clips are kept).
* **Generations.** `captureGeneration` is bumped by every change of intent: `start()`, `stop()`,
  `pauseCapture()`, `resumeCapture()`. `bringUp(generation)` checks `isCurrent(generation)` (current
  generation *and* `automaticCaptureAllowed`) before it starts and after every `await`: after the
  free-space stop, after `FrameSource.start` returns (for the camera that includes the permission
  prompt) and after it throws. A stale start publishes nothing (not `.recording`, not `.cameraDenied`,
  no voice trigger, no Photos prompt, no idle-timer change) and stops what it started
  (`stopCapture()`); the newer intent's own work is already queued behind it. A recovery records the
  generation it began in, and `isCurrentRecovery(id)` (same id, current generation, capture allowed)
  is checked by every backoff timer, before an attempt, after its restart returns, and by the give-up.
  `startFailed` and `stopForResources` (low disk, recorder halt #14) re-check `automaticCaptureAllowed`
  after their `await`, so a pause that lands while they stop the source keeps its phase. The voice
  trigger's authorization callback is already guarded by `voiceSession`, which every stop (a pause
  included) bumps.
* **Serialized.** Pause, Resume, background and foreground only queue pipeline work, which runs one
  piece at a time, so rapid toggling settles on the newest intent: stale starts are skipped at their
  first check or undone at their second, and only one session start is in flight at any moment.
  `tearDown` shows `.starting` rather than `.idle` when a start is queued behind it.
* **Late events.** Interruption ends, runtime errors and what the safety net sees while paused update
  `sourceInterruption` at most; `applySourceState`, `recoverCapture` and `reconcileCapture` return
  early. Resume starts afresh (`bringUp` clears `sourceInterruption`). The frame watchdog stays disarmed
  while paused and re-arms on the first status tick after Resume, with that moment as its baseline and
  a fresh stall budget (`start()` calls `forgetStalls()`). The free-space check doesn't read while
  paused; Resume checks free space like a launch and may show the out-of-space notice.
* **Controls.** Save (button, volume buttons, voice) goes through `save(trigger:)`, which refuses while
  `saveUnavailableReason` is non-nil: "Recording is paused. Tap Resume to record again." The button is
  disabled with that hint; the volume buttons and a stale voice callback get a "Can't save" toast and
  the failure haptic. Dim is disabled while paused (`setDimmed(true)` is ignored): nothing is recorded,
  so the screen should be allowed to lock. Settings changes and thermal steps while paused start
  nothing. Retry for clips waiting for Photos keeps working. The preview is black while paused
  (`PreviewSurface`), so a frozen last frame can't pass for a live picture.
* **Not persisted across relaunch.** The pause lives in memory. A relaunch (including after iOS ends
  the app in the background) records as before: issue #15 keeps the launch and foreground defaults and
  rules out persisting a new default recording mode, and a persisted pause would turn a cold launch
  into a stopped camera the user may not notice, the opposite of the app's job of having the last
  moments ready. Within the running app the banner says it lasts "until you tap Resume"; README's
  known limits say that a relaunch records again.

Tests (`UserPauseTests.swift`, harness time, no sleeps): `SyntheticFrameSource.holdNextStart()` holds
the next `start` (as a permission prompt or slow start would) until `releaseHeldStart()`, with
`waitForHeldStart()` to know it is waiting. Covered: pause stops everything and refuses Save from
every trigger while kept clips stay; the pause holds across inactive/active, a Settings round trip,
Try Again, `start()` and 30 s of ticks; pause during a pending start, during a permission prompt
answered "Don't Allow" or "Allow" afterwards; background during a pending start (default behaviour
kept); rapid pause/resume/background/foreground; pause during recovery backoff and during a stall
restart's start (the watchdog re-arms after Resume); interruption ended while paused; Try Again
queued just before Pause; a low-disk stop queued just before Pause; no persistence across a relaunch.
UI test `testPauseHoldsAcrossBackgroundUntilResume`: Pause, confirm, banner and disabled Save, to the
Settings app and back, still paused, Resume, REC, Save. Not covered by CI: the real camera permission
prompt and real interruption timing around a pause, and the volume buttons while paused (README
checklist).

### Frame watchdog (issue #9)

Nothing else notices if frames simply stop: the session still "runs", the phase stays `.recording`,
and the ring holds footage that gets older every second (a stalled capture output after a
media-services reset, a writer that is never ready and drops every frame, a writer that keeps failing
and restarting). `FrameWatchdog` (pure value, `RewindCam/Model/FrameWatchdog.swift`) is fed the
recorder's `RecorderStatus` on every status tick by `AppModel.checkFrameWatchdog()`, which runs in
`statusTick()` after the safety net:

* **Signals.** Progress is `latestMediaTime` (PTS of the newest *video* frame appended to the writer;
  audio never touches it, so a microphone that keeps delivering can't mask a dead camera) and
  `lastSegmentEnd`. **`.noVideo`**: no new video frame for `FrameWatchdog.timeout` = **5 s**.
  **`.noSegments`**: video kept arriving for 5 s after the last new segment (when the camera itself
  stops, segments stop a moment before frames do, and that is `.noVideo`). 5 s because frames normally
  come every 17–33 ms and segments every second (a new writer's first one after 1–2 s); it is far
  outside any normal gap, the check runs every 0.5 s (detection 5–5.5 s after the last frame), and it
  keeps the time the app shows "REC" over a frozen buffer short next to the shortest buffer (15 s).
* **Time** is `AppEnvironment.monotonicClock` (`MonotonicClock`): live, `HostMonotonicClock`, the Core
  Media host clock (`CMClockGetHostTimeClock`, the clock capture timestamps use, already read by
  `HostMediaClock`), so a wall-clock change can't fake or hide a stall. It is not one of Apple's
  "system boot time" required-reason APIs (`ProcessInfo.systemUptime`, `mach_absolute_time()`), so the
  privacy manifest is unchanged. In tests the harness's `FakeDelayScheduler` is the clock, so the
  status loop and the time it measures advance together and no test sleeps.
* **Generations.** Every writer has a generation number. A newer generation with a frame is progress; a
  snapshot from an older generation than one already seen is stale and ignored, as is every generation
  the recorder held before the watchdog was armed on an empty recorder (after a suspend), so nothing
  from before a restart counts as new video.
* **No false positives.** It is armed only while capture is wanted (`automaticCaptureAllowed`), the
  phase is `.recording`, the source runs, the recorder isn't suspended, and no recovery or pipeline
  work is pending; any tick where that isn't so disarms it, and so do `bringUp`, `tearDown`,
  `startFailed`, `applySourceState` (pause or resume), `recoverCapture` and `applyQuality` (settings
  and thermal changes), because a whole restart can finish between two ticks. The first tick after
  re-arms it with the recorder's current state as baseline, so every start, restart, interruption or
  reconfiguration gets the full 5 s (a new generation legitimately has no frame for a moment).
* **On a stall** the model first settles a save that is waiting for its post-roll
  (`RollingRecorder.settlePendingSave()`): the post-roll will never arrive, so the save gets the
  segments already linked (the toast says the clip "ends early"), or, if none, fails with
  `RecorderError.videoStopped` ("…Save again once RewindCam shows REC"). A ticket is fulfilled at most
  once, so a later suspend can't settle it again. Then `recoverCapture(.stalled(kind))`: recorder
  suspended, phase `.paused("No new video for 5 s. Restarting the camera…")`, and
  `restartSource(for:)` stops and starts the source with the current configuration (keeping the
  recovery and the phase; a failed start backs off like any other attempt). While a stall recovery is
  pending, neither a stale "running again" event nor the safety net's "running but paused" case ends
  it: a stalled source reports `.running` all along, so only its restart counts.
* **Bounded.** One automatic restart per stall episode (`automaticRestartsPerStall`). If the restarted
  source stalls again before 30 s of stall-free recording (`recoveredAfter`) end the episode,
  `recoverCapture` starts the recovery with a spent budget (`RestartBackoff.spent`), so it gives up at
  once through the same path as #4: screen woken from Dim, failure haptic, `startFailed(.restartFailed)`
  → "Not recording — The camera stopped (no new video arrived for 5 s) and couldn't be restarted." with
  Try Again. A user start (launch, foreground, Try Again) begins a new episode. A camera that delivers
  a few frames after each restart and stops again therefore can't make the app restart forever.
* **Audio without video.** The recorder drops audio more than `RollingRecorder.maxAudioLead` (1 s)
  past the newest video frame. The writer interleaves audio with video, so when the camera stops and
  the microphone doesn't, audio can only pile up in it. The UI test caught the consequence: appends
  blocked the recorder queue, so the watchdog's own `suspend()` froze the main thread at the moment
  of the stall. Capture delivers both on one clock within a few hundred ms, so normal audio is untouched.
* **Telling the user.** After a restart that works, `AppModel.stallNotice` (orange `AppNotice`, no
  action) says that video had stopped, when the camera was restarted, and that the footage from before
  is gone; it clears once the buffer is full again, or when capture stops or restarts from the user.
  The successful restart doesn't wake the screen (unattended use); giving up does.
* **User pause (#15).** The watchdog only runs while `automaticCaptureAllowed`, and its recovery goes
  through `recoverCapture`, whose timers and attempts check it too. Pause also disarms it at once and
  ends any stall recovery, and a stall restart whose start completes after Pause is dropped (see
  "User pause"). After Resume it re-arms on the first tick with a fresh baseline and stall budget.

`SyntheticFrameSource.withholdVideo(_:)` simulates the stall: frames keep their place on the timeline
but never reach the sink, audio still does, and `runState` stays `.running`. Tests:
`FrameWatchdogTests.swift` (policy, settling a pending save in the recorder, and the model: one restart
then Try Again, recovery and the notice, audio not masking, post-roll settling once, and no stall
across launch, settings and thermal restarts, background and interruptions). Not covered by CI:
whether a real `AVCaptureSession` stalls like this and whether a stop and start cures it.

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

**Worst case during a save** (nominal sizes, what #10's free-space checks use): ring cap + post-roll
segments (≤ 30 s × rate, hard-linked) + concatenated temp file (≤ clip) + exported `.mov` (≤ clip, in
`UnsavedClips/`). For 4K60, 120 s and 30 s post-roll that is about 1.15 GB + 0.19 GB + 2 × 0.94 GB ≈ 3.2 GB
for a few seconds. For the default (1080p30, 30 s, no post-roll) it is about 62 MB + 2 × 38 MB ≈ 138 MB.
The segments and the temp file are deleted as soon as the export finishes; the `.mov` as soon as Photos
has the clip. The Photos staging link adds no bytes.

#### Working-set budgets (issue #14)

The ring cap bounds the ring, but a save adds its own files, and fragment data waits in memory before
it is written. Two separate budgets, both derived from the same settings as the ring cap
(`BufferMath.swift`, "Working-set budgets"):

**Queued fragment data (memory).** The writer delegate hands each fragment over as a `Data` and returns at
once; the fragment then waits for the recorder queue, which writes it. Before the delegate retains it,
it is admitted against `FragmentQueueLimit` (`BufferMath.fragmentQueueLimit`): at most **8 fragments**
(≈ 8 s of writes the disk hasn't kept up with) and **max(16 MB, 4 s × rate × 1.5)** bytes (4K60:
37.5 MB; every 1080p and 720p preset: 16 MB), and no single fragment larger than that or the ring cap.
Healthy storage keeps the queue at 0–1. The counters (`RollingRecorder.fragmentQueue()`) are
thread-safe; every admitted fragment is released exactly once, when its queue block ends (written,
stale, refused or failed), and the delegate never blocks.

*At the bound* (or for one oversized fragment) the fragment is let go at once, every later fragment of
that writer is refused too, and on the recorder queue its generation **stops**: the writer is cancelled,
the ring folder deleted, and a save waiting for its post-roll is settled once with the contiguous footage
it already has (fragments queued after the refusal point are dropped, so there is never a hole that an
export could span). The recorder then **halts** (`RecorderHalt.backlog`, in `RecorderStatus.halt`):
it ignores samples until `resume()`/`reset()`, so the same shortage can't become an automatic restart
loop. A segment that fails to write (`RecorderHalt.writeFailed`, usually a full disk) is handled the
same way instead of being skipped. `AppModel` sees the halt on the next status tick (0.5 s, before the
frame watchdog could mistake it for a stall) and stops capture: below #10's reserve it is the
out-of-space stop, otherwise **"Not recording"** with the reason and **Try Again**. A stale writer's
late callbacks are admitted, dropped and released; they can't recreate a deleted generation folder.

**Temporary media on disk.** `BufferMath.temporaryMediaCapBytes` = ring cap + one save's job folder
(`saveBundleCapBytes`: the ring cap for `N + postRoll` seconds) + its export output (source + 5 % +
256 kB). While `source.mp4` is written the job's segments still exist (ring + job + source ≤ ring +
2 × job); then they are deleted and the output is written (ring + source + output). Both fit the cap.
Only one save runs at a time. Kept clips are not temporary and come on top.

| Settings | Ring cap | Save job cap | Export output | **Temporary cap** | #10 estimate |
|---|---|---|---|---|---|
| 1080p30, 30 s, no post-roll (defaults) | 62.3 MB | 62.3 MB | 65.6 MB | **190 MB** | 138 MB |
| 4K60, 120 s, +30 s | 1.15 GB | 1.44 GB | 1.51 GB | **4.1 GB** | 3.2 GB |

The cap is higher than #10's estimate because it applies the 1.5 overhead factor everywhere; it is the
bound, the estimate is the usual size. Each part is enforced where it is written:

* **Ring**: `SegmentRing`'s strict cap; no admitted fragment is larger than the cap.
* **Save job folder**: hard links cost nothing. If a link fails (another volume, or a file system without
  links), the segment is copied, but only if `TemporarySpace` grants its size above the reserve; linking
  runs newest first, so what doesn't fit is the oldest footage. A post-roll segment that would take the
  folder past its cap, or whose copy has no room, settles the save early (`SaveLimit`).
* **Export**: before anything is written, `AppModel.exportDurably` asks `DiskSpacePolicy.exportAdmission`
  how much of the bundle fits, from the sizes of the files on disk: the newest segments whose source +
  output fit in free space above the save floor. All of it, a newer part (the clip still ends where asked
  and starts later), or none ("Nothing was saved … free up about X"). The peak is then reserved in
  `TemporarySpace` until the export ends, and passed to `AVAssetExportSession` as `fileLengthLimit`.
* **Photos staging**: a hard link (0 bytes); a copy only if linking fails, admitted like the rest. If it
  doesn't fit, the clip stays kept for Retry.

**Measured, not only estimated.** `BufferStorage.measureWorkingSet()` enumerates the folders and reports
`MediaWorkingSet`: ring, save jobs (copies, links to segments the ring has since evicted, `source.mp4`),
exports (`.partial.mov`), staging copies, and kept clips separately. Each physical file counts once
(same device and inode): a save's link to a ring segment, or a staging link to a kept clip, adds
nothing; copies and independent source/output bytes do. Settings shows "Temporary video: X of at most Y",
and the tests check these numbers, not `RecorderStatus.bytes`.

**Unavoidable overshoot.** `fileLengthLimit` is documented as approximate: an export can write slightly
past it. That, and a write already in flight when free space is read, are covered only by the 64 MB
reserve. The `Data` a fragment arrives in is allocated by AVFoundation before the delegate sees it, so one
fragment over the bound exists in memory for the duration of that call; it is never retained.

**Unsaved clips** are outside that bound: each clip that didn't reach Photos keeps its full size
(≤ (N + post-roll) × rate, e.g. 38 MB for the default, ≈ 0.94 GB for 4K60 with 120 s + 30 s) in
Application Support until a Retry succeeds. They are counted in `BufferStorage.unsavedClips()`
(`UnsavedClip.bytes`). The app never deletes them on its own; there is no in-app delete yet.

### Free space (issue #10)

The ring bounds what RewindCam itself keeps, but not what the phone has left. Without a check, a nearly
full phone fails segment writes one by one (holes in the buffer, a small red error) and a save runs
out of space half-way. The low-disk guard reads free space and acts on fixed rules derived from the
table above, never on constants per preset.

**Reading free space.** `DiskCapacityProvider` on `AppEnvironment` (`environment.diskCapacity`) is the
only reader. Live: `VolumeDiskCapacity` reads `volumeAvailableCapacityForImportantUsageKey` of the
Caches volume (the required-reason API declared as `E174.1`: the result decides whether recording
starts and is shown to the user). Tests and `-UITestLowDisk` use `FakeDiskCapacity`. A `nil` answer
(unknown, e.g. some Simulator volumes) always counts as enough, so it never blocks recording.

**Policy.** `DiskSpacePolicy` (pure value, `BufferMath.swift`) holds every threshold; `AppModel` only
asks it. Built from buffer length, the preset actually recorded, "Record sound" and post-roll:

* `requiredBytesToBuffer` = ring cap + **reserve** (`BufferMath.reserveBytes`, 64 MB).
* `requiredBytesToSave` = post-roll segments + concatenated `source.mp4` + exported `.mov`
  = `rate × postRoll + 2 × rate × (N + postRoll)` at the nominal rate (the "worst case during a save"
  above, minus the ring): 75.5 MB for the defaults, 2.07 GB for 4K60 / 120 s / +30 s. The post-roll
  term is what the save's hard links keep after the ring evicts it; the Photos staging link is free.

| When | Condition | What happens |
|---|---|---|
| Start (launch, foreground, Try Again, quality/thermal restart, a longer buffer) | free < `requiredBytesToBuffer` | capture doesn't start: phase `.outOfSpace`, red **"Not recording: not enough free space"** banner, Save disabled, badge "NO SPACE" |
| | free < `requiredBytesToBuffer + requiredBytesToSave` | records, orange **"Storage is low"** banner |
| Recording, every 5 s (status loop, after the watchdog) | free < reserve | stops cleanly: recorder suspended (ring deleted, a pending post-roll settled with what is there), camera stopped, screen woken from Dim, failure haptic, same red banner |
| | free + ring bytes < `requiredBytesToBuffer + requiredBytesToSave` | keeps recording, orange banner |
| Save | free < `requiredBytesToSave` | **saves anyway**, orange warning toast; if the export then fails, its error toast adds "Storage is low: free up space" |

Choices the issue left open, and why:

* **Reserve 64 MB** (decimal, like the table). It must exceed what the ring can grow between two checks;
  the worst is 4K60 at the 1.5 overhead: 6.26 MB/s × 1.5 × 5 s ≈ 47 MB. A unit test checks this for
  every preset.
* **Check every 5 s**, counted on `environment.monotonicClock` from the last read (start, a buffer
  change or the previous check), not on each 0.5 s tick. It is skipped while pipeline work or
  recovery runs, or while not recording.
* **The ring's own bytes count as available while recording.** They are already on disk; comparing raw
  free space with `requiredBytesToBuffer + requiredBytesToSave` would warn as soon as the ring filled
  on a phone that had room for it. Stopping deletes the ring, so "free up about X" is measured after it.
* **"Free up about X"** is the shortfall to `requiredBytesToBuffer + requiredBytesToSave`: after freeing
  it, recording starts with no warning. The out-of-space banner says where (Settings › General › iPhone
  Storage) and offers the in-app alternative (shorter buffer, lower quality).
* **Try Again, not Open Settings.** RewindCam's Settings page can't free space and iOS has no public
  link to iPhone Storage. Besides Try Again, capture re-checks on return to the foreground (like a
  failed start) and whenever the buffer length or quality changes, so lowering either in RewindCam's
  Settings starts recording as soon as it fits. Nothing retries on a timer.
* **A longer buffer chosen while recording** is checked like a start (free + ring bytes against
  `requiredBytesToBuffer`) and stops recording if it can't fit, instead of growing into the reserve.
* **Unsaved clips** (#1) are never deleted or evicted to make room. The banners say how many there are
  and how much they take ("2 clips waiting for Photos use 76 MB."), and Settings lists them.
* **Settings** shows free space under the buffer picker, marks the current buffer at the current quality
  in red when it doesn't fit (orange when only a save may not fit), and lists the buffer lengths that
  don't fit.

**Estimates warn; actual sizes decide (issue #14).** The checks above are pre-checks on nominal sizes
and only warn: a save is never refused when Save is tapped. What a save may then write is decided from
the actual file sizes (see "Working-set budgets" above), against the same reserve; no second threshold:

* **Save floor** (`DiskSpacePolicy.saveFloorBytes`): while capture writes, a save's temporary files
  (copies, `source.mp4`, the export, a staging copy) must leave the **reserve** free, because the ring
  grows into it between two checks. Once capture has stopped (out of space, interrupted, halted), nothing
  else of RewindCam's writes, so a save may use what is free, best effort, but never more.
* **Reservations** (`TemporarySpace`): a running export's peak is reserved until it ends. Every free-space
  read in `AppModel` (start, the 5 s check, a longer buffer, Save, Settings) is free space minus those
  reservations, so a start during an export already counts the export's remaining bytes.
* **The best-effort save of #10, reconciled**: Save → warning toast if the estimate doesn't fit →
  export of everything that fits above the floor. A save cut short says so ("It's shorter than asked:
  there wasn't enough free space for all of it"); one with no room for even its last second writes
  nothing and says how much to free. Neither ever deletes a kept clip or fills the disk past the floor.

Not covered by CI: the real `volumeAvailableCapacityForImportantUsage` on a full phone (it includes
purgeable space iOS frees on demand, so it can read higher than Settings shows), and real write failures.

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

### Accessibility (issue #11)

* **Announcements.** `AppModel` speaks to VoiceOver through `environment.announcer`
  (`AccessibilityAnnouncer`; live `UIAccessibility.post(.announcement)` with a speech priority, tests
  `FakeAccessibilityAnnouncer`). Every toast is announced once by `showToast` (save results, "Can't
  save…", Photos failures; errors at high priority). State changes go through `announceChanges()` at
  the end of `refreshStatus()`, which every phase change reaches: it compares the phase, the thermal
  message and the visible warnings (stall restart, low storage, microphone) with what was last
  announced and speaks only the difference, in one utterance ("Recording resumed. The camera was
  restarted…"). So the 0.5 s status tick never repeats an announcement. `.starting` isn't announced;
  a failed start is announced at high priority, and again if Try Again fails the same way. A warning
  is news again only after it went away. `AnnouncementTests` checks each event is spoken exactly once.
* **VoiceOver labels.** The badge reads "Recording" with the value "N seconds ready" (or "Paused by
  you", "Not recording, camera access is off", …); pills read as sentences; each banner's text is one
  element with a decorative icon, and its button a separate one; Save's value says why it is
  unavailable; the dim overlay is one button (wake) with a **Save** custom action.
* **Dynamic Type.** All text uses text styles. Fixed shapes cap their text at an accessibility size and
  show the large content viewer: the status bar (`...accessibility1`, wraps to two rows with
  `ViewThatFits`), the round icon buttons, and the Save circle (grows with `@ScaledMetric` up to 168 pt,
  which still fits beside the round buttons on a 375 pt-wide iPhone). Banners scroll when they don't fit
  (`BannerArea`), their buttons move under the text at accessibility sizes, and Settings uses menus
  instead of segmented controls there.
* **Contrast and motion.** Text over footage sits on a near-black base (pills 65 %, banners 80 % under
  the tint, toast 80 %), which keeps white text at ≥ 4.5:1 over a white frame; button fills are darkened
  red, orange and blue (≥ 5:1 with white). Settings warnings colour the icon, not the text. The toast's
  cross-fade is off with Reduce Motion; nothing else animates.
* **Checks.** `AccessibilityUITests` launches at the largest text size with three banners and checks the
  controls stay on screen, hittable and apart (screenshots `a11y-*`), and runs Xcode's
  `performAccessibilityAudit()` on the main screen (recording, dimmed, paused) and Settings. Contrast
  is audited on the paused screen (black preview), not over the synthetic colour bars, and in Settings
  at the top only: scrolled down, the audit scrolls the Form to reveal the row under the navigation bar
  and measures contrast while rows still move, which gave random failures. The other
  exclusions, each with its reason in `AuditLog.excuse`: Dynamic Type results for the deliberately
  capped elements; "partially unsupported" Dynamic Type for text the largest-text test shows wrapping
  at full size (banners, dim overlay, Settings rows, Done); issues in the Settings Form that XCUITest
  can't attach to any element (UIKit internals of system controls; the segmented pickers become menus
  at accessibility sizes); on the
  dimmed screen, the contrast of the controls the overlay covers on purpose (the audit measures them
  although they are hidden from VoiceOver; the overlay's own text must pass); and text cut by the
  screen edge in a scrolling list, or by the scrolling banner area's faded edge; and "potentially inaccessible text" with no element (the timestamp
  drawn into the synthetic test footage, hidden from VoiceOver like the camera preview). Excused issues are
  attached to the test result as `audit-excused-*`. While dimmed, everything under the overlay is
  hidden from VoiceOver and the overlay is modal. Real VoiceOver speech and runtime text-size changes
  are on the README's device checklist.

## 5. Testing strategy

* **Unit tests** run the real `RollingRecorder` and `ClipExporter`, fed by a `SyntheticFrameSource` in
  *manual* mode. Frames carry synthetic timestamps, so 300 s of "recording" takes seconds and the
  results are deterministic (no wall clock is involved: every time value is a media timestamp).
* **UI tests** launch with `-UITestMode`: `SyntheticFrameSource` in real-time mode at a reduced
  resolution (the CI VM has no hardware encoder), a `FakePhotoLibrary` that writes into
  `Documents/FakePhotoLibrary`, and a fresh `UserDefaults` suite. A hidden-in-production label shows
  the fake library's clip count so XCUITest can check it. `FakePhotoLibrary` can deny access or fail
  the next saves; `-UITestPhotosFailOnce` makes the first save fail so a UI test can tap Retry.
  `-UITestDenyMicrophone` makes the synthetic source report a denied microphone and emit no audio.
  `-UITestDenyCamera` makes its start throw `.cameraAccessDenied` until Open Settings is tapped (standing
  in for the user allowing it), and `-UITestNoCamera` makes it throw `.noCamera` (Try Again path).
  `-UITestLowDisk` makes free space read 90 MB (the low-disk guard, issue #10).
  `-UITestLowDiskWarning` makes it read 150 MB (recording with the low-storage warning).
* **Working-set stress** (issue #14, `WorkingSetTests`): `RecorderHarness` with injected storage
  (`MediaFileOperations`: writes that stall or fail, hard links that fail) and fragment callbacks driven
  straight into the writer delegate. A stalled write plus a burst checks the queued-fragment bound and
  the halt; an oversized fragment, a full disk, forced copy fallback with little room, exports while
  capture continues, and a soak over every preset and buffer length (bitrates ÷100, VBR 0.5–1.5×, and an
  8× overshoot at 4K60) check the disk bounds by enumerating the folders.
* **Flake detector**: CI re-runs the unit tests 4× after the main run (`-run-tests-until-failure`); its
  failing tests and messages are appended to the job summary and `test-summary.md` ("Stress run").
  It caught one flake: `writerAudioInputWithoutSamples(realTime: true)` timed out waiting for segments
  ("no segment through …"). The test pushed 6 s of frames back to back into a *real-time* writer, which
  drops every frame its input isn't ready for; how many survived depended on timing and load (usually
  enough; in a reproduction on CI only 3 to 33 of the 90), and with too few no segment was ever emitted. Real-time recorder tests now feed frames
  with `RecorderHarness.generatePaced`: each frame only once the writer's video input is ready, as a
  camera feeds an encoder that keeps up. No frame is dropped (the test checks every one was appended),
  so the segments are the offline writer's whatever the load. Otherwise bursts (`source.generate`) go
  to the default non-real-time writer, whose appends wait for the encoder instead of dropping; the one
  model test with a real-time writer (`audioDoesNotMaskVideoStall`) doesn't depend on which frames survive.
* **Not covered by CI**: `CameraFrameSource` (including the real camera and microphone prompts and
  their failure paths), `AVCaptureEventInteraction` (volume buttons),
  real thermal behaviour, real Photos (permission prompt, denial, `performChanges` errors),
  background-task time after locking the phone, Data Protection (the Simulator doesn't enforce it),
  battery drain, and real peak storage and memory at 4K60 with slow storage (issue #14's bounds are
  checked deterministically, not measured on a device). See the manual checklist in the README.

## 6. Voice trigger (stretch)

* `SpeechVoiceTrigger` uses `SFSpeechRecognizer` (en-US) with
  `requiresOnDeviceRecognition = true`. If the device doesn't report
  `supportsOnDeviceRecognition`, the toggle is disabled. Audio never goes to a server.
* No second microphone session: a `SampleFanOut` sink passes the capture session's own audio
  samples to the recogniser (`SFSpeechAudioBufferRecognitionRequest.appendAudioSampleBuffer`).
  With voice on and "Record sound" off, the mic is captured for recognition only, and the
  recorder's writer still has no audio track. If the microphone is denied, the trigger isn't
  started; the microphone notice and the "Listening" row say why (§2, "What the source delivers").
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

## 7. Clip library (assessed, not built)

Issue #16 asked whether to add a private in-app clip library on top of #1's durable store. Decision:
**no permanent library**; production stays Photos-first and deletes a clip once Photos accepts it.
The recommended follow-up is a small "Not in Photos yet" sheet (play, share, add to Photos, confirmed
delete) over the same `UnsavedClips/` records; an opt-in per-clip "Keep locally" is feasible but
deferred, and a local-first library is rejected (unbounded storage competing with the buffer). The
comparison of ownership policies, storage, file protection, privacy, risks, evidence and the proposed
follow-up text are in [docs/decisions/clip-library.md](docs/decisions/clip-library.md). The disabled
prototype (`RewindCam/Library/ClipLibraryPrototype.swift`, not used by the app) and its tests
(`ClipLibraryPrototypeTests`) check those operations on real clips in temp folders.
