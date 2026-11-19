# Musical state protocol

[Documentation index](../README.md#documentation)

The analyser (`analysis/`, `cctv-analyse`) publishes one `MusicalState` per
analysed block (512 samples, about 94 messages/s at 48 kHz). Godot's
`MusicalStateReceiver` applies the newest one each frame to `MusicalClock`.

## Transport

- UDP datagrams, one JSON object each, to `127.0.0.1:9870` by default
  (`--udp HOST:PORT`, Godot `--state-port=N`).
- Fire-and-forget. The analyser never blocks on the receiver, and the receiver
  only applies the newest message per frame. A lost datagram is replaced by the
  next one about 10 ms later.
- `--record FILE.jsonl` writes the same messages (plus a header line) for
  replay and evaluation.

## Clocks

`t_audio` and `t_sent` are `time.monotonic()` seconds in `realtime` mode, or
stream time (`sample_index / sample_rate`) in `external` mode (file analysis as
fast as possible). The receiver estimates the offset to Godot's monotonic clock
as the minimum of `receive_time - t_sent` over a 10 s window. On localhost the
minimum one-way delay is effectively zero, so this recovers the offset.

`t_audio` is the time the analysed audio was audible at the capture point
(end of the latest block). For live input, PortAudio's ADC timestamps are used,
so device latency is included. All musical values describe that instant. The
clock extrapolates them to the current frame using `bpm`.

## Fields (schema `v: 1`)

| Field | Type | Meaning |
| --- | --- | --- |
| `v`, `features` | int, str | Schema version (receivers reject others) and feature-code version |
| `seq` | int | Increasing per analyser run. A large drop means the analyser restarted |
| `t_audio`, `t_sent` | s | See above |
| `sample_index`, `sample_rate` | int | Stream position after the block |
| `clock` | str | `realtime` or `external` |
| `timing_source` | str | `audio` when the beat tracker is locked, otherwise `none`. `mixxx` is reserved for the telemetry adapter |
| `bpm` | float | Tracked tempo, folded into `--bpm-range` (default 70–180) |
| `beat_position` | float or null | Continuous beat count at `t_audio`, using the analyser's own numbering. Null when not locked |
| `beat_confidence` | 0..1 | Agreement of recent detections with the loop. Decays without detections |
| `discontinuity` | bool | Tempo/phase re-acquired (new track, seek): the receiver may jump instead of slewing |
| `beats_per_bar`, `downbeat` | int | Beat index (mod `beats_per_bar`, analyser numbering) that starts a bar, or -1 |
| `bar_confidence`, `bar_source` | 0..1, str | Separate from beat confidence. `none`, `estimate` or `manual` |
| `bass`, `mid`, `high`, `level` | 0..1 | Band energies relative to their recent (~8 s) range, with attack/release envelopes |
| `onset`, `onset_envelope`, `onset_strength` | bool, 0..1, 0..1 | Spectral-flux onsets (rising edge, no look-ahead) |
| `transient_density` | 1/s | Onsets per second, smoothed over ~2 s |
| `spectral_change` | 0..1 | Frame-to-frame spectral distance |
| `silent` | bool | Nothing above -60 dBFS for 0.5 s |
| `energy_short`, `energy_long`, `energy_trend` | 0..1, 0..1, -1..1 | 2 s and 30 s level, and their difference. Published at 2 Hz (slow features) |
| `novelty` | 0..1 | Spectral distance between the last ~2 s and ~16 s (section-change evidence). 2 Hz |
| `overruns` | int | Blocks dropped by the live input queue |
| `analysis_ms` | ms | Processing time of the block |

All features are causal: they depend only on audio already heard, so recorded
and live input produce the same values at the same moments
(`tests/test_io.py::test_realtime_matches_external_clock`).

## Receiver behaviour and fallback

| Condition | Clock behaviour |
| --- | --- |
| First confident state | Adopt the tempo. Jump the phase if it is more than 0.25 beat off, otherwise slew |
| Following | Tempo smoothed (τ 0.5 s). Phase error slewed (τ 0.3 s), rate limited to 0.5–2× nominal so the phase never runs backwards |
| `discontinuity` | Jump the phase when it is more than 0.25 beat off |
| `beat_confidence < 0.3` or `beat_position` null | Ignored for timing (features still used) |
| No timing for 0.5 s (analyser stopped, silence, breakdown) | `timing_source` becomes `internal`: free-runs at the last tempo and phase, and `beat_confidence` decays (τ 2 s) |
| Features older than 0.25 s | Fade over 0.25 s back to clock-synthesised envelopes |
| Bar estimate | Always reported as `bar_estimate` (local numbering). Bars are aligned from it only if `auto_bar_alignment` is on (default **off**, see [beat evaluation](beat-evaluation.md)) and `bar_confidence ≥ 0.5` |
| Operator `B` | Manual bar alignment, which overrides estimates until cleared (`Shift+B`) |

All thresholds are `MusicalClock` exports and can be set per show:
`"timing": {"latency_compensation": 0.03, "min_confidence": 0.4, ...}`.
