# RewindCam

A free, private, offline **pre-record camera** for catching a baby's spontaneous milestones.
The camera records all the time into a rolling buffer that never grows. When something happens, tap
**Save** (or press a volume button) and the last *N* seconds land in Photos.

Nothing leaves the phone: no network code, no accounts, no analytics.

See [DESIGN.md](DESIGN.md) for the architecture and the buffer/disk math.

## Task checklist

Each feature lands with its own tests and its own green CI run.

- [x] DESIGN.md: architecture and buffer math
- [x] Minimal green pipeline (XcodeGen, macOS 26 runner, newest Xcode, dynamic simulator, artifacts)
- [ ] Rolling buffer engine: HLS-profile fMP4 segments, ring eviction, bounded disk
- [ ] Save: concatenate → trim → passthrough `.mov`; early save; post-roll
- [ ] Interruptions: buffer resets cleanly, no corrupt clips
- [ ] Thermal step-down policy
- [ ] Settings persistence
- [ ] App model + SwiftUI UI (Save button, toast, haptic, settings, dim mode, battery)
- [ ] Volume buttons via `AVCaptureEventInteraction`
- [ ] UI tests with screenshots (`-UITestMode`)
- [ ] Orphan cleanup on launch
- [ ] Final README: screenshots, limits, device install
- [ ] Stretch: on-device voice trigger ("save that"), behind a setting

## License

MIT — see [LICENSE](LICENSE).
