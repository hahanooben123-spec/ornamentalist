# Pen response — 0.9.0

Brush settings now include adaptive stabilization, pressure curve and minimum size.
Solid ink supports start/end taper. Stamped brushes support Pencil tilt shading.
All settings are remembered per preset automatically. Saved settings and existing
strokes retain their old response unless adjusted. New Brush pen defaults use
taper; new Graphite, Charcoal and Soft shader defaults enable tilt shading.

Open the Brushes panel and scroll below Pressure sensitivity. A low pressure
curve value gives more width under a light touch; a high value needs more force.
Minimum size zero allows a very fine pressure-controlled line. Disable pressure
and taper for a uniform fineliner. Adaptive stabilization shortens the filter's
response time at speed and on turns; zero Steady line bypasses filtering.

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

Document format 9 stores the additional settings and taper samples. Older formats
remain readable; older app builds cannot read drawings saved by this version.

Local checks: Swift grammar, build YAML and byte-for-byte source packaging.
Portable tests cover pressure response, taper persistence and budget, adaptive
prediction isolation, and tilt geometry. Native tests cover preference persistence.
Tests require Apple CI; physical Pencil latency and lift cost require iPad testing.
