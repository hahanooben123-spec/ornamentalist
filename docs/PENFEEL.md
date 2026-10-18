# Pen response — 0.9.8

Brush settings now include adaptive stabilization, pressure curve and minimum size.
Solid ink supports start/end taper. Stamped brushes support Pencil tilt shading.
All settings are remembered per preset automatically. Saved settings and existing
strokes retain their old response unless adjusted. New Brush pen defaults use
taper; all stamped brush defaults enable tilt shading at 70%. Existing personal
settings with tilt off are migrated once. A later choice to turn tilt off is
remembered normally. Existing strokes are never migrated or redrawn differently.

Open the Brushes panel and scroll below Pressure sensitivity. A low pressure
curve value gives more width under a light touch; a high value needs more force.
Minimum size zero allows a very fine pressure-controlled line. Disable pressure
and taper for a uniform fineliner. Adaptive stabilization shortens the filter's
response time at speed; zero Steady line bypasses filtering. Version 0.9.1
smooths the velocity vector so tremor cannot trigger a sudden reduction in
smoothing, normalizes speed to screen points across zoom levels, and uses two
position filters with delay compensation to retain deliberate curve radii.
Predicted ink is limited to the next 16.7 ms when stabilization is enabled.

Taper lengths are measured relative to brush width. The ending is applied on
Pencil lift, rebuilding this stroke once; ordinary drawing remains incremental.
Very short two-sample strokes keep a full start so the entire mark cannot vanish.
Stationary taps retain the brush diameter rather than becoming invisible.

Tilt changes the orientation and shape of a stamp's footprint; it does not add
more vertices or symmetry copies. A tilted footprint has at most 1.8 times the
upright major radius. Finger input uses an upright footprint. Metal, PNG export
and thumbnails share the same geometry. Predictions use temporary filter state
and never alter stored ink. This is geometric shading, not a simulated paper or
wet-paint model.

Steady line now supports 0–100%. Version 0.9.2 uses a third smoothing stage to
compensate curve-radius error at high stabilization, with light pressure filtering
to reduce abrupt width changes. This still follows freehand input; it does not
snap a stroke to a mathematically perfect circle or recreate Procreate's engine.

Stamped geometry now stores four Float2 corners (32 bytes) per dab, instead of
six Float4 triangle vertices (96 bytes). Metal derives the repeated corners and
local shape coordinates. Coordinates, density, opacity, randomness and stroke
files are unchanged. Budget accounting uses actual storage units, allowing up
to three times as many stamped dabs at the previous 32 MB source-buffer budget.
The per-stroke storage budget stays bounded too. Reopening expands only one
stroke at a time rather than materializing the whole document's expanded mesh.
Input-sample, file-size, raster and render-target limits still exist. More dabs
can still increase GPU fill cost, export time and total memory; this change does
not promise unlimited drawing or a measured device speedup.

Version 0.9.3 adds an explicit Stabilization on/off switch. Off bypasses input
smoothing, while the remembered strength remains available when enabled again.
The former Adaptive stabilization toggle only selected the speed adaptation;
it did not disable the stabilizer. That control is now labeled Adapt to drawing
speed. Higher strength now uses a longer smoothing interval, with partial delay
compensation instead of triple compensation. This deliberately retains a visible
tradeoff: smoother strokes follow the Pencil more slowly at high settings.
Regression replay covers 4 Hz and 9 Hz hand wobble at 60/120/240 input samples
per second, both speed modes, exact bypass, and clear strength differentiation.

Version 0.9.4 lengthens high-strength stabilization for more pronounced smoothing.
Soft shader and Airbrush normalize per-dab opacity against stamp spacing for new
strokes. Opacity is still accumulated across repeated passes; it is not a strict
whole-stroke cap. Existing strokes decode with their original per-dab behavior.
Saved current brush preferences migrate to the new behavior. Opacity sliders use
a square response for finer low-end adjustment, display tenths of a percent, and
allow 0%. All eraser brush presets are available, with independent remembered
size, opacity, pressure, stabilization, taper, tilt, density and spacing settings.

Version 0.9.7 adds Edge softness (0–100%) and Stroke falloff (0–100%) for
stamped brushes, including shading, dots and eraser brushes. Softness controls
the feathered part of each dab. Falloff starts at full strength and fades with
stroke distance; higher settings finish sooner. At zero it is disabled. Lifting
Pencil resets the fade. Geometry stops emitting after the fade length, so an
invisible tail does not keep filling the geometry budget. Mirror duplicates the
same faded geometry. Settings persist per brush. Existing strokes retain their
previous softness and have no distance fade.

Faded compact dabs still use 32 bytes: three parallelogram corners and an opacity
value; Metal reconstructs the fourth corner. Non-faded dabs retain four corners.
Reconstruction may differ by floating-point rounding from expanded corners.
Core tests cover input batching, distance-based opacity, validation and reopening;
native tests compare expanded/compact live and committed drawing plus PNG for
both ink and erasing. These checks require Apple CI, not Windows grammar checks.

Version 0.9.8 coalesces GPU-busy redraw requests until a GPU completion callback,
instead of immediately scheduling another draw from the busy guard. This removes
the tight retry loop associated with extreme Deferred frames counts. Device
performance still needs measurement. The input budget is now 400,000 points
(80,000 per stroke), source geometry 64 MB (8 MB per stroke), and drawing file
size 128 MB. Render-target and raster budgets are unchanged. Reopening still
expands one stroke at a time. These are bounded capacities, not unlimited drawing.
The diagnostic report now shows input-point and geometry-budget usage, and their
limit errors are distinct. Tests cover a 120,000-point mirrored drawing and
shading beyond the former 32 MB geometry budget.

New strokes use 2.5× pressure sensitivity by default. Full size is reached at 40%
of UIKit's reported maximum force, rather than requiring 100%. Pencil sensitivity
is adjustable from 1× to 5× and remembered per drawing/eraser preset. Personal
current settings migrate once; existing strokes decode with the old 1× response.

Document format 14 stores pressure sensitivity and the expanded capacity. Older formats
remain readable; older app builds cannot read drawings saved by this version.

Local checks: Swift grammar, build YAML and byte-for-byte source packaging.
Portable tests cover pressure response, taper persistence and budget, adaptive
prediction isolation, and tilt geometry. Native tests cover preference persistence.
Tests require Apple CI; physical Pencil latency and lift cost require iPad testing.
