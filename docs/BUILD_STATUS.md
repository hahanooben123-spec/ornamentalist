# Verified build status — 17 October 2026

The native application source passed compilation and **25 automated tests** in [Apple validation run 39022548794](https://github.com/hahanooben123-spec/ornamentalist/actions/runs/39022548794), commit `1e10564edbab5c66eb8acc3119a27a6e25e93c83`.

- **17 portable Swift tests passed** on macOS: geometry, symmetry, input replay/stabilization, budget limits, history, autosave deadlines, migration, journal recovery and editable project import/export.
- **8 iPad simulator tests passed**, with no skips: asymmetric Metal pixel readback under navigation, temporary prediction removal, PNG dimensions/transparency/orientation, runtime shader compilation, 8/64-copy timing samples, active-stroke recovery, canceled checkpoint removal and closing while save is delayed.
- The simulator was **iPad Air 11-inch (M3), iOS 26.2**; the application deployment target is iPadOS 17.
- The 8/64-copy timing sample renders 48 source strokes, three frames at each count. Its timing attachment is kept in `.xcresult`; simulator render+readback timings do not measure physical iPad latency or FPS. Later runs are available in [GitHub Actions](https://github.com/hahanooben123-spec/ornamentalist/actions/workflows/apple-validation.yml).

These results validate the Xcode app target built from the same Swift source. They do not validate opening the AppleProductTypes manifest in the installed iPad Swift Playground version, physical Pencil/palm behavior, actual device memory or touch-to-photon latency. Complete [the device checklist](VALIDATION.md) before declaring Phase 1 acceptance complete.

The workflow's `Ornamentalist-iPad` artifact contains the app-playground source ZIP. `apple-test-results` contains the `.xcresult` test record. New commits are tested automatically; always check the commit/run status before using a future build.
