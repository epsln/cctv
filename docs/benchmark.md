# Benchmark and acceptance procedure

[Documentation index](../README.md#documentation)

Milestone 1 acceptance needs the agreed workload to hold the target output on
the **performance machine**. Results from CI or software rendering (llvmpipe)
only show that the benchmark runs. They are not acceptance evidence.

## Target

| Item | Value |
| --- | --- |
| Output | 1920x1080 at 60 fps, vsync on |
| Workload | `shows/bench.json`: 4 simultaneous videos (3x 360p and 1x 720p Theora), a PDF page with redaction and highlight annotations, a face-track box, a caption and a scrolling ticker, local effects on every video, a group glitch pass, global feedback + chromatic + bloom, and a beat-quantized transition every 8 beats that cycles through crossfade, wipe, glitch cut and cut |
| Pass | mean fps ≥ 98 % of target, late frames ≤ 1 %, p99 frame time ≤ 1.5 frame periods, no switch failures, no runtime errors, and RSS growth ≈ 0 MB/h in long runs |

## Running

```sh
tools/make_sample_assets.sh -d 60     # or point a show at the real library
GODOT=/path/to/godot tools/bench.sh 300                        # 5 min
GODOT=/path/to/godot tools/bench.sh 7200 --sample=60           # long session
GODOT=/path/to/godot tools/bench.sh 120 --vsync=off            # headroom
```

Options: `--switch-beats=N`, `--seek-every=S`, `--show=PATH`, `--out=PATH`,
`--seed=N`. The benchmark exits with status 1 if the runtime reported errors.

Run with the real projector output connected, with the compositor/desktop
configuration you will use for the performance.

## Recorded measurements (`bench/results/*.json`)

| Field | Meaning |
| --- | --- |
| `frames` | frame count, late frames (interval > 1.5x the period), mean/recent fps, p50/p95/p99/max frame time |
| `acceptance` | each pass criterion, plus an overall `pass` |
| `switches` | each composition switch: target, transition kind, and `prepare_ms` (synchronous build cost on the render thread) |
| `seeks` | random video seeks: synchronous seek cost in ms |
| `timeline[*].seek_count_total` | all decoder seeks, including drift corrections. Steady growth without benchmark seeks means a decoder is falling behind the clock |
| `timeline[*].process_ms` | main-thread process time. Theora decoding and texture upload happen here |
| `upload_ms` | micro-benchmark of `ImageTexture.update` at 360p, 720p and 1080p |
| `cpu_percent` | whole-process CPU time (100 = one core) |
| `timeline[*].rss_mb`, `video_mem_mb`, `texture_mem_mb`, `objects` | memory and object counts sampled during the session |
| `rss_growth_mb_per_hour` | linear fit of RSS after warm-up |
| `renderer`, `driver`, `cpu_name` | the environment |

## Results

Copy this template into the table below for each acceptance run:

| Date | Machine / GPU | Driver | Duration | Mean fps | Late % | p99 ms | Max prepare ms | Max seek ms | CPU % | RSS MB (end) | RSS MB/h | Pass |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | | | | | |

Reference smoke run (software rendering, **not acceptance**). llvmpipe,
16 threads, 15 s: about 22 fps, 7/7 switches succeeded, max prepare 23 ms,
max seek 34 ms, constant object count across switches.

## Known risks to check on the target machine

- **Theora decode cost** runs on the main thread. If `process_ms` uses most of
  the frame budget, reduce video resolution or bitrate in `tools/transcode.sh`,
  or swap the backend (e.g. an FFmpeg GDExtension) behind `VisualSource`.
- **Composition preparation** is synchronous. If `max_prepare_ms` causes late
  frames on switches, move preparation off the render path. Pre-building the
  next composition one beat early is the easiest change.
- **Capture readback** (`Recorder`) is synchronous in the Compatibility
  renderer. Use `--capture-every` or `--capture-scale` during live sessions,
  and Movie Maker (`tools/render_movie.sh`) for offline renders.
