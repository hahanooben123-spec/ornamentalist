# Ornamentalist — Phase 1

[Dansk vejledning: Kom i gang på iPad](docs/KOM-I-GANG.md)

A native iPad app playground in Swift and SwiftUI, with UIKit Pencil input and Metal drawing. No external package dependencies. The adapted MIT-licensed ColorPickerRing wheel is included locally, with its license in ThirdParty/. Target: iPadOS 17 or later, with a Swift Playground installation that includes a compatible SDK.

**Delivery status:** The hardened Phase 1 native source has passed a cloud Apple build and automated tests; see [verified build results](docs/BUILD_STATUS.md). This Windows environment has neither Swift nor an Apple SDK. Local grammar checks are separate from Apple compilation. Physical iPad/Pencil acceptance remains pending.

## Start on your iPad

1. Put `dist/Ornamentalist-iPad.zip` in Files on your iPad, using iCloud Drive, OneDrive, USB file transfer, or another file service you already use.
2. Tap the ZIP in Files to extract it. Inside, find **Ornamentalist.swiftpm**. Open/share that app playground with **Swift Playground** (formerly Swift Playgrounds). Open the `.swiftpm` document, not the repository's root `Package.swift`.
3. Let the app playground load, then tap **Run App**. No Swift packages, permissions, terminal, CocoaPods, or custom shader build phase are required.
4. Tap **New drawing**, give it a name, then **Create drawing**. Draw on the white paper with Apple Pencil. The default is eight radial copies.
5. Open **Symmetry** and use a preset or the Stepper to set 1–64 copies. One means symmetry off. Existing strokes keep their original symmetry.
6. Use two fingers to pan, pinch to zoom, or rotate. Navigation pauses during a Pencil stroke so a palm cannot shift its coordinate frame. **Canvas → Fit drawing to screen** restores the fit.
7. Use Undo/Redo for complete symmetric strokes. Use **Save and export → Save drawing** to save immediately. Completed edits autosave after 0.5 seconds idle or two seconds of continuous editing, checked by a 0.25-second timer. Confirmed points of an active stroke are checkpointed separately. **Gallery** locks editing and saves before closing; tap a project to reopen and keep drawing.
8. Use the export icon → **PNG · White paper** or **PNG · Transparent** and choose **Save to Files** in the iPad share sheet. Export is 2048 × 2048 pixels; guides are excluded.
9. Use the export icon → **Editable project** to save an `.ornamentalist.json` backup in Files. In Gallery, tap **Import** to reopen it as a new editable project. Imports never overwrite the original.
10. Use the ellipsis on a gallery card, or touch and hold its preview, to **Rename**. Search and sort your drawings above the cards. Thumbnails render in the background after you return to Gallery; the actual drawing is saved before closing. The floating **Brushes** panel contains 14 procedural ink, shading, dot/stipple and texture brushes with native previews and size/opacity/spacing/density controls; see [the brush guide](docs/PENSLER.md). **Symmetry** provides presets and a precise 1–64 Stepper. Changes apply to the next stroke.
11. After a drawing test, open **Canvas → Drawing performance** to inspect and copy CPU submission/GPU timing samples and source-buffer memory. This does not measure Pencil-to-display latency or total app RAM.

The warm paper gallery and floating studio controls follow system light/dark appearance; **Canvas → Studio appearance** can override it. The drawing paper stays white. The upper-right focus button hides the controls; its replacement restores them. Panels overlay the canvas without changing its coordinate frame. Apple Pencil draws by default. Optional **Canvas → Draw with finger** is for basic testing. Starting a two-finger gesture cancels an unfinished finger stroke. Finger mode is not the palm-rejection mode.

### If Swift Playground rejects the packaged manifest

App playground manifest handling can vary across installed versions. Update Swift Playground first. If the `.swiftpm` document still cannot open, use this entirely iPad-based fallback:

1. Create a new **App** in Swift Playground, named Ornamentalist.
2. Remove its generated `MyApp.swift` and `ContentView.swift` source files. There must be exactly one `@main` declaration.
3. Use the sidebar **+ → Insert from** to add all **29 `.swift` source files** inside the supplied `Ornamentalist.swiftpm` folders, excluding `Package.swift`. You can also add empty Swift files and paste each file's complete contents. Folder layout is organizational; all files belong to the same app target.
4. Keep the new app's automatically generated manifest. Use an iPadOS 17+ deployment target and Swift 5 language mode if those options are exposed. The supplied source uses Swift 5.9 syntax.
5. Run App again. You do not need the repository's `Tests`, cloud workflow, or `project.yml` on iPad.

Apple documents adding Swift files and inserting files from Files in its [iPad guide](https://support.apple.com/en-lamr/guide/playgrounds-ipad/itc18b7bce9d/4.6/ipados/18.0). See [technical feasibility](docs/FEASIBILITY.md) for environment and distribution limits.

## Implemented scope

Version 0.3.0 adds **Mirror** under Symmetry and a **Layers** panel: up to 32 layers, selection, visibility, locking, renaming, reordering and confirmed deletion. Undo/Redo covers layer edits and restores deleted ink. Mirror adds reflection across radial guide axes (up to 128 copies at 64 sectors). Canvas, thumbnails and PNG use visible layers in stacking order; editable projects retain every layer. Schema 1/2 drawings migrate to one visible layer without mirror. See the [Danish feature guide](docs/MIRROR-OG-LAG.md) and [build status](docs/BUILD_STATUS.md).

| Area | Phase 1 implementation |
| --- | --- |
| Input | Pencil-only default; coalesced samples; replaceable predicted tail; normalized pressure; stored altitude and azimuth |
| Brushes | 14 ink, soft shading, dots/stipple and texture presets; size, stamp opacity/spacing/density, pressure and stabilization; old ink preserved |
| Symmetry | Identity/off and 2–64 radial rotations; copies instanced during drawing; settings frozen per stroke |
| Navigation | Invertible document/view transform; two-finger pan, anchored pinch zoom, anchored rotation; reset |
| History | Undo/redo of whole source strokes and their instances; new strokes invalidate the redo branch |
| Storage | Versioned JSON, atomic saves, rolling active-stroke recovery journal, prior valid backup, gallery previews, renaming and metadata index |
| Export | White/transparent PNG, editable project export/import via Files, native iPad share sheet |

There are no unimplemented core toolbar actions. Movable center UI, imported/custom brushes, precision shapes, image import, stencil mode, physical dimensions, SVG, PDF, and cloud sync remain later work. Altitude and azimuth are retained but do not change this brush. Undo history is session-local; saved source stroke geometry remains editable after reopening, while a merged base retains pixels instead of its original individual strokes. Version 1 projects retain their original pressure and tip geometry when decoded; version 2 stores brush geometry version and storage revisions explicitly.

Colors: open the header color circle for the hue wheel, saturation/brightness square and sliders, HEX, a studio palette and 12 recent colors. Layers: select a layer for 0–100% group opacity; the eye hides/shows it without changing its opacity. See [the color/opacity guide and open source credits](docs/FARVER-OG-OPACITY.md).

Eraser and eyedropper are available in the header (Drawing tools menu in compact layouts). Layers include transparent thumbnails, Duplicate layer and Merge down. Merging bakes two visible/unlocked layers into a transparent pixel base, preserving their composite appearance; Undo restores the original layers before closing. See [editing tools and layer guide](docs/REDIGERING-OG-LAG.md) for workflow and merge limits.

## Source layout

```text
Ornamentalist.swiftpm/
  Package.swift                        iPad app playground metadata
  App/OrnamentalistApp.swift            app entry point
  Core/Geometry.swift                  affine matrices and viewport
  Core/DrawingLimits.swift             geometry budgets and save scheduling
  Core/SymmetryEngine/                  radial configuration and transforms
  Core/StrokeModel/                     samples, input/stabilizer session, validation, history
  Core/BrushEngine/                     procedural presets and deterministic dab sampler
  Core/StrokeGeometry.swift             shared incremental tessellation
  DrawingEngine/PencilCanvasView.swift  touch input and navigation
  CanvasRenderer/                       runtime Metal pipeline and buffers
  DocumentStore/                       repository actor and UI session state
  ExportEngine/                        document-space PNG generation
  UIComponents/                        gallery, editor, controls, share sheet
Tests/                                 portable Swift and iOS-specific tests
project.yml                            cloud-only XcodeGen project description
.github/workflows/apple-validation.yml  macOS build and test workflow
```

LayerManager implements adding, renaming, hiding, locking, reordering, duplicating, merging and deleting layers with Undo/Redo. Format 6 retains ink/erase operations, deterministic pattern seeds and bounded merged PNG bases alongside per-stroke sRGB color, recent color choices, isolated layer opacity and procedural brush settings. Source strokes retain their layer and radial/mirror configuration. Renderer buffers, live predictions, and navigation state are not serialized. See [architecture](docs/ARCHITECTURE.md), [repository evaluation](docs/RESEARCH.md), and [verification checklist](docs/VALIDATION.md).

## Apple build verification without owning a Mac

The app manifest explicitly enumerates all 29 sources, and packaging checks that this list matches the shipped files exactly. `python3 tools/check_playground_target.py` additionally uses real SwiftPM source discovery in a temporary copy with a standard executable product. It preserves the exact target declaration but replaces AppleProductTypes application metadata; it therefore verifies target source membership, not the installed iPad editor's preview/file-provider integration.

The supplied GitHub Actions workflow runs on a hosted macOS runner in [the Ornamentalist repository](https://github.com/hahanooben123-spec/ornamentalist). Open **Actions → Apple validation** to inspect builds. A green build verifies compilation/tests, not physical Pencil behavior. The job also uploads a source ZIP for iPad.

The workflow runs `swift test` against the actual input model, geometry, history, limits, migration, journal and repository code. It then builds the same app source and runs simulator tests for save/close races, PNG pixels/transparency and actual offscreen Metal output with asymmetric strokes, navigation and temporary predictions. No signing secrets are required. A Metal test skip is not a Metal pass.

For optional manual execution on a cloud Mac:

```sh
swift test
brew install xcodegen
xcodegen generate
xcodebuild test -project Ornamentalist.xcodeproj -scheme Ornamentalist \
  -destination 'platform=iOS Simulator,id=YOUR_AVAILABLE_IPAD_SIMULATOR_UUID' \
  CODE_SIGNING_ALLOWED=NO
```

An unsigned simulator app cannot be installed on your physical iPad. Run the app directly in Swift Playground for the first device test. A standalone TestFlight/App Store build requires your own Apple signing and distribution setup; that is a later cloud workflow, described in [feasibility](docs/FEASIBILITY.md).

## Storage and prototype limits

Drawings remain in Documents/MandalaDrawings for compatibility with existing installs. `.mandala` is the primary JSON, `.backup` the prior valid save, `.journal` the rolling active-stroke checkpoint, `.index` lightweight gallery metadata, and `.png` a replaceable thumbnail. Persisted revision numbers prevent an old journal from replacing a newer primary. Gallery reports recovery. Export `.ornamentalist.json` files to keep editable backups outside the app; uninstalling can remove local app documents.

Autosave has both idle and maximum dirty deadlines. A two-second rolling journal captures confirmed active points; predictions are excluded. Deactivation finishes confirmed input and requests a primary save. These are best-effort deadlines, not guaranteed disk-write completion times. A sudden kill can still lose points since the latest completed checkpoint; there is no synchronous per-sample durability guarantee. A failed primary save retries after five seconds and remains visible.

Validation bounds are 64 MB encoded data, 20,000 source strokes, 100,000 samples per document, 20,000 samples per stroke, 250,000 estimated vertices per stroke and 2,000,000 across the document. Input reserves tail geometry before accepting each sample. The source GPU vertex budget is about 32 MB; frame buffers, MSAA, predictions, metadata and temporary copies use additional memory. Mesh reconstruction runs off the main actor. Paper, guides and symmetry coefficients are cached. These are guardrails, not certified capacity or latency targets. Full-scene replay, large exports, estimated-property correction and physical-device profiling still need hardening.

To rebuild the iPad archive from this workspace, run `python tools/package_ipad.py`. This checks and packages source; it does not compile Swift.
