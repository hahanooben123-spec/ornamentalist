# Ornamentalist: independent code review

This is a native iPad drawing app built from Windows. Communicate with the owner in Danish. Your default role is an independent reviewer: report concrete findings and suggested fixes. Do not modify files, commit, push, install dependencies or change the owner's iPad data during a review.

## Project boundaries

- `Ornamentalist.swiftpm/Package.swift` is the actual iPad app manifest, with AppleProductTypes and one executable target containing 29 Swift sources.
- The repository-root `Package.swift` is a portable model-test library for cloud macOS. It is not the iPad app and must not replace its manifest.
- `Diagnostics/Ornamentalist-Starttest.swiftpm` is a minimal startup diagnostic, not the full drawing app.
- The app uses SwiftUI, UIKit Pencil input, Metal and Core Graphics; it is not a website. Keep erasing, symmetry, color, layers, persistence and export consistent.

## Evidence and verification

- Windows has no local Swift compiler or Apple SDK in this workspace. `python tools/check_sources.py` checks grammar only. `python tools/package_ipad.py` checks source inventory and ZIP bytes, not compilation.
- GitHub Actions runs portable Swift tests, SwiftPM source discovery, Xcode app compilation, native pixel/model tests and simulator UI tests. See `.github/workflows/apple-validation.yml` and `docs/BUILD_STATUS.md`.
- `tools/check_playground_target.py` substitutes the AppleProductTypes product for source discovery. The cloud Xcode target does not evaluate the actual app playground manifest in the installed iPad editor.
- A green simulator run is not proof of physical iPad Swift Playground compatibility, Pencil behavior or File Provider synchronization.
- A Git pull updates the Working Copy checkout, not a separate imported Playground copy. Local changes may survive a pull or conflict with upstream changes.

## Current device investigation

The owner previously saw missing types including DrawingLayer, InkColor, BrushVertex, BrushGeometry and StudioLayersView. They confirmed LayerManager.swift exists on iPad. Photos showed duplicate displayVersion/bundleVersion/appIcon arguments, two executableTarget declarations, and later a target closed before sources. The repository manifest is canonical; do not assume why the iPad copy acquired duplicates. The owner has since confirmed the app builds/runs on an iPad Pro, but drawing and erasing were very slow.

The current task is version 0.7.0 performance optimization: persistent bounded viewport caches, incremental confirmed live geometry, transient predictions and reusable/memoryless work targets. Read `docs/HASTIGHED.md`, `docs/ARCHITECTURE.md` and `Tests/iOS/RendererCacheTests.swift`. Verify cache ownership, cancel/commit promotion, chunk offsets, memory fallback and pixel parity. Simulator benchmark ratios are not physical iPad FPS or Pencil latency. Manifest source membership/delivery still matter when an old app copy is opened. Never recommend deleting app data as a routine repair.

## Review output

For each finding, give severity, a source path and line, a concrete failure scenario and the smallest supported fix. Distinguish confirmed source defects from device-only hypotheses. If a diagnosis needs the installed app manifest or a new device error, say exactly what evidence is missing. Do not invent execution results or claim tests ran when you only inspected code.
