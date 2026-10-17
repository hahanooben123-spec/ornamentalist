# Open-source evaluation — 17 October 2026

Decision: use no external drawing dependency for Phase 1. This is a scoped source/documentation review, not a build, benchmark, complete code audit, or legal opinion. No code from the three projects was copied. Recheck the exact license files, notices, dependencies, and pinned revisions before incorporating any of their code in a release.

## alfredang/sketchbookapp

The [repository README](https://github.com/alfredang/sketchbookapp) declares MIT licensing and describes a SwiftUI/PencilKit app with JSON documents. That is a promising native iPad architectural reference. Its [SymmetryEngine source](https://github.com/alfredang/sketchbookapp/blob/main/Sketchbook/Drawing/SymmetryEngine.swift) transforms supplied PKStroke arrays. The README explicitly says mirroring happens on stroke commit, so its described approach does not meet this project's continuous radial-copy requirement.

The folder separation between models, storage, drawing, and features is useful. Its breadth of features is not evidence that all paths are production ready; there was no local build or test audit. A sample source review cannot establish overall code quality. The documented XcodeGen, iCloud, and AR setup needs adaptation for an iPad playground. Do not import the whole project. Use the organizational ideas; keep our independent sample model and live GPU instancing.

Maintenance: the viewed repository page exposed no reliable latest-commit timestamp or release baseline. Current activity and response cadence remain unverified. No performance numbers were verified; raster composition and committed mirroring have different costs from live 64-way replication.

## Harley-xk/MaLiang

The [README](https://github.com/Harley-xk/MaLiang) and [license](https://raw.githubusercontent.com/Harley-xk/MaLiang/master/LICENSE) identify MIT terms. Its Metal-backed canvas, textured brushes, Bézier lines, persistence, and history are directly relevant to native iPad drawing. Documented installation uses CocoaPods or Carthage rather than a verified SwiftPM route; that is not a drop-in iPad Playground dependency.

The [Canvas source](https://github.com/Harley-xk/MaLiang/blob/master/MaLiang/Classes/Canvas/Canvas.swift) exposes separable render operations and brush callbacks. Those boundaries are useful design references. Its visible touch overrides pick an available touch and forward it to the current brush; the reviewed portion does not establish a coalesced/predicted input pipeline. Adapting input, shader resources, packaging, and real-time symmetry would still be necessary. Force-unwrapped current-brush assumptions also merit checking before reuse.

Maintenance: the README's iOS 9/Swift 5 baseline is an older compatibility target, not proof of abandonment. The commit feed was unavailable during review, so current maintenance is unverified. Metal offers a useful performance foundation, but 64-way symmetry would require new benchmarks. Prefer the small native renderer here rather than importing and repackaging the whole library.

## mathnotes-app/mobile-ink

The [repository](https://github.com/mathnotes-app/mobile-ink) declares Apache-2.0; its [license file](https://raw.githubusercontent.com/mathnotes-app/mobile-ink/main/LICENSE) contains those terms. The [package manifest](https://raw.githubusercontent.com/mathnotes-app/mobile-ink/main/package.json) and README identify a React Native/native Skia stack. Apache licensing is generally usable in a commercial app subject to its requirements, but dependency licensing needs separate review.

The [native canvas source](https://github.com/mathnotes-app/mobile-ink/blob/main/ios/MobileInkModule/MobileInkCanvasView.swift) separates real and predicted input and normalizes pressure/tilt. These are useful patterns; the substantial view and bridge surface also creates integration complexity. The README describes Metal rendering and pooled notebook engines, with native CocoaPods/build requirements. Adopting it would add React Native/C++/Skia tooling outside this iPad-only Swift playground scope.

The [visible commit history](https://github.com/mathnotes-app/mobile-ink/commits/main/) includes renderer fixes and release work through August 2026 in the retrieved snapshot. This indicates recent work, not guaranteed support or a verified latest release. Published production-use claims and benchmark infrastructure are encouraging but do not establish this app's latency or mandala throughput. Reject as a Phase 1 dependency; retain the conceptual separation of predicted ink, real ink, and viewport state.

## Compatibility summary

| Candidate | Declared license | Native iPad foundation | Verified iPad Playground install | Phase 1 choice |
| --- | --- | --- | --- | --- |
| sketchbookapp | MIT in README; full license file fetch unavailable | SwiftUI/PencilKit | No; documented XcodeGen workflow | Architectural reference |
| MaLiang | MIT | Swift/Metal | No; documented Pods/Carthage workflow | Rendering reference |
| mobile-ink | Apache-2.0 | Native engine through React Native/Skia | No | Input/rendering reference only |

For the MIT candidates, preserve copyright/license notices if code is later reused. For Apache-2.0 code, review license/notice retention and modification notices as applicable. This app currently incorporates none of their code or binary assets, so no runtime attribution dependency is introduced by the evaluation.
