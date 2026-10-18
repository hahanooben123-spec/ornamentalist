# Verified build status — 18 October 2026

## Current: 0.3.1 explicit playground target sources

The device reports `DrawingLimits.swift not in a target` while updating previews, with a File Provider URL. The file is present and was inside the recursively discovered app target in previous packaging. The screenshot does not establish why the installed Swift Playground loses its target association. Version 0.3.1 lists all 21 source paths explicitly in the app manifest and checks that this list exactly matches delivered files. A new cloud check uses actual SwiftPM target discovery with only the AppleProductTypes product replaced by a standard executable product; it preserves the app target path/source list. That check and the Apple tests are pending. The exact AppleProductTypes manifest and iPad provider/preview cache remain device-only acceptance steps.

## Previous: 0.3.0 Mirror and layers

Mirror reflection, ordered layers, layer visibility/locking/naming/reordering/deletion, layer-aware input and rendering/export, schema 1/2 migration and structural Undo/Redo are implemented. See [the feature guide](MIRROR-OG-LAG.md).

[Apple validation run 39110341009](https://github.com/hahanooben123-spec/ornamentalist/actions/runs/39110341009) passed for app-source commit `4810d3555b6de13f5080bd892f11468c4d913e36`: **45 tests passed**, comprising 27 portable Swift tests, 13 native unit tests and 5 native UI tests. There were no failed/skipped tests or Swift source compiler warnings. Tool/metadata notices remain. Debug actor data-race checks were enabled; simulator iPad Air 11-inch (M3), iOS 26.2, Xcode 26.6.

- Portable checks cover reflection at an arbitrary center, 128 transforms, layer order/visibility/locks, limits/names, precise layer-deletion Undo/Redo, immutable input layer/mirror state, version 2 migration and editable repository/export/import round trips.
- Native pixel checks verify live and committed reflection, hidden-layer omission from transparent PNG, unhiding without changing stroke IDs and 64-sector/128-transform Metal rendering. Model checks freeze edits during a stroke, block drawing on locked layers, restore deleted ink and clear canceled preparation after immediate Undo.
- The new UI flow toggles Mirror; adds, names, hides, locks, reorders and deletes a layer; undoes deletion; closes/reopens the drawing and verifies both layer selection and Mirror. The four existing UI flows also pass.
- Native Mirror/Layers panel screenshots were inspected from the earlier green [44-test feature run 39110028885](https://github.com/hahanooben123-spec/ornamentalist/actions/runs/39110028885); UI source is unchanged in the latest revision. Those local images are in `dist/ui-preview/39110028885`. The later revision adds cancellation safety and its regression test.

Local Swift grammar, 21-source inventory and byte-for-byte source ZIP checks pass. The direct public repository download was verified without authentication and every Swift file matched the tested Git commit. Later delivery documentation changes do not change app source. The user confirmed 0.2.2 runs on the physical iPad; **0.3.0 still needs Pencil/device verification**, particularly live mirroring, layer switching and multitasking. The cloud Xcode target still does not exercise the AppleProductTypes manifest.

## Previous: 0.2.2 device compiler compatibility

The physical iPad exposed an explicit `Ambiguous use of 'cos'` build error in StudioPanels. Version 0.2.2 removes mixed Double/CGFloat overload inference in the symmetry preview and related ornament. It also changes the unmutated Metal uniforms array to a constant.

[Apple validation run 39109017201](https://github.com/hahanooben123-spec/ornamentalist/actions/runs/39109017201) passed for app-source commit `7859c245457e6053c67da9690d3007a8e729ed4f`: **32 tests passed** (19 portable, 9 native unit, 4 UI), including normal launch without showcase data, saving/relaunching and opening the symmetry panel. Normal-launch UI flow passed in 26.950 seconds. No Swift source warnings or compilation errors were reported in this run; tool/metadata notices remain. Local grammar and byte-for-byte package checks also pass.

The simulator is iPad Air 11-inch (M3), iOS 26.2, using Xcode 26.6/SDK 26.5. Earlier Xcode tests also accepted the ambiguous expression, so this green run is regression evidence, not reproduction of the device compiler diagnostic. Building the corrected full package in the user's installed Swift Playground is still required to confirm device compatibility. No success for 0.2.2 on the physical iPad has been reported yet.

The [direct source download without GitHub login](https://github.com/hahanooben123-spec/ornamentalist/archive/7859c245457e6053c67da9690d3007a8e729ed4f.zip) was verified to contain the corrected source and 0.2.2 manifest. Open `Ornamentalist.swiftpm` in the archive's main folder, rather than the optional minimal package under `Diagnostics`. The local iPad ZIP is rebuilt with the same app source and updated delivery documentation.

## Previous: 0.2.1 startup audit

[Apple validation run 39105575507](https://github.com/hahanooben123-spec/ornamentalist/actions/runs/39105575507) passed at app-source commit `0c775afbf15b192eab876d31d1c6cb7ca4889f4e`: **32 tests passed**, comprising 19 portable Swift tests, 9 native unit tests and 4 UI tests. No test was skipped. Messages saying an attachment export was skipped refer to tests without screenshots, not skipped tests.

The new oversized metadata-index regression passed. The new `testNormalLaunchWithoutShowcase` passed in 30.591 seconds: no showcase environment/arguments, normal repository and gallery, create a default drawing, open the Metal canvas, save/close, terminate/relaunch and find the saved drawing. Debug actor data-race checks were enabled. The simulator remains iPad Air 11-inch (M3), iOS 26.2, Xcode 26.6, deployment target 17. The logs show the studio-visible and gallery-loaded milestones. Compiler warnings include an existing unmutated `uniforms` variable; no Swift compilation errors occurred.

Download the [0.2.1 iPad source artifact](https://github.com/hahanooben123-spec/ornamentalist/actions/runs/39105575507/artifacts/12127793881). The local ZIP is rebuilt from the same app source, with subsequently updated delivery documentation. The artifact includes documentation as it stood at the verified commit.

**The user's physical iPad Swift Playground crash is unresolved.** The simulator has not reproduced it. See [the audit](CRASH-AUDIT.md) for confirmed findings, preventive changes and limitations. The AppleProductTypes manifest is still not exercised by this Xcode target. Open the newly extracted package on iPad to test the update; the previously opened Playground does not update from GitHub automatically.

## Previous: 0.2.0 interface validation

The updated native studio interface passed compilation and **30 automated tests** in [Apple validation run 39103943920](https://github.com/hahanooben123-spec/ornamentalist/actions/runs/39103943920), app-source commit `91d977886556f1cd02fbadaa0b61cbb591de8d48`.

- **18 portable Swift tests passed**: geometry, symmetry, input replay/stabilization, budgets, history, autosave deadlines, migration, journal recovery, project import/export and rejection of a late thumbnail after a newer save.
- **9 native iPad simulator tests passed**, with no test skips: asymmetric Metal pixels under navigation, temporary prediction removal, PNG dimensions/transparency/orientation, shader compilation, 8/64-copy timing samples, save/close races, active-stroke recovery, canceled checkpoint removal and valid save/reopen of the screenshot fixtures.
- **3 native UI tests passed**: named creation, empty studio, gallery/open, symmetry selection and accessible copy count, Undo/Redo, focus/restore, brush and canvas panels, dark appearance and search after rotating to portrait.
- The simulator was **iPad Air 11-inch (M3), iOS 26.2**; the deployment target remains iPadOS 17.
- Real SwiftUI/Metal screenshots were visually inspected for the landscape gallery, editor, symmetry and brush panels, focus and dark gallery. Local previews are in `dist/ui-preview/39103943920`. The original portrait attachment caught the rotation transition; its subsequent portrait search passed. Screenshot capture now follows that interaction to avoid the transition in later runs.
- Gallery return waits for the durable drawing save, then prepares the replaceable preview in the background. Revision checks reject outdated previews. The latest source ZIP was rebuilt and verified byte-for-byte on Windows.

These results validate the Xcode app target built from the same Swift source. They do not validate opening the AppleProductTypes manifest in the installed iPad Swift Playground version, physical Pencil/palm behavior, actual device memory or touch-to-photon latency. VoiceOver traversal, accessibility text sizes and physical iPad multitasking still require device acceptance. Complete [the device checklist](VALIDATION.md) before declaring Phase 1 acceptance complete.

The workflow artifacts are `Ornamentalist-iPad` (source ZIP), `apple-test-results` (the `.xcresult` record) and `studio-ui-screenshots` (native screenshot/video attachments and their manifest). The source ZIP is not a signed installable app. After this verified app commit, delivery documentation and the screenshot timing were updated without changing the app source.
