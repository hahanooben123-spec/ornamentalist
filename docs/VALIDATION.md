# Validation and acceptance

Local checks: Swift grammar parsing, build YAML/source paths and byte-for-byte ZIP integrity. Swift/Apple compilation runs on [GitHub Actions](https://github.com/hahanooben123-spec/ornamentalist/actions/workflows/apple-validation.yml); see the run for the tested commit and pass/fail status. A syntax parse does not type-check Swift. No physical iPad/Pencil reliability or latency result is claimed.

## Included automated checks

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

The app tests inject a slow repository to reproduce close/Undo races, verify active-stroke checkpoints and read actual offscreen pixels from the same Metal pipeline as the canvas. An asymmetric stroke is checked through zoom, pan and rotation; predicted pixels must disappear on commit. PNG tests check asymmetric orientation, radial copies, dimensions and backgrounds. Metal tests can skip when a simulator has no Metal; skips are not GPU passes. Touch-event routing and palm rejection still require device tests.

Native UI tests exercise named creation, the empty studio, opening saved art, symmetry settings, Undo/Redo, focus, pen and canvas panels, appearance and search. Screenshot attachments are exported in the workflow's `studio-ui-screenshots` artifact. Procedural example drawings are confined to a temporary test repository and are validated by a separate save/reopen test.

The cloud workflow uses the same app source as the iPad app playground. It does not validate the AppleProductTypes playground manifest itself; opening the supplied `.swiftpm` on iPad remains an explicit acceptance step.

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
