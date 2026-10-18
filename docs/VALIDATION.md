# Validation and acceptance

Local checks: Swift grammar parsing, build YAML/source paths and byte-for-byte ZIP integrity. Swift/Apple compilation runs on [GitHub Actions](https://github.com/hahanooben123-spec/ornamentalist/actions/workflows/apple-validation.yml); see the run for the tested commit and pass/fail status. A syntax parse does not type-check Swift. No physical iPad/Pencil reliability or latency result is claimed.

Version 0.3.1 adds explicit source-list equality checks and actual SwiftPM target-source discovery. The latter replaces only the AppleProductTypes product with a standard executable product in a temporary copy, retains the exact app target declaration and checks all app paths (29 in version 0.6.0), including DrawingLimits.swift. This does not reproduce iPad preview/cache integration.

## Included automated checks

Version 0.8.0 adds preset-memory/relaunch checks, independent eraser settings, frozen quick controls during a stroke, size-cursor scaling without model revisions, translucent solid-brush persistence and Metal/PNG/live-commit pixel checks. Its UI flow adjusts the native vertical sliders, switches brushes and restores settings, exercises the right sidebar, checks unchanged canvas bounds, draws with a finger, performs actual two-/three-finger taps, pinches without history changes and inspects portrait controls. See [the controls guide](SIDEPANELER-OG-GESTUS.md). These checks do not simulate physical Pencil hover or palm contact.

`swift test` at the repository root runs the actual portable Swift implementation, covering:

- Eight-fold rotations about an arbitrary center and preservation of radius/center.
- Symmetry off and 64 distinct rotational copies.
- Viewport forward/inverse mapping at multiple scales, with pan and rotation.
- Stable incremental live geometry matching geometry reconstructed from stored samples.
- A visible single-point stroke and pressure-dependent width.
- Whole-stroke history, redo, branching, and preservation of earlier symmetry settings.
- Codable round trips and rejection of malformed geometry/settings.
- Repository save/reopen, stale-generation protection, backup recovery, and an unreadable project alongside a valid project.
- Continuous-dotting autosave deadlines, fineliner width, adaptive tips and version 1 migration.
- Input replay with duplicate timestamps, stabilization, temporary predictions and preflight geometry budgets.
- Active-stroke journal recovery, primary/journal revision ordering and editable project round trips without overwrites.
- A thumbnail finishing after a newer primary save must not replace the newer revision's preview.
- An oversized gallery metadata index falls back to the actual saved drawing.
- Reflections around an arbitrary center, 128-transform mirror capacity, immutable stroke layer/mirror settings and schema 2 migration.
- Layer order, visibility/locks, limits/names, deletion with exact Undo/Redo and full layer/mirror project round trips.

The app tests inject a slow repository to reproduce close/Undo races, verify active-stroke checkpoints and read actual offscreen pixels from the same Metal pipeline as the canvas. An asymmetric stroke is checked through zoom, pan and rotation; predicted pixels must disappear on commit. PNG tests check asymmetric orientation, radial copies, dimensions and backgrounds. Metal tests can skip when a simulator has no Metal; skips are not GPU passes. Touch-event routing and palm rejection still require device tests.

Native UI tests exercise named creation, the empty studio, opening saved art, symmetry settings, Undo/Redo, focus, pen and canvas panels, appearance and search. A separate launch flow clears showcase arguments/environment, opens the normal gallery, creates a canvas, saves and relaunches to find the drawing. Debug builds enable actor data-race checks. Screenshot attachments are exported in the workflow's `studio-ui-screenshots` artifact. Procedural example drawings are confined to a temporary test repository and are validated by a separate save/reopen test.

The cloud workflow uses the same app source as the iPad app playground. It does not validate the AppleProductTypes playground manifest itself; opening the supplied `.swiftpm` on iPad remains an explicit acceptance step.

Version 0.3.0 adds native checks of live and committed mirrored Metal pixels, hidden-layer omission in transparent PNG, visibility invalidation and 64-sector/128-transform rendering. A model test freezes layer edits during a stroke and checks locked-layer input eligibility and deleted-ink restoration. The new UI flow toggles Mirror, creates/renames/hides/locks/reorders/deletes/undoes a layer, closes/reopens and verifies the layer selection and Mirror setting. See [the additional physical-iPad checklist](MIRROR-OG-LAG.md).

Another model/view regression immediately undoes a stroke before asynchronous canvas preparation starts, synchronizes again and verifies that input is no longer blocked by a stale preparation flag.

Version 0.4.0 adds eight portable tests covering all 14 preset geometries and settings, live/reopened parity with prediction isolation, event-rate-independent dot spacing, stable seeded scatter and density, legacy decoding, soft coverage, budget rejection before a large allocation, and brush/layer persistence through editable export. Native tests read actual Metal/PNG pixels for separate mirrored dots and gaps, live/committed/reopened equivalence, feathered alpha with cross-renderer tolerance, hidden-layer omission and smoke rendering every preset. A model test freezes brush changes during input and saves settings without changing old ink; a UI flow selects dot/shading families, adjusts opacity and checks selection after reopening. Results are recorded in BUILD_STATUS.md.

Physical brush acceptance: tap and draw slow/fast curves with Dots/Fine dots, compare spacing at different speeds, overlap Soft shader/Airbrush passes, adjust stipple density, enable Mirror, switch/hide layers, Undo/Redo, reopen and export transparent PNG. Confirm that soft shading and dot patterns keep their appearance and that the panel scrolls with the close control available in portrait and multitasking. Dense mirrored shading still needs actual-device responsiveness/memory measurements.

## Real iPad checklist

Record iPad model, iPadOS version, Apple Pencil model, Swift Playground version, build revision, and pass/fail notes. All acceptance items below are currently **pending device verification**.

| Criterion | Action | Expected result |
| --- | --- | --- |
| 1. Runs natively | Open the `.swiftpm` in Swift Playground and Run App | Gallery appears; New drawing → Create drawing opens a native drawing surface |
| 2. Pencil reliability | Draw taps, slow curves, quick curves, varying pressure; rest a palm; lift Pencil; background and return | Pressure changes width, no finger/palm marks in default mode, no stuck active stroke |
| 3. Live eight-way symmetry | Keep Pencil down and draw a long curve with default ×8 | All eight copies grow before Pencil lifts |
| 4. Adjustable count | Draw at ×2, ×8, ×16, ×64, and 1 | New strokes use requested count; earlier strokes remain unchanged |
| 5. Undo/redo | Draw three symmetric strokes; undo twice; redo twice; undo and draw a new stroke | Each undo removes all copies of one source stroke; new branch clears redo |
| 6. Zoom alignment | Zoom to 4×; pan, rotate, draw across guide; reset; repeat near a paper edge | Copies share center and spacing; screen navigation introduces no offset; no ink outside paper |
| 7. Editable persistence | Save, Gallery, reopen; draw another stroke; save; stop and rerun app; reopen | Same artwork and settings return, with new editable source strokes |
| 8. PNG export | Export white and transparent to Files, inspect in an alpha-aware viewer | 2048 square artwork, expected copies, correct background, no guides or interface |
| 9. Functional core controls | Exercise Stepper, width, Guides, Canvas reset, Undo, Redo, Save, Gallery and export | Each visible action changes the intended state or produces an actual file |

Also test iPad multitasking/resize and portrait/landscape changes. A resize should finish confirmed ink before applying a new coordinate mapping. In finger-test mode, verify a two-finger gesture cancels only the unfinished finger stroke and navigates.

## Additional release gates

Run a 10-minute drawing session at eight copies and another at 64. Record visible input lag, allocation failures, memory behavior, edge clipping, exported appearance, and the longest usable stroke. Repeat undo/redo after reopening a dense drawing. There is no certified 120 Hz target in this delivery; `preferredFramesPerSecond` is a request, not a measured result.

Exercise storage failure/recovery with a test app container or development device. Export an editable project to Files, import it twice and confirm the copies do not overwrite the source. Rename projects and inspect their thumbnails. Background saving and the rolling journal are best effort: a kill before a write completes can lose recent input. Test canceled finger strokes after a journal checkpoint; they must not return after a successful subsequent save. Large-document rendering still needs further work before production performance claims.

Use **Canvas → Drawing performance** after drawing at eight and 64 copies, copy the report and record it beside the device/OS/Pencil details. Its last 240 CPU/GPU samples and buffer bytes are diagnostics, not a substitute for touch-to-screen latency measurement or memory profiling.

Do not declare Phase 1 complete until all nine real-device criteria pass. Keep any Swift/Metal compiler diagnostics or device failures with their file/line and reproduction steps for the next fix.

## Colors and layer opacity (0.5.0)

Portable tests cover strict HEX validation, sRGB/HSB round trips, schema-4 migration to black/full opacity, independent visibility and opacity with Undo/Redo, captured stroke color and editable project round trips including recent colors. Native tests compare overlapping red strokes on one 50%-opacity layer above blue, temporary live ink, transparent PNG alpha, hiding/zero opacity and layer order. Each brush is rendered in color through actual Metal and PNG. A model test coalesces a slider drag into one undo and freezes color/layer edits during drawing. UI tests enter HEX, adjust opacity, hide/show and reopen a project to check persisted values.

Device acceptance must include picking from the ring and saturation/value square, choosing white/black, HEX typing with the keyboard, VoiceOver slider/wheel adjustment, two differently colored layers, hiding/unhiding, group opacity across overlapping strokes, all brush families, Mirror, and transparent export. Profile dense artwork and resizing/multitasking while changing layer opacity. The grouped Metal path uses one reusable layer target per command buffer and permits only one grouped display frame in flight; this bounds transient targets by viewport size and sample count, not layer count, but is not a physical-device memory or latency measurement.

## Editing tools and layer operations (0.6.0)

Portable tests cover duplication with fresh stroke identities and preserved deterministic pattern seeds, atomic rejection at layer budgets, merge replacement and exact Undo/Redo, merge visibility/locking guards, bounded PNG header/raster identity validation, eraser operation migration and format-6 editable project round trips. Header-only fixtures test Foundation validation; ImageIO decoding is tested separately in the native layer.

Native tests compare live/committed/reopened mirrored eraser pixels, reveal an unchanged lower layer, Undo/Redo and transparent PNG holes. Merge tests compare pre/post PNG colors/alpha at asymmetric points, actual Metal raster orientation, erasing the merged base and thumbnail creation. Pipette tests cover composited colors, hidden layers, white paper, erased holes and out-of-paper rejection. Soft eraser/duplicate alpha and model merge/undo/save/tool state are also covered. The UI flow selects an eraser, changes its edge, samples from the canvas, duplicates a populated layer, captures thumbnails, merges and undoes.

Physical acceptance: draw and erase hard/soft strokes with Pencil at several zoom/rotation levels, enable Mirror, hide/lock and change opacity on lower layers, sample fine details with the pipette, duplicate stipple, merge layers with different opacities, Undo/Redo and save/reopen/import. Confirm thumbnails update without input stalls, portrait/multitasking tool availability and adequate memory during merge or restoring merged layers. These device checks remain separate from simulator tests.

## Rendering caches (0.7.0)

Portable tests compare incremental vertex pricing with full replay for all fourteen brush presets. Native tests compare cached and reference pixels during live soft ink/erasing, multiple static layers, commit, Undo/Redo, navigation, layer edits, resizing and memory fallback; concurrent readbacks must retain their own outputs. Warm frames must allocate no new working textures and replay no committed source strokes; committing one new stroke must encode only that stroke. Layer preview caching must track content while ignoring visibility/group opacity. Comparative 8/64-sector + Mirror timing attachments cover static frames and live ink/erase at 512 pixels, including GPU wait/readback. Simulator timings are not physical Pencil latency/FPS. See HASTIGHED.md for real-device acceptance and cache-memory limits.
