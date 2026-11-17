# Changelog

## 0.1.0 — Milestone 1 rendering substrate

- Godot 4.5 GDScript project with replaceable `VisualSource` backends
  (Theora video, image, PDF page, text) and an asset manifest.
- `MusicalClock` with live and replay modes and a documented phase convention.
- Layers, groups, annotation layers and serializable compositions.
- Effect shaders ported from the previous renderer (chromatic, glitch,
  kaleidoscope, edge detection with corrected texel offsets, bloom) and new
  ones (color grade, feedback, transitions), with musical modulation bindings.
- Ping-pong temporal feedback that resets on seek.
- Transition compositor with two composition slots and beat-quantized
  transitions.
- Projector window, operator view, frame metrics.
- Timestamped asynchronous capture and Movie Maker offline rendering.
- Benchmark workload, metrics and acceptance procedure.
- Asset tools (transcode, rasterize PDF, sample library).
- Headless and OpenGL test suites, GitHub Actions CI.
