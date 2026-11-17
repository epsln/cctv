# Milestone 1: rendering substrate (implementation)

[Documentation index](../README.md#documentation)

Status: **implemented prototype (v0.1.0)**. Acceptance against the 1080p60
target is still **pending**: it has to be measured on the performance machine
(see [benchmark](benchmark.md)).

## Runtime structure

```text
PerformanceRoot                       runtime/performance_root.gd
 ├─ MusicalClock                      runtime/musical_clock.gd
 ├─ AssetManager -> VisualSources     sources/
 ├─ TransitionCompositor (A/B slots)  runtime/transition_compositor.gd
 │   └─ Composition (SubViewport)     runtime/composition.gd
 │       ├─ Layer (+ EffectChain)     runtime/layer.gd, effect_chain.gd, effect.gd
 │       ├─ LayerGroup                runtime/layer_group.gd
 │       └─ AnnotationLayer           runtime/annotation_layer.gd
 ├─ FeedbackPass (ping-pong)          runtime/feedback_pass.gd
 ├─ Global EffectChain
 ├─ Recorder                          runtime/recorder.gd
 ├─ Projector window / operator view  runtime/operator_view.gd
 └─ FrameMetrics                      runtime/frame_metrics.gd
```

A "show" JSON file (`shows/*.json`) declares the asset manifest, output size,
fps, BPM, feedback, global effects and named composition specs.

## Roadmap items

| Item | Implementation |
| --- | --- |
| Multiple simultaneous videos | `TheoraVideoSource` behind the `VisualSource` interface. Clock-slaved playheads with drift correction, loop, seek, and shared or independent instances. |
| Image, PDF page and text overlays | `ImageSource`, `PdfPageSource` (pre-rasterized, or rasterized asynchronously with pdftoppm), `TextSource` (caption or ticker). Face-track, box, highlight and redaction annotations. |
| Local and global effects | `Effect`/`EffectChain` on layers, groups and the output. Musical uniforms `uBeatPhase`, `uBeatEnvelope`, `uBassEnergy`, `uOnsetEnvelope`, `uBarPhase`, and `param = base + amount × signal` bindings. |
| Explicit temporal feedback | `FeedbackPass` with two alternating render targets. A clock seek resets its history. |
| Composition transitions | Cut, crossfade, wipe and glitch cut. Progress comes from the clock, and transitions can start on the next beat. |
| Projector and operator views | A separate projector window (fullscreen on a chosen screen) and an operator view with a preview, triggers and status |
| Output capture | `Recorder` writes timestamped PNGs and a `frames.jsonl` index, with PNG encoding on a worker thread. Movie Maker handles deterministic offline renders. |
| Measurement | `Benchmark` scene and `tools/bench.sh` |

## Design decisions

- **Clock**: animation, playheads, transitions and feedback all read time from `MusicalClock`. Live mode follows the monotonic clock. Replay mode advances exactly `1/fps` per frame. Phase convention: `beat_phase` is 0 at the onset and rises to 1. `bar_phase` is -1 unless bar alignment is set. BPM is a fixed placeholder until Milestone 2.
- **No silent no-ops**: unknown effect types or parameters, bindings, blends, assets, IDs, annotation targets and transition kinds are all rejected with an error. This addresses the registry and ID mismatches in the [assessment](02-current-implementation-assessment.md#renderer-and-action-integration-gaps).
- **Transactional preparation**: `PerformanceRoot.trigger()` fully builds and validates the incoming composition before it touches the active one. If the build fails, the composition is discarded and the current one keeps playing.
- **Offscreen allocation**: a `SubViewport` is only created for compositions, groups that have effects, effect passes, feedback and transitions. Plain layers are drawn as ordinary 2D items.
- **Feedback binding**: the pass being written always samples the *other* target, never itself. The old renderer's unbound previous-frame texture problem cannot occur.
- **Observability**: `PerformanceRoot.status()` reports the clock, the transition, each source's state and playhead, capture stats, frame metrics and errors.

## Tests and CI

`tools/test.sh` runs 70 unit and integration tests. They run headless with the dummy renderer, and under Xvfb with OpenGL (Mesa llvmpipe), where they also read back pixels: effect output, layout, group effects, feedback decay and reset, crossfade/wipe and recorded frames.

A test fails on any GDScript runtime or compile error, not only on assertions. GitHub Actions runs gdlint/gdformat, shellcheck, both test modes, a benchmark smoke run and a Movie Maker smoke run.

The test runner is a small built-in one (`tests/run_tests.gd`) instead of gdUnit4, which avoids a third-party addon pinned to a particular Godot version.

## Known limitations

- Theora decoding and texture upload run on the main thread. Decode cost is the main risk to the 1080p60 target.
- Building a composition is synchronous, so its cost (`prepare_ms`) lands on the frame where the switch is triggered.
- Recorder readback is synchronous in the Compatibility renderer.
- Viewport render order is not explicitly constrained, so the output may lag the compositions by one frame in the worst case.
- Masks are rectangular only (crop and group clip). Shaped masks are not implemented.
- Musical features are synthesized from a fixed BPM. Real analysis is Milestone 2.
