# Changelog

## Unreleased — Milestone 2 musical runtime

- `analysis/`: Python 3.12 / uv package `cctv-analysis` with the `cctv-analyse` CLI.
  It provides file (real-time, played, or externally clocked) and live PortAudio/PipeWire
  PCM sources, causal band/onset/energy/novelty features, an aubio + PLL
  beat tracker, a downbeat estimator, and versioned `MusicalState` over UDP and JSONL.
  Tooling: ruff, mypy (strict), pytest.
- `MusicalClock`: integrated beat position (no phase jump on tempo change),
  follows external state with smoothing and slew, falls back to internal timing
  when state is stale or not confident, separates beat and bar confidence, adds
  manual bar alignment and nudge, and adds latency compensation.
- `MusicalStateReceiver` (UDP, clock-offset estimation, freshness stats).
- `Scheduler`: beat-position events with IDs, outcomes and lateness.
  `trigger()` supports `now`, `next_beat`, `next_bar` (rejected without bar
  alignment) and `grid:N`.
- New uniforms `uMidEnergy`, `uHighEnergy`, `uEnergyTrend`, `uBeatConfidence`.
- Operator view: quantisation selector, bar alignment (B / Shift+B), nudge
  ([ / ]), and timing/analysis/scheduler status.
- `tools/timing_probe.sh`: end-to-end analyser → Godot timing measurement.
- `cctv-evaluate`: offline beat/bar evaluation against madmom references or hand
  annotations, with mir_eval metrics and click-track rendering for listening
  checks. Results are in `docs/beat-evaluation.md`.
- Comb-filter beat tracker (now the default; aubio + PLL is still available with
  `--tracker aubio`). F-measure 0.65 → 0.80, re-locks 11 → 2.6 per 4 min.
- Downbeat estimation uses beat-synchronous spectral novelty. Automatic bar
  alignment from estimates is off by default (`auto_bar_alignment`).
- `tools/run.sh` (analyser + Godot launcher) and `tools/route_mixxx.sh` (PipeWire links).
- Evaluation on a recorded 145 min DJ set: beat F 0.88, tempo correct 94 % of the time.
- Milestone 1 acceptance run recorded (RTX 4070 Ti, 1080p60, 300 s: pass).

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
