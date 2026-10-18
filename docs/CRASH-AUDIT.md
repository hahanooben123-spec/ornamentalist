# iPad startup audit — 18 October 2026

The user subsequently confirmed that version 0.2.2 runs on the physical iPad after the concrete compiler fix below. Earlier investigation notes are retained as history. Version 0.3.0 adds Mirror/layers and requires its own device acceptance.

## Confirmed device compiler error: 0.2.2 correction

The latest device screenshot exposes a red **“Ambiguous use of 'cos'” in StudioPanels**. This is a confirmed build blocker; the accompanying yellow `uniforms` message is only an unmutated-variable warning. A generic “Crashed / Build failed” screen did not previously reveal this compiler diagnostic.

`SymmetryPreview.path` combined a `Double` angle with a `CGFloat` radius in one expression. Version 0.2.2 explicitly calls `Darwin.cos`/`Darwin.sin` with a `Double`, converts their results to `CGFloat`, and then performs only `CGFloat` coordinate arithmetic. The related ornament in `StudioTheme` uses the same explicit boundary. The unmutated Metal uniform array is now a `let` constant. These changes preserve the mathematical values while removing overload ambiguity for the device compiler.

The full app package is the next device test; the separate minimal diagnostic is no longer the first troubleshooting step. The screenshot establishes the build failure's reported cause, but does not prove there are no subsequent device errors. See BUILD_STATUS.md for validation of the corrected source.

## Earlier investigation

The physical iPad reports “Crashed” with an empty console. No crash report or device/OS details are available. **The cause is not established.** A passing Xcode simulator run cannot establish Swift Playground compatibility on this device.

Subsequent device evidence: Swift Playground shows “Build failed”; replacing the main window with a plain `Text` still fails, but a newly created Apple-standard App project runs successfully. Replacing the window does not remove the other source files from compilation. The next isolation step is the separate one-source [diagnostic package](STARTTEST.md), which has not yet been run on the device.

## Review and changes in 0.2.1

- Reviewed all 19 app Swift files, the AppleProductTypes manifest and delivery script. There is one app entry point; the manifest requires iPadOS 17 and Swift tools 5.9. The initial screen is the gallery. Metal is created only after a drawing is opened/created, so a crash before the gallery appears does not implicate Metal initialization.
- Found an unbounded metadata read in gallery startup: the replaceable `.index` file was loaded without checking its size or title/stroke-count fields. It now has a 16 KiB read limit and validated fields; an invalid index falls back to the saved drawing. Added a regression test with a valid JSON index containing an oversized title. This is a robustness fix, not a confirmed explanation for a crash on an empty first installation.
- Explicitly marked Metal completion handlers and the dynamic UIColor provider `@Sendable`. Framework callbacks must not accidentally inherit an actor requirement when called on a framework queue. Existing UI updates still hop to the main actor. This is preventive hardening; no device actor-isolation crash has been observed. See Swift's [incremental concurrency adoption guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/) for runtime checks at callback boundaries.
- Enabled actor data-race runtime checks in the cloud Debug build.
- Added a UI test with no showcase arguments or environment. It starts the normal gallery/storage path, creates a canvas, returns to the gallery, terminates/relaunches and checks that the saved drawing is present. Earlier UI tests used isolated test repositories.
- Added three plain console milestones: app entry, studio visible/loading gallery, and gallery load finished. They contain no user content. These cannot capture a crash before app entry or guarantee that Swift Playground connects its console.

## Verification

Windows grammar/package checks do not compile Swift. See BUILD_STATUS.md for the corresponding Apple compiler/test run and any remaining limits. The package cannot be declared fixed on the physical iPad until the updated source runs there.

The fatal coder initializer belongs to a programmatically constructed MTKView and is not called by the normal app path. Other unsafe pointer accesses in Metal are guarded by nonempty storage or validated dimensions. No blanket removal of those guards or forced resets of user storage was made.
