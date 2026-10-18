# Ornamentalist studio interface

The visual direction is a quiet drawing studio: warm ivory, copper accents, serif titles and a charcoal canvas surround. The rosette brand mark is a native vector shape. Real gallery cards use saved PNG thumbnails; the decorative empty-state ornament never impersonates a saved drawing.

## Gallery

- Adaptive thumbnail grid, search by title and sorting by modification date or name.
- New drawing sheet with a name field and the actual 2048 × 2048 / eight-copy defaults.
- Import from Files; renaming through a card's ellipsis or context menu.
- Busy state prevents duplicate open/create/import operations.

## Drawing workspace

- Floating header contains Gallery, title, save state, Undo/Redo, export and focus.
- Floating dock exposes Fineliner, Symmetry and Canvas popovers. These overlay the same mounted Metal canvas; opening a panel does not change the drawing's view bounds.
- Fineliner shows a width preview, width presets, pressure sensitivity and stabilization.
- Symmetry shows a radial preview, quick presets, exact 1–64 copies and guides. Settings affect future strokes.
- Canvas contains navigation help, fit-to-screen, finger mode, appearance and the existing diagnostic report.
- Focus hides chrome and retains one accessible restore button.
- Active drawing, mesh preparation and export disable incompatible commands. The existing close/save lock and recovery alerts remain in use.

Controls use native SwiftUI semantics, named icon actions, scalable system text for controls and 44-point or larger primary tap targets. Large panels scroll. Paper remains white in both appearances.

## Validation

The Xcode scheme includes UI tests for named creation, opening, changing symmetry, Undo/Redo, focus, panel navigation, appearance and search. Tests capture gallery, editor and panel screenshots, including portrait and dark appearance.

The debug-only showcase launch argument creates original procedural artwork in a new temporary repository. It does not seed the user's library. CI exports test attachments in the `studio-ui-screenshots` artifact; screenshots show the actual SwiftUI/Metal app.

Run `python tools/github_ci.py screenshots --run RUN_ID` to download them into ignored `dist/ui-preview/RUN_ID`. Physical iPad/Pencil feel, VoiceOver traversal and accessibility text sizes still need device acceptance.
