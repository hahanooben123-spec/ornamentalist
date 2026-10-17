# Validation and acceptance

Status at delivery: static source/package checks only. There is no Swift compiler, Apple SDK, iPad connection, or Mac runner attached to this Windows session. The included Swift tests and CI job have **not** been executed here. No screenshot, frame-rate measurement, or Pencil reliability result is claimed.

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

The XcodeGen app test target adds PNG decoding/pixel checks for output dimensions, expected radial copies, transparent/white corners, and Metal runtime pipeline creation. The Metal test does not verify visible output or latency and can skip when a simulator has no Metal device.

The cloud workflow uses the same app source as the iPad app playground. It does not validate the AppleProductTypes playground manifest itself; opening the supplied `.swiftpm` on iPad remains an explicit acceptance step.

## Real iPad checklist

Record iPad model, iPadOS version, Apple Pencil model, Swift Playground version, build revision, and pass/fail notes. All acceptance items below are currently **pending device verification**.

| Criterion | Action | Expected result |
| --- | --- | --- |
| 1. Runs natively | Open the `.swiftpm` in Swift Playground and Run App | Gallery appears; New canvas opens a native drawing surface |
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

Exercise storage failure/recovery with a test app container on the cloud Mac or a development device. The repository tests corrupt a primary in temporary storage, but real application-container recovery still needs verification. Background saving is best effort: a process kill before the write completes can lose recent input. Phase 4 needs a journal, a global geometry budget, and large-document rendering work before claiming production crash recovery/performance.

Do not declare Phase 1 complete until all nine real-device criteria pass. Keep any Swift/Metal compiler diagnostics or device failures with their file/line and reproduction steps for the next fix.
