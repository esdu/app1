# Decision: a private clip library on top of durable save recovery (#16)

**Status:** assessed; **no-go for now** on a permanent library. Production behaviour is unchanged
(Photos-first; a clip is deleted from the app once Photos accepts it). Closing #16 enables nothing.
**Proposed follow-up:** a small "Not in Photos yet" list (play, share, delete with confirmation) over
#1's existing records, and nothing else (text at the end). An optional per-clip **Keep locally** is
feasible and prototyped, but left for a later, explicit product decision.

Related: #1 (durable saves), #13 (file protection, DESIGN.md §2 "File protection and backup"),
#10 (low-disk guard), #14 (temporary working set), #5 and #17 (work order).

## 1. What #1 already provides, and what is missing

#1 already does the hard part of a library, for clips that didn't reach Photos:

| Capability | #1 today | Where |
|---|---|---|
| Atomic publication | export to `UnsavedClips/<name>.partial.mov`, rename to `<name>.mov` only when complete | `BufferStorage.partialClipURL`, `commitPartialClip` |
| Stable identity | the committed file name `RewindCam_<date>_<time>[-n].mov`, never reused while the file exists | `commitPartialClip` |
| Durable location | Application Support, excluded from backup, never wiped | `FileBufferStorage.unsavedDirectory` |
| Startup recovery | `.partial.mov` deleted, finished `.mov` kept and listed | `removeOrphans`, `unsavedClips()` |
| Source independence | the clip is a self-contained `.mov`; the ring can be wiped | `ClipExporter` |
| Photos hand-off ownership | Photos gets a disposable hard link; the kept file is deleted only after success | `stageForPhotos`, `AppModel.addToPhotos` |
| Retry UI | banner "N clips aren't in Photos yet" + Retry, survives relaunch | `AppModel.retryUnsavedClips`, `ContentView` |
| Size metadata | `UnsavedClip.bytes` | `unsavedClips()` |

Missing for a user who can't (or won't) grant Photos access:

1. **No way to look at a kept clip.** The banner only counts them.
2. **No way to get it out** other than Photos (no share sheet, so no AirDrop, Files or Messages).
3. **No way to delete one.** A clip that will never reach Photos (access permanently denied) takes its
   full size forever (README "Known limits"; DESIGN.md §2 "Bounded disk").
4. **No creation date shown** (it is in the name, see §4).

Nothing is missing for the main flow: when Photos works, the clip is in Photos and the user uses
Photos to watch, share and delete it. That is the product's stated design (README: "the last *N*
seconds land in Photos").

## 2. The three ownership policies

| | A. Recovery-only (today) | B. Optional "Keep locally" | C. Local-first library |
|---|---|---|---|
| Who owns a clip after Photos accepted it | Photos only | Photos; the app too, only for clips the user marked | the app always; Photos is an optional copy |
| Clips in the app | only those not yet in Photos | + the ones marked Keep | every clip ever saved, until deleted |
| Extra storage | none beyond failures | one full duplicate per kept clip | one full duplicate per clip (if also exported), unbounded |
| Default behaviour change | none | none (opt-in per clip) | yes: Save no longer means "it's in Photos" |
| Deletion | automatic after Photos success; explicit only for never-imported clips (follow-up) | explicit for kept clips | explicit for everything; needs quotas/warnings |
| App deletion / new phone | only not-yet-in-Photos clips are lost | kept copies lost, Photos copies survive | everything not exported is lost unless backed up |
| UX surface | banner + list | list + a Keep toggle at save or in the list | full library tab, thumbnails, sorting, storage screen |
| Fit with "never miss a moment" | good: nothing competes with the buffer for space | fine if users keep few clips | poor: library growth eats the space the buffer and saves need |

**Policy C is a no-go.** It changes the product's promise, makes storage unbounded on a device that
must keep room for a ring of up to ~1.15 GB plus a save's working set (DESIGN.md §2 "Bounded disk"),
and "no silent eviction of completed moments" (this issue) means the only response to a full library
is refusing to save, which is the one failure RewindCam exists to avoid.

**Policy B is feasible** (the prototype implements it without a second durability path) but has no
demonstrated need: Photos already offers favourites, albums, the Hidden album and sharing. It costs
a full duplicate per kept clip and a new ownership state to explain. Defer until a user need appears.

**Policy A plus a small list** closes every gap in §1 and is the recommendation.

## 3. Storage and peak disk

Per-clip sizes (DESIGN.md §2 "Bounded disk"): about 38 MB for the default (1080p30, 30 s), up to
~0.94 GB for 4K60 with 120 s + 30 s post-roll.

* **Peak during a save is unchanged by any policy.** The prototype's "keep" step is a rename from
  `UnsavedClips/` to a sibling folder on the same volume: no bytes are written. The Photos hand-off is
  a hard link (0 bytes). So the save working set that #14 bounds (ring + post-roll links +
  `source.mp4` + export) is the same.
* **Durable bytes grow.** A: only failed imports. B: + every kept clip. C: every clip. These bytes are
  not temporary and must never be evicted, so they belong to #10's "available capacity" input (they
  are already reflected in the volume's free space) and must **not** be counted in #14's temporary
  working set. A list would show `UnsavedClip.bytes` per clip and the total
  (`ClipLibraryPrototype.storageUse()` splits "not in Photos" and "kept locally").
* **Is a kept copy a real duplicate?** Photos imports with `shouldMoveFile`, and RewindCam hands it a
  hard link of the kept file. Whether Photos keeps that inode (0 extra bytes) or copies/transcodes it
  into its store is not documented and not verified on a device. With iCloud Photos "Optimize iPhone
  Storage", Photos may also offload its full-size original. Plan for a full duplicate.
* **Interaction with #10 and #14 (coordination only, no change here):** #10's low-disk warning should
  mention clips waiting in the app when they are a large share of the shortfall ("2 clips (1.2 GB)
  aren't in Photos yet"), and offer the list, never delete them. #14 should keep treating
  `UnsavedClips/` (and a future kept folder) as outside the evictable working set.

## 4. Data model, if built (atomic publication, identity, metadata, recovery, cleanup, ownership)

Reuse #1, add no second store:

* **Records are files.** Not in Photos = `BufferStorage.unsavedClips()` exactly. No database, no
  manifest: the directory listing is the index, so there is nothing to get out of sync after a crash.
* **Publication** stays #1's partial → rename. Listing filters `.partial.mov`; staging and share
  links live in `Caches/RewindClips/` and are never listed (tested).
* **Identity** is the committed file name. Policy B moves a kept clip into a separate folder
  (prototype: `KeptLocally/`, in the app next to `UnsavedClips/`), keeping its name unless taken
  (then `-2`, …), so the prototype's entry id is `<status>/<name>`. If B ships, a UUID suffix in the
  committed name would make identity stable across the move.
* **Why a separate folder for kept clips:** `UnsavedClips/` must keep meaning "Photos doesn't have
  it", or #1's Retry would re-add kept clips to Photos on every launch.
* **Creation metadata** is parsed from the name (`ClipLibraryPrototype.saveDate(fromName:)`), not read
  from file timestamps: those are a required-reason API, and using them would need a File Timestamp
  declaration (C617.1) in `PrivacyInfo.xcprivacy` (#7). Duration is loaded from the asset when shown.
* **Startup recovery and cleanup:** #1's `removeOrphans` as is. A rename into the kept folder is a
  single step; a kill around it leaves the clip in exactly one of the two folders. Nothing writes
  partial files into the kept folder.
* **Transfer ownership:** Photos always gets a hard link in `photos-<uuid>/` (copy if linking fails);
  `shouldMoveFile` moves that name, never the kept one. Only after Photos reports success does the
  policy decide: A deletes the app's file; B moves it to the kept folder. If that move fails, the clip
  stays in `UnsavedClips/` and is offered again: a possible duplicate in Photos, never a loss (same rule
  as #1's "Duplicates over loss").
* **Deletion** is only ever explicit and confirmed. For a clip Photos doesn't have, the confirmation
  must say it is the only copy. Delete re-reads the folder and only removes a currently listed finished
  clip (never a partial export or a caller-supplied path).

## 5. File protection (#13), backup and privacy

* **Not in Photos yet** clips keep #13's class (`completeUntilFirstUserAuthentication`) and backup
  exclusion, unchanged: a save started before a lock must still be able to finish and hand off.
* **Kept locally** clips (B) are already in Photos, so they never need to be read while locked: they
  *could* use `.complete`. But the kept file may share its inode with Photos' copy (hard-link hand-off),
  and changing the class through one name changes both. If B ships, either hand Photos a copy for
  kept clips (costs a temporary duplicate at import time), or keep the #13 class. Not decided here;
  #13's "possible follow-up" covers the same trade-off for clips waiting for Retry.
* **Backup:** the kept folder would be excluded from backup like `UnsavedClips/` (Photos is the backup
  of record). Consequence, to be stated in the UI: deleting the app or moving to a new phone loses the
  app's copies. For A that only affects clips not yet in Photos (already in README "Known limits").
* **Privacy:** clips in the app are outside Photos' protections (Hidden album behind Face ID, Shared
  Library rules) and visible to anyone who can open the unlocked app. Nothing leaves the device except
  through a user-initiated share sheet; no network code or manifest data types change. A list must not
  show thumbnails on the lock screen or in app-switcher snapshots (blur on `scenePhase` inactive).

## 6. UX and capture policy

* The list opens as a sheet from the existing "N clips aren't in Photos yet" banner (and from Settings
  when the list is non-empty). It shows date, duration, size, and per clip: Play, Share, Add to Photos
  (Retry), Delete (confirmed). No library tab.
* **Capture keeps running** while the sheet is open (it is an overlay, not a scene change), so the ring
  keeps covering the last *N* seconds and Save still works when the sheet closes. Playing a clip with
  sound uses `AVPlayer` within the audio session the capture session already configures (RewindCam
  sets no category itself; `AVCaptureSession` manages it by default); it must not reconfigure the
  capture session. If a later device check shows that playback disturbs capture, pausing capture while playing
  must be explicit and shown (reuse #15's user pause), never silent.
* Accessibility (#11) and README/DESIGN (#12) need a pass for the new sheet.

## 7. Risks

* Deleting the only copy by mistake: mitigated by confirmation wording ("only copy") and no bulk delete.
* Shared inode with Photos (hard-link hand-off): attribute changes through the app's name affect
  Photos' file. The app never modifies a clip after commit; only #13's class re-apply at launch touches
  kept clips. Keep it that way.
* Duplicates in Photos after a crash between Photos success and the local delete/move (existing #1
  behaviour; also when the B move fails).
* Storage creep in B (users keep everything); C rejected for this reason.
* Playback with the camera running is unverified on a device (audio session, thermal).
* App deletion and new-phone migration lose app-only copies by design (backup excluded).

## 8. Evidence

**Simulator / CI (unit tests, `RewindCamTests/ClipLibraryPrototypeTests.swift`)** against real clips
made by #1's path (`partialClipURL` → `ClipExporter.export` → `commitPartialClip`, synthetic source):

* relaunch and source independence: after the recorder is suspended and launch cleanup wipes the
  ring, a fresh storage/library lists the same clip (same id and size), and it decodes completely
  (`inspectClip`: playable, every frame decodes, audio present);
* pending files: a `.partial.mov` and a Photos staging link are never entries, in either folder, and
  cannot be deleted through the library;
* share: a hard link in `Caches/RewindClips/share-<uuid>/`, playable, not an entry; discarding it keeps
  the clip;
* Photos denied, and Photos failing: the clip and its entry are unchanged, staging is removed;
* recovery-only success: the clip reaches the fake Photos, plays, and the local file is deleted even
  when Keep was asked (today's behaviour);
* Keep locally success: the fake Photos *moves* the staged link (like `shouldMoveFile`); the kept copy
  survives, plays, has left `UnsavedClips/` (so #1's Retry won't re-offer it); re-adding a kept clip
  never deletes it; deleting the kept copy leaves every Photos copy playable;
* a failed move into the kept folder after Photos accepted the clip (a stand-in for a protected-data or
  disk error at that step) keeps the clip in `UnsavedClips/`;
* delete needs a matching confirmation, and for a clip not in Photos an only-copy acknowledgement.

**Not verified (physical device, pending):** real `PHPhotoLibrary` import of a hard link with
`shouldMoveFile` (does Photos keep the inode? does a kept copy stay intact?), Photos denied/limited on a
real prompt, a share sheet with AirDrop/Files/Messages, playback while the camera runs, Data Protection
on a locked phone (the Simulator does not enforce it), and storage numbers in Settings › iPhone Storage.

The prototype is `RewindCam/Library/ClipLibraryPrototype.swift`. It is compiled into the app target
but nothing constructs it (`ClipLibraryPrototype.isEnabledInApp == false`); it is not on
`AppEnvironment`, not used by `AppModel`, not reachable from any view.

## 9. Proposed follow-up issue (not filed)

> **Title:** Let users play, share and delete clips that aren't in Photos yet
>
> **Why:** #1 keeps a clip in the app until Photos accepts it, but the banner only offers Retry. A
> user who denies Photos access can't watch, share or remove those clips, and each keeps its full size
> forever. #16 assessed a permanent library and recommended only this.
>
> **Scope:**
> - A sheet opened from the "N clips aren't in Photos yet" banner (and from Settings when non-empty)
>   listing `BufferStorage.unsavedClips()`: date (from the name), duration, size, and the total.
> - Per clip: Play (`AVPlayer`, capture keeps running), Share (hard link in
>   `Caches/RewindClips/share-<uuid>/`, removed on dismiss and at launch), Add to Photos (the existing
>   retry path for one clip), Delete with a confirmation that says it is the only copy.
> - Reuse #1's records and `stageForPhotos`; no new store, no manifest, no "Keep locally", no change to
>   Photos-first saving or to #13's protection class. Move the needed parts of
>   `ClipLibraryPrototype` into `BufferStorage`/`AppModel` and delete the prototype.
> - Blur the list when the scene goes inactive.
>
> **Acceptance:** unit tests for list/play/share/delete/one-clip retry with `ModelHarness` (Photos
> denied, failing, succeeding; relaunch; partial files never listed; delete confirmation); a UI test
> with `-UITestPhotosFailOnce` that opens the sheet, plays, and deletes; README "Known limits" and
> DESIGN.md §2 updated; #11 accessibility labels. Device checks pending: playback while recording,
> share targets, real Photos import from the sheet.
>
> **Order:** after #10 (its low-disk warning should link to the sheet) and #14; Lane A files
> (`AppModel.swift`, `ContentView.swift`), so serial with #5's lane.
