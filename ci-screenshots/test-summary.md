## ✅ RewindCam tests: Passed

| Total | Passed | Failed | Skipped |
|---|---|---|---|
| 222 | 222 | 0 | 0 |

Device: iPhone 17 — iOS Simulator 26.5

| Test | Result | Duration |
|---|---|---|
| `App model/Announcements: recording normally for 30 s says nothing after the start` | ✅ | 8s |
| `App model/Announcements: a successful save is announced once, with the toast's words` | ✅ | 0.86s |
| `App model/Announcements: a failed save is announced at high priority; the Retry that works is announced too` | ✅ | 0.28s |
| `App model/Announcements: Save refused (nothing recorded) says why, at high priority` | ✅ | 0.0095s |
| `App model/Announcements: an interruption and its end are announced once each, not on every tick` | ✅ | 0.49s |
| `App model/Announcements: Pause and Resume (issue #15)` | ✅ | 0.0069s |
| `App model/Announcements: camera denied at high priority; a Try Again that fails again says so again` | ✅ | 0.0079s |
| `App model/Announcements: microphone denied is said with the start, once` | ✅ | 0.45s |
| `App model/Announcements: thermal step-down and recovery, once each` | ✅ | 0.27s |
| `App model/Announcements: low storage once while it lasts, again after it cleared; out of space at high priority` | ✅ | 2s |
| `App model/Announcements: a frame stall, and the restart that cured it, once each` | ✅ | 0.55s |
| `App model/Announcements: phase wording` | ✅ | 0.00077s |
| `App model/Thermal downgrade switches the recorder to the lower preset and tells the user` | ✅ | 0.0082s |
| `App model/Settings persist across launches` | ✅ | 0.0081s |
| `App model/Buffer-length change applies to the running recorder in place` | ✅ | 0.01s |
| `App model/Save from the model lands in the (fake) photo library with a toast and haptic` | ✅ | 0.26s |
| `App model/Backgrounding pauses, clears the buffer and explains why; foreground resumes` | ✅ | 0.15s |
| `App model/Dim mode lowers brightness and restores it on wake` | ✅ | 0.0096s |
| `App model/Interruption events from the source pause and resume recording` | ✅ | 0.17s |
| `App model/modelCleansOrphansWhenStarting()` | ✅ | 0.0048s |
| `App model/Camera denied: an Open Settings notice, nothing recording, Save refused with a reason` | ✅ | 0.0076s |
| `App model/Camera allowed in Settings: returning to the foreground starts recording (with and without a background trip)` | ✅ | 0.42s |
| `App model/Other start failures offer Try Again, which re-runs the start pipeline once per tap` | ✅ | 0.0068s |
| `App model/A restart that fails (camera switch) stops capture and lets the screen lock; foreground retries it` | ✅ | 0.096s |
| `App model/Camera denied after a relaunch: clips that didn't reach Photos can still be retried` | ✅ | 0.19s |
| `App model/Source events are handled in the order emitted, however many arrive back to back` | ✅ | 0.34s |
| `App model/Runtime error, session still running: recording resumes at once, without a restart` | ✅ | 0.18s |
| `App model/Runtime error that stops the session: restarts on the backoff schedule until one works` | ✅ | 1s |
| `App model/Restarts that keep failing give up: Not recording with Try Again, screen woken, later events ignored` | ✅ | 0.22s |
| `App model/Backgrounding during recovery cancels it; returning starts normally` | ✅ | 0.19s |
| `App model/An ordinary interruption during recovery takes over: no give-up, and its end resumes recording` | ✅ | 0.13s |
| `App model/Safety net: a missed 'running again' or a suspended recorder is repaired on the next status tick` | ✅ | 1s |
| `App model/Safety net: a source interrupted or stopped without telling us is paused, then restarted` | ✅ | 0.17s |
| `App model/The safety net does nothing while stopped, failed, or recording normally` | ✅ | 0.31s |
| `App model/A change while the camera starts is started before Recording, recorder to match` | ✅ | 0.13s |
| `App model/Record sound turned on while the camera starts, microphone denied: the notice, never silently silent` | ✅ | 0.14s |
| `App model/Several changes while the camera starts: one corrective start with the newest configuration` | ✅ | 0.12s |
| `App model/A change during each corrective start: settles on the newest, one start per change, no loop` | ✅ | 0.099s |
| `App model/Two changes in quick succession while recording (the issue's sequence): the second lands in the first's restart` | ✅ | 0.11s |
| `App model/A change while the camera starts, then Pause: Pause wins; Resume starts the newest configuration` | ✅ | 0.27s |
| `App model/A change while the camera starts, then background: nothing records; foreground starts the newest configuration` | ✅ | 0.11s |
| `App model/A change during the frame watchdog's restart is started by that restart; the stall notice stays` | ✅ | 0.24s |
| `App model/A change while the camera starts that doesn't fit in free space: the out-of-space notice, not Recording` | ✅ | 0.016s |
| `App model/Dim: the level from before is stored while dimmed and cleared on wake` | ✅ | 0.014s |
| `App model/Dim: .inactive puts the brightness back and keeps the overlay; .active dims again` | ✅ | 0.018s |
| `App model/Dim: repeated inactive/active flips restore and re-dim each time, never losing the level` | ✅ | 0.051s |
| `App model/Dim: a level changed while inactive (Control Center slider) is the one restored afterwards` | ✅ | 0.017s |
| `App model/Dim: .background wakes, restores the brightness and clears the stored level` | ✅ | 0.022s |
| `App model/Dim: a level the user or auto-brightness set during the dim is left alone on wake` | ✅ | 0.019s |
| `App model/Dim: a relaunch after a kill while dimmed restores the stored level once and clears it` | ✅ | 0.016s |
| `App model/Dim: a relaunch whose first phase is .inactive restores too (no read-back stored), and a later dim keeps it` | ✅ | 0.02s |
| `App model/Dim: a relaunch without a stored level leaves the brightness untouched` | ✅ | 0.01s |
| `App model/Dim: a relaunch after the brightness changed since the kill (e.g. a lock) leaves it and clears` | ✅ | 0.013s |
| `App model/Dim and Pause: pausing wakes and restores; scene flips while paused don't dim` | ✅ | 0.022s |
| `App model/Dim: the stored levels round-trip, are separate from the settings and ignore bad values` | ✅ | 0.022s |
| `App model/Dim on a clamping or rounding screen: wake restores, and the read-back is stored` | ✅ | 0.038s |
| `App model/Dim on a clamping or rounding screen: inactive restores, active dims again, repeatedly` | ✅ | 0.064s |
| `App model/Dim on a clamping or rounding screen: a relaunch after a kill restores, unless changed since` | ✅ | 0.033s |
| `App model/Not enough space for the buffer at start: not recording, says how much to free; Try Again re-checks` | ✅ | 0.0095s |
| `App model/A shorter buffer chosen in Settings starts recording once it fits, with a save warning` | ✅ | 0.011s |
| `App model/Free space falls below the reserve mid-recording: stops cleanly within 5 s, no write errors` | ✅ | 0.21s |
| `App model/Between the two thresholds mid-recording: keeps recording with a warning that clears with space` | ✅ | 0.45s |
| `App model/Unknown free space (nil) records normally` | ✅ | 0.5s |
| `App model/Save with low free space still produces a clip, after a warning toast` | ✅ | 0.27s |
| `App model/Space runs out during post-roll: capture stops, and the save still delivers what was recorded` | ✅ | 0.42s |
| `App model/Frame stall: one automatic restart, then Not recording with Try Again, screen woken` | ✅ | 0.42s |
| `App model/Frame stall recovered: recording resumes, the user is told, and a later stall gets its own restart` | ✅ | 1s |
| `App model/Audio that keeps arriving doesn't hide a video stall` | ✅ | 0.1s |
| `App model/A save waiting for its post-roll when video stops settles once, with the footage there is` | ✅ | 19s |
| `App model/No false stall: launch, settings and thermal restarts, background, interruptions` | ✅ | 0.092s |
| `App model/A stop during stall recovery supersedes it` | ✅ | 0.02s |
| `App model/Microphone denied with Record sound on: video-only writer, a notice with Open Settings, playable clips` | ✅ | 3s |
| `App model/Voice trigger with the microphone denied reports it can't listen; settings stay as chosen` | ✅ | 0.49s |
| `App model/Sound and voice trigger off: the microphone isn't requested, so a denial shows nothing` | ✅ | 0.012s |
| `App model/Microphone allowed: the recorder writes audio because the source captures it` | ✅ | 0.92s |
| `App model/Turning the phone keeps the buffer; the clip is turned for the tap, not the post-roll` | ✅ | 1s |
| `App model/Front camera in landscape right: turned like the back camera; portrait stays untouched` | ✅ | 1s |
| `App model/Photos failure keeps the finished clip durably; Retry adds it and only then deletes it` | ✅ | 0.54s |
| `App model/Photos access is requested at launch, before any save, and only once` | ✅ | 0.023s |
| `App model/Photos denied: the user is told at launch, and a save keeps the clip with a Settings hint` | ✅ | 0.51s |
| `App model/Relaunch keeps clips that never reached Photos, removes stray partial exports and job folders` | ✅ | 0.54s |
| `App model/A save that fails before export leaves no partial file and still ends its background task` | ✅ | 0.0088s |
| `App model/Pause: camera off, buffer discarded, voice and dim off, Save refused from every trigger; kept clips stay` | ✅ | 1s |
| `App model/Pause holds across foreground, a trip to Settings, Try Again, start() and 30 s of status ticks` | ✅ | 0.36s |
| `App model/Pause while the camera is still starting: the late start publishes nothing and is stopped` | ✅ | 0.27s |
| `App model/Pause during the camera permission prompt: a late denial shows nothing; Resume asks again` | ✅ | 0.094s |
| `App model/Background while the camera is still starting: no recording survives, foreground starts as before` | ✅ | 0.1s |
| `App model/Rapid pause/resume/background/foreground settles on the newest intent, one session at a time` | ✅ | 0.23s |
| `App model/Pause during recovery backoff: no later attempt, no give-up notice; Resume starts fresh` | ✅ | 0.16s |
| `App model/Pause while a stall restart is starting the camera: the restart is dropped; the watchdog re-arms after Resume` | ✅ | 0.21s |
| `App model/Interruption ended while paused: no resume, no recovery, nothing restarted` | ✅ | 0.11s |
| `App model/Try Again while paused does nothing; a Try Again still queued when Pause comes is dropped` | ✅ | 0.11s |
| `App model/Low disk: the free-space check doesn't run while paused, and a stop it queued just before Pause yields to it` | ✅ | 0.31s |
| `App model/A relaunch starts recording: the pause is not persisted` | ✅ | 0.093s |
| `App model/Voice trigger gives up: Listening says No and why, one toast; retried on toggle and on the next start` | ✅ | 2s |
| `App model/Voice trigger gives up while recording: Pause and Resume try again; a report after a stop is ignored` | ✅ | 0.021s |
| `App model/Recorder overflow while recording: Not recording with Try Again, the pending save delivers once, no loop` | ✅ | 0.12s |
| `App model/Recorder halt with free space below the reserve is the out-of-space stop` | ✅ | 0.052s |
| `App model/A save that only partly fits the free space exports its newest part and says so` | ✅ | 0.19s |
| `App model/A save with no room for even its last second writes nothing and says how much to free` | ✅ | 0.13s |
| `App model/Free-space reads are net of a running save's reservation; Settings measures the working set` | ✅ | 0.17s |
| `Capture recovery policy/Backoff: immediate first attempt, growing delays, then a spent budget` | ✅ | 0.00065s |
| `Capture recovery policy/Fake scheduler runs due actions in time order, including ones they schedule` | ✅ | 0.00046s |
| `Capture recovery policy/resumeRunning: true and 'running again' whenever the source runs afterwards, else false and silent` | ✅ | 0.0002s |
| `Clip library prototype (#16, disabled)/Policies: only Keep locally (when chosen) or local-first retains a clip Photos accepted; the prototype is off` | ✅ | 0.00019s |
| `Clip library prototype (#16, disabled)/Creation metadata comes from the committed name, not from file timestamps` | ✅ | 0.0021s |
| `Clip library prototype (#16, disabled)/A durable clip is listed, reloads after the buffer is gone (relaunch), plays, and can be shared` | ✅ | 0.23s |
| `Clip library prototype (#16, disabled)/Recovery-only (today's policy): denied or failed Photos keeps the clip; success removes it even if Keep was asked` | ✅ | 0.15s |
| `Clip library prototype (#16, disabled)/Keep locally: Photos gets a link, the kept copy survives the move, leaves the Retry list, and is deleted only explicitly` | ✅ | 0.4s |
| `Clip library prototype (#16, disabled)/If the kept copy can't be moved after Photos accepted it, the clip stays offered: a duplicate, never a loss` | ✅ | 0.99s |
| `Clip library prototype (#16, disabled)/Deleting a clip Photos doesn't have needs the only-copy acknowledgement; pending exports are never entries` | ✅ | 0.0063s |
| `Free-space policy/Defaults (1080p30, 30 s, no post-roll): ≈ 136 MB worst case, as in DESIGN.md` | ✅ | 0.00023s |
| `Free-space policy/4K60, 120 s, 30 s post-roll: ≈ 3.2 GB worst case, as in DESIGN.md` | ✅ | 0.00014s |
| `Free-space policy/Larger settings never need less space` | ✅ | 0.00033s |
| `Free-space policy/The reserve outlasts the ring's growth between two checks at every preset` | ✅ | 0.00017s |
| `Free-space policy/Before buffering: too low below the ring cap + reserve, a warning below buffer + save` | ✅ | 0.00012s |
| `Free-space policy/While recording: stop below the reserve; the ring's own bytes count as available` | ✅ | 0.00051s |
| `Free-space policy/Before a save: a warning below the save estimate, never a refusal` | ✅ | 0.00015s |
| `Free-space policy/The policy follows post-roll and sound` | ✅ | 0.019s |
| `File protection and backup/Media uses 'until first unlock': lock-safe for background saves, never Complete or Complete-unless-open` | ✅ | 0.00042s |
| `File protection and backup/Every media file exists; hard links are the same file (one class), the copy is a separate file` | ✅ | 0.012s |
| `File protection and backup/Where Data Protection is reported, every media file reads back as 'until first unlock'` | ✅ | 0.037s |
| `File protection and backup/Launch re-applies the media class to kept clips and never deletes them` | ✅ | 0.0026s |
| `File protection and backup/Durable folders are excluded from backup, re-marked before each export; Caches folders are wiped` | ✅ | 0.0029s |
| `File protection and backup/The app keeps the buffer and save jobs in Caches and unsaved clips in Application Support` | ✅ | 0.00035s |
| `Frame watchdog policy/Advancing video and segments never stall` | ✅ | 0.00039s |
| `Frame watchdog policy/Frozen video: nothing at 4.9 s, a stall at 5 s, reported once` | ✅ | 0.00015s |
| `Frame watchdog policy/The timeout counts from the last new frame, not from arming` | ✅ | 0.00012s |
| `Frame watchdog policy/No video yet (nil media time) after arming: the grace period is the full timeout` | ✅ | 0.00013s |
| `Frame watchdog policy/Audio can't mask it: only the video time counts, so frozen video stalls even with segments` | ✅ | 0.00057s |
| `Frame watchdog policy/Video arrives but no segment for 5 s: a writer stall` | ✅ | 0.00016s |
| `Frame watchdog policy/Stale generations are ignored` | ✅ | 0.00011s |
| `Frame watchdog policy/Disarm and re-arm restart the timeout; a disarmed watchdog reports nothing` | ✅ | 0.00014s |
| `Frame watchdog policy/Budget: one automatic restart per stall episode; an episode ends after 30 s without a stall` | ✅ | 0.014s |
| `Recorder: settling a pending save when video stops/A pending post-roll settles at once with the footage already buffered, exactly once` | ✅ | 0.25s |
| `Recorder: settling a pending save when video stops/With nothing buffered for it, the pending save fails with an actionable message` | ✅ | 0.1s |
| `Frame source start contract/start reports whether audio is captured, and why not; no audio samples when it isn't` | ✅ | 0.022s |
| `Orientation policy (issue #37)/Each way of holding the phone is recognised, also tilted back on a stand` | ✅ | 0.00029s |
| `Orientation policy (issue #37)/Lying (nearly) flat decides nothing: the current orientation stays` | ✅ | 0.00015s |
| `Orientation policy (issue #37)/Hysteresis: the orientation changes only 15° past the 45° midpoint, either way` | ✅ | 0.00016s |
| `Orientation policy (issue #37)/A new orientation counts only once held for 0.5 s; a brief tilt is ignored` | ✅ | 0.00019s |
| `Orientation policy (issue #37)/Live sensor: samples are stamped on its clock and settle without the accelerometer` | ✅ | 0.00083s |
| `Orientation policy (issue #37)/The clip's turn puts the scene's up at the top, for every orientation, camera and mirroring` | ✅ | 0.00017s |
| `Orientation policy (issue #37)/The app's front camera is mirrored, so it turns its clips exactly as the back camera does` | ✅ | 0.00014s |
| `Orientation policy (issue #37)/The transform maps the frame exactly onto the display size (landscape for a sideways phone)` | ✅ | 0.00015s |
| `Orientation: exported clips (issue #37)/Each orientation and camera: preferredTransform, display size, and every frame decodes` | ✅ | 0.49s |
| `Privacy manifest/manifestIsInTheAppBundle()` | ✅ | 0.0032s |
| `Privacy manifest/declaresNoTrackingAndNoCollectedData()` | ✅ | 0.00056s |
| `Privacy manifest/declaresRequiredReasonAPIs()` | ✅ | 0.00041s |
| `Quality governor/effectivePreset(_:)` | ✅ | 0.0018s |
| `Quality governor/stepDownNeverRaisesBitrate()` | ✅ | 0.00018s |
| `Rolling recorder/300 s of frames with a 30 s buffer keeps ~30 s on disk, under the cap` | ✅ | 5s |
| `Rolling recorder/Save produces a playable clip as long as the buffer (±1 s)` | ✅ | 1s |
| `Rolling recorder/Post-roll: clip covers buffer + post-roll (±1 s)` | ✅ | 0.99s |
| `Rolling recorder/Saving before the buffer is full returns whatever exists` | ✅ | 0.18s |
| `Rolling recorder/Save with nothing buffered fails cleanly` | ✅ | 0.0041s |
| `Rolling recorder/Interruption resets the buffer; later clips are valid` | ✅ | 0.72s |
| `Rolling recorder/Interruption during post-roll yields a valid clip of what was captured` | ✅ | 0.22s |
| `Rolling recorder/Shortening the buffer applies in place without restarting` | ✅ | 0.57s |
| `Rolling recorder/Writer audio input that is never fed: no segments are emitted and nothing can be saved` | ✅ | 4s |
| `Rolling recorder/Only one save can be pending at a time` | ✅ | 0.25s |
| `Segment ring policy/keepsMinimalSuffixCoveringBuffer()` | ✅ | 0.0028s |
| `Segment ring policy/unevenSegmentsStayWithinOneSegmentOfBuffer()` | ✅ | 0.01s |
| `Segment ring policy/byteCapWinsOverDuration()` | ✅ | 0.00067s |
| `Segment ring policy/capHoldsEvenForOneOversizedSegment()` | ✅ | 0.00021s |
| `Segment ring policy/newestSegmentWithinCapIsKept()` | ✅ | 0.00011s |
| `Segment ring policy/shrinkingBufferEvictsInPlace()` | ✅ | 0.001s |
| `Speech voice trigger: one recognition task at a time/Late callbacks from a cancelled task don't cancel or replace the current task` | ✅ | 0.00046s |
| `Speech voice trigger: one recognition task at a time/A cancellation error delivered from inside cancel() doesn't start a restart loop` | ✅ | 0.00022s |
| `Speech voice trigger: one recognition task at a time/The phrase fires once; late partials from the replaced task neither fire nor restart` | ✅ | 0.00027s |
| `Speech voice trigger: one recognition task at a time/The 50 s recycle creates exactly one new task` | ✅ | 0.00041s |
| `Speech voice trigger: one recognition task at a time/After stop, the old task's callbacks and audio are ignored` | ✅ | 0.00017s |
| `Speech voice trigger: one recognition task at a time/Without on-device recognition nothing starts` | ✅ | 0.00014s |
| `Speech voice trigger: one recognition task at a time/Recognition requests are on-device only` | ✅ | 0.00037s |
| `Storage, settings and buffer math/orphanedBufferFilesAreRemovedOnLaunch()` | ✅ | 0.0086s |
| `Storage, settings and buffer math/settingsStoreRoundTrip()` | ✅ | 0.012s |
| `Storage, settings and buffer math/settingsDecodeIsTolerant()` | ✅ | 0.017s |
| `Storage, settings and buffer math/bufferMathMatchesDesignDoc()` | ✅ | 0.0004s |
| `Storage, settings and buffer math/capGrowsMonotonicallyWithBufferAndQuality()` | ✅ | 0.00014s |
| `Storage, settings and buffer math/fakePhotoLibraryStoresClips()` | ✅ | 0.0015s |
| `Storage, settings and buffer math/Launch cleanup keeps finished clips and deletes partial exports; the folder is excluded from backup` | ✅ | 0.0036s |
| `Storage, settings and buffer math/A partial export becomes visible only when committed, and never overwrites a kept clip` | ✅ | 0.051s |
| `Storage, settings and buffer math/Photos gets a staged link; the kept clip survives Photos taking the file, and staging is cleaned up` | ✅ | 0.0037s |
| `Voice phrase matching/matches(_:)` | ✅ | 0.026s |
| `Voice phrase matching/doesNotMatch(_:)` | ✅ | 0.000076s |
| `Battery drain meter/reportsPercentPerHourAfterTenMinutes()` | ✅ | 0.0023s |
| `Battery drain meter/chargingRestartsTheMeasurement()` | ✅ | 0.00021s |
| `Voice trigger in the app/Enabling the voice trigger taps capture audio; hearing the phrase saves a clip` | ✅ | 0.3s |
| `Voice trigger in the app/Battery drain is measured while recording, against the injected clock` | ✅ | 0.0045s |
| `Voice trigger: sessions that keep failing back off, then stop (#36)/Every session fails at once: a bounded number of sessions, on the backoff schedule, then one stop` | ✅ | 0.0011s |
| `Voice trigger: sessions that keep failing back off, then stop (#36)/A session that produces a transcript refills the budget; healthy ends restart at once` | ✅ | 0.011s |
| `Voice trigger: sessions that keep failing back off, then stop (#36)/A nil session counts as a failure: retried on the backoff schedule, then the trigger stops` | ✅ | 0.00065s |
| `Voice trigger: sessions that keep failing back off, then stop (#36)/A failure delivered before the session is stored ends that session; it never receives audio` | ✅ | 0.0004s |
| `Voice trigger: sessions that keep failing back off, then stop (#36)/Stale callbacks (#2) are still ignored, also while a restart waits; stop and start cancel the wait` | ✅ | 0.00042s |
| `Working-set policy/Queued fragments: 8 fragments, max(16 MB, 4 s at 1.5×), never one larger than the ring cap` | ✅ | 0.00049s |
| `Working-set policy/Temporary media cap: defaults ≈ 190 MB, 4K60 120 s +30 s ≈ 4.1 GB, as in DESIGN.md` | ✅ | 0.00031s |
| `Working-set policy/Export admission: unknown → all; partial → newest segments; nothing → how much to free` | ✅ | 0.00017s |
| `Working-set policy/The save floor is #10's reserve while capture runs, nothing once it stopped` | ✅ | 0.0025s |
| `Working-set policy/TemporarySpace: reservations count against free space above the floor, and are released once` | ✅ | 0.00058s |
| `Working set (recorder)/Slow storage and a burst of fragments: queued data stays within its bound, then the generation stops once` | ✅ | 0.6s |
| `Working set (recorder)/A single fragment larger than the bound is never retained; the generation stops, the save settles` | ✅ | 0.29s |
| `Working set (recorder)/A segment write fails (full disk): the generation stops instead of continuing with a hole` | ✅ | 1s |
| `Working set (recorder)/Hard links are counted once; a forced copy fallback is counted, measured from the files` | ✅ | 1s |
| `Working set (recorder)/Copy fallback with little free space: the newest footage that fits, then the save settles early` | ✅ | 0.53s |
| `Working set (recorder)/Copy fallback with no room for even the newest segment: the save fails and leaves nothing` | ✅ | 0.29s |
| `Working set (recorder)/Repeated saves exported while capture continues stay within the temporary-media cap, then clean up` | ✅ | 3s |
| `Working set (recorder)/Source concatenation fails (a segment is gone): nothing is exported, discarding leaves nothing` | ✅ | 0.35s |
| `Working set (recorder)/Soak: every preset and buffer length, +30 s post-roll (bitrates ÷100): ring, save and queue stay bounded` | ✅ | 8s |
| `Working set (recorder)/Encoder far over its bitrate (8×) at 4K60: the ring keeps its cap and the save stops at its own` | ✅ | 0.14s |
| `AccessibilityUITests/testAccessibilityAuditMainScreen()` | ✅ | 1m 11s |
| `AccessibilityUITests/testAccessibilityAuditSettings()` | ✅ | 1m 4s |
| `AccessibilityUITests/testLargestTextKeepsEverythingReachable()` | ✅ | 1m 25s |
| `RewindCamUITests/testCameraDeniedOffersOpenSettingsAndRecordsAfterReturning()` | ✅ | 34s |
| `RewindCamUITests/testCameraStartFailureOffersTryAgain()` | ✅ | 11s |
| `RewindCamUITests/testChangeBufferTo60Seconds()` | ✅ | 37s |
| `RewindCamUITests/testDimModeTogglesOverlay()` | ✅ | 17s |
| `RewindCamUITests/testLowDiskExplainsAndRecordsAtSettingsThatFit()` | ✅ | 23s |
| `RewindCamUITests/testMicrophoneDeniedShowsNoticeAndSavesStillWork()` | ✅ | 24s |
| `RewindCamUITests/testPauseHoldsAcrossBackgroundUntilResume()` | ✅ | 43s |
| `RewindCamUITests/testPhotosFailureKeepsClipAndRetryAddsIt()` | ✅ | 19s |
| `RewindCamUITests/testSaveAfterFiveSecondsAddsOneClip()` | ✅ | 14s |
| `RewindCamUITests/testVideoStallRestartsCameraAndSaysSo()` | ✅ | 19s |

## ✅ Stress run (flake detector): Passed

| Total | Passed | Failed | Skipped |
|---|---|---|---|
| 209 | 209 | 0 | 0 |

Device: iPhone 17 — iOS Simulator 26.5

No failing tests.
