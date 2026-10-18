# Verified build status — 18 October 2026

The updated native studio interface passed compilation and **30 automated tests** in [Apple validation run 39103943920](https://github.com/hahanooben123-spec/ornamentalist/actions/runs/39103943920), app-source commit `91d977886556f1cd02fbadaa0b61cbb591de8d48`.

- **18 portable Swift tests passed**: geometry, symmetry, input replay/stabilization, budgets, history, autosave deadlines, migration, journal recovery, project import/export and rejection of a late thumbnail after a newer save.
- **9 native iPad simulator tests passed**, with no test skips: asymmetric Metal pixels under navigation, temporary prediction removal, PNG dimensions/transparency/orientation, shader compilation, 8/64-copy timing samples, save/close races, active-stroke recovery, canceled checkpoint removal and valid save/reopen of the screenshot fixtures.
- **3 native UI tests passed**: named creation, empty studio, gallery/open, symmetry selection and accessible copy count, Undo/Redo, focus/restore, brush and canvas panels, dark appearance and search after rotating to portrait.
- The simulator was **iPad Air 11-inch (M3), iOS 26.2**; the deployment target remains iPadOS 17.
- Real SwiftUI/Metal screenshots were visually inspected for the landscape gallery, editor, symmetry and brush panels, focus and dark gallery. Local previews are in `dist/ui-preview/39103943920`. The original portrait attachment caught the rotation transition; its subsequent portrait search passed. Screenshot capture now follows that interaction to avoid the transition in later runs.
- Gallery return waits for the durable drawing save, then prepares the replaceable preview in the background. Revision checks reject outdated previews. The latest source ZIP was rebuilt and verified byte-for-byte on Windows.

These results validate the Xcode app target built from the same Swift source. They do not validate opening the AppleProductTypes manifest in the installed iPad Swift Playground version, physical Pencil/palm behavior, actual device memory or touch-to-photon latency. VoiceOver traversal, accessibility text sizes and physical iPad multitasking still require device acceptance. Complete [the device checklist](VALIDATION.md) before declaring Phase 1 acceptance complete.

The workflow artifacts are `Ornamentalist-iPad` (source ZIP), `apple-test-results` (the `.xcresult` record) and `studio-ui-screenshots` (native screenshot/video attachments and their manifest). The source ZIP is not a signed installable app. After this verified app commit, delivery documentation and the screenshot timing were updated without changing the app source.
