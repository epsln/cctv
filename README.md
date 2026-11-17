# CCTV: AI-directed audiovisual performance

An autonomous VJ instrument: an AI artistic director over a beat-aware audiovisual
instrument. The agent chooses composition and pacing; the runtime executes precise
musical events and continuous modulation.

This repository contains the **Milestone 1 rendering substrate**: a Godot 4.5
(GDScript) prototype with a replaceable video backend. The previous C++/OpenGL
implementation lives in a separate repository (`cctvcpp`).

## Quick start

Requirements: Godot 4.5 stable, `ffmpeg`, `pdftoppm` (poppler-utils).

```sh
tools/make_sample_assets.sh          # synthetic test videos/images/PDF pages
godot --path .                       # projector + operator windows
godot --headless --path . -s res://tests/run_tests.gd   # tests
tools/bench.sh 60                    # 60 s benchmark -> bench/results/*.json
```

See [docs/benchmark.md](docs/benchmark.md) for acceptance measurements and
[docs/milestone-1.md](docs/milestone-1.md) for the implementation overview.

## Layout

| Path | Contents |
| --- | --- |
| `runtime/` | Clock, compositions, layers, effects, feedback, transitions, recorder, metrics |
| `sources/` | `VisualSource` interface and video/image/PDF/text implementations |
| `effects/shaders/` | Godot shaders (ported from the old GLSL effects) |
| `scenes/` | Performance root, operator view, benchmark |
| `tools/` | Asset transcoding, PDF rasterization, sample generation, benchmark launcher |
| `tests/` | Headless test runner and unit/integration tests |

## Documentation

| Document | Contents |
| --- | --- |
| [Project direction](docs/01-project-direction.md) | Scope, design principles, aesthetic, and future extensions |
| [Current implementation assessment](docs/02-current-implementation-assessment.md) | Previous agent strategy, correctness issues, and gaps |
| [Visualization architecture](docs/03-visualization-architecture.md) | Godot evaluation, sources, layers, effects, rendering, and runtime |
| [Agent–engine protocol](docs/04-agent-engine-protocol.md) | Semantic actions, scheduling, transactions, acknowledgments, and replay |
| [Mixxx and audio integration](docs/05-mixxx-and-audio.md) | Linux audio capture, optional telemetry, musical clock, and recorded inputs |
| [Media library and visual language](docs/06-media-library-and-style.md) | Asset preprocessing, face boxes, composition families, and style controls |
| [Learning strategy and objectives](docs/07-learning-strategy.md) | Recorded-set training, imitation, scene-level PPO, rewards, and evaluation |
| [Quality annotation workflow](docs/08-quality-annotation.md) | A/B review, long-sequence feedback, data records, and preference learning |
| [Development roadmap](docs/09-development-roadmap.md) | Ordered implementation milestones and acceptance criteria |

## Branching

Git-flow: `main` holds releases, `develop` integrates `feature/*` branches,
`release/*` branches stabilise before merging to `main` with a version tag.
