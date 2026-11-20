# Milestone 2: musical runtime (implementation)

[Documentation index](../README.md#documentation)

Status: **closed (core complete)**. The analyser, transport, clock following,
scheduler, operator timing controls, launcher and the
[beat/bar evaluation](beat-evaluation.md) are implemented and tested. Recorded
input meets the acceptance criteria: beat F 0.88 on a 145 min DJ set, measured
event timing, and a defined fallback when timing is lost. Live Mixxx input
still needs a one-time check on the performance machine. The remaining items
are deferred (see [Deferred work](#deferred-work)).

## Running

```sh
tools/run.sh file set.wav            # play a recorded set; analyser + Godot
tools/run.sh live                    # live input, then in another shell:
tools/route_mixxx.sh                 # link Mixxx main output -> analyser (pw-link)
CCTV_GODOT_ARGS="--projector-screen=1" tools/run.sh live   # with projector
```

Godot runs with its operator window. Press `B` on a "one" to align bars.

## Structure

```text
analysis/ (Python 3.12, uv)                         Godot
  FilePcmSource / LivePcmSource  (pcm.py)
        │ PcmBlock: mono, sample_index, t_mono
  FastAnalyser   bands, envelopes, onsets  (features.py)
  SlowAnalyser   energy trend, novelty     (features.py)
  CombBeatTracker  comb filter + PhaseFollower (comb.py, default)
  BeatTracker      aubio "energy" + BeatPll     (beat.py, --tracker aubio)
  DownbeatEstimator                        (beat.py)
        │ MusicalState (state.py)
  UdpPublisher / JsonlRecorder (transport.py) ──UDP──> MusicalStateReceiver
                                                         │ apply_state()
                                                       MusicalClock (follow / fallback)
                                                         │ beat_position
                                                       Scheduler ──> PerformanceRoot.trigger()
                                                         │ uniforms
                                                       effects / layers
```

The message format and fallback rules are specified in
[musical-state.md](musical-state.md).

## Roadmap items

| Item | Status | Implementation |
| --- | --- | --- |
| Common live/file PCM input | done | `PcmSource` protocol. Files are read with libsndfile, either real-time paced (optionally played) or externally clocked. Live input uses PortAudio with a bounded queue that drops and counts overruns, never blocking capture. Timestamps come from ADC time |
| Mixxx main-output routing | partial | `cctv-analyse live --device pipewire` captures from the PipeWire ALSA device. A routing script (Mixxx main → analyser node) and verification on the performance machine are pending |
| Separate fast DSP and slow analysis | done | Fast: per 512-sample block (10.7 ms). Slow: updated per block, published at 2 Hz. Tempo/phase: comb estimate every 0.25 s. About 0.1 ms per block on average |
| Timestamped state with confidence and freshness | done | `MusicalState` v1. Beat and bar confidence are separate. Freshness is measured by the receiver (`age_ms`, `transport_ms`) and the clock (`timing_age`) |
| Beat-aware scheduler and continuous modulation | done | `Scheduler` targets beat positions, so events stay on the beat through tempo changes and slews. Every event has an explicit outcome and lateness. New uniforms: `uMidEnergy`, `uHighEnergy`, `uEnergyTrend`, `uBeatConfidence` |
| Explicit bar alignment | done | Operator alignment (`B`) and nudge (`[`/`]`). A downbeat estimator (beat-synchronous spectral novelty) is reported as a hint. Automatic alignment from it is off by default because its precision is 0.39 ([evaluation](beat-evaluation.md)). Bar quantisation without alignment is **rejected**, not approximated |
| Optional Mixxx telemetry | pending | Controller-script adapter (see below) |

## Design decisions

- **Separate process.** Analysis runs in Python, so the same code serves live
  use, offline feature extraction and training. A slow or crashed analyser
  cannot stall rendering. Godot falls back to its internal clock.
- **Comb-filter tracker by default.** It re-estimates tempo and phase from 8 s of
  20 Hz–2 kHz onset strength every 0.25 s, with hysteresis on phase switches.
  On the evaluation corpus it beats aubio + PLL on every accuracy metric
  (F 0.80 vs 0.65, re-locks 2.6 vs 11 per 4 min). First lock is slower (about 4 s
  vs 2.6 s), because the comb needs 4 s of history. See
  [beat-evaluation.md](beat-evaluation.md). The aubio notes below apply to
  `--tracker aubio`.
- **aubio `energy` onset method for tempo.** On synthetic material with offbeat
  hats, aubio's default (HFC) and spectral-flux methods lock onto the offbeat
  (about +200 ms error). `energy` follows the kick (`tests/test_beat.py::test_not_fooled_by_offbeat_hats`).
  A fixed +28 ms bias corrects aubio's early beat reports.
- **PLL over detections.** aubio's beat output is smoothed by a phase-locked
  loop (phase gain 0.25, period gain 0.05, ±0.2 beat acceptance). After 8
  consecutive disagreeing detections (or fewer than 4 hits in the last 8), the loop re-locks from three consistent
  detections. The beat count stays continuous across re-locks, so bar
  alignment can survive.
- **No re-lock from aubio's tempo estimate by default.** On real techno, aubio's
  BPM estimate wanders between unrelated values (e.g. 143 ↔ 164). Hint-driven
  re-locks caused 5–8 spurious re-locks per 4 minutes. Without them there were 2–3.
  The option remains (`BeatPll(hint_relock_after=N)`).
- **Integrated clock.** `MusicalClock` integrates beat position instead of
  computing it from `time × bpm`, so tempo changes never jump the phase. External
  phase errors are slewed, rate limited to 0.5–2× nominal speed, and jumped only
  on first lock or a reported discontinuity.
- **Phase-only following.** The clock follows the analyser's phase, not its
  beat numbers. Local beat indices stay continuous through analyser restarts,
  and bar estimates are translated into local numbering.
- **Scheduled switches.** `trigger()` still builds compositions synchronously
  (transactional), but a quantised start is now a scheduler event. A newer
  trigger cancels and releases a pending one. Quantisation options: `now`,
  `next_beat`, `next_bar`, `grid:N`.
- **Packaging.** `aubio` 0.4.9 (the last PyPI release) is built from source with
  `CFLAGS=-Wno-error=incompatible-pointer-types` and without system libav/sndfile
  (`[tool.uv.extra-build-variables]` in `analysis/pyproject.toml`). Only its DSP
  is used.

## Measurements so far

Synthetic 126 BPM kick/hat track (`cctv_analysis.synth`), externally clocked:
phase error −2 ± 6 ms, tempo within 0.3 BPM, no re-locks, downbeat correct
with confidence 1.0. With equal-loudness kicks the bar confidence stays below
0.3, so no false bar claim is made.

End to end (`tools/timing_probe.sh`, analyser real-time → UDP → headless Godot,
60 fps):

| Input | Followed | Clock vs state phase error p95 | Beat event lateness max | Receiver cost |
| --- | --- | --- | --- | --- |
| Synthetic 126 BPM, 12 s | 68 % (lock after ~4 s) | 6.9 ms | 16.8 ms (≤ 1 frame) | ~0.3 ms/frame |
| Real techno (Ancient Methods AM-1 A1, from 60 s), 25 s | 79 % | 13.1 ms | 17.3 ms | ~0.3 ms/frame |

The table above was measured with the initial aubio tracker. With the comb
tracker, the same probe gives a p95 phase error of 2.7 ms (synthetic) and
3.7 ms (real techno).

Accuracy on real music against madmom references (16 tracks): F-measure 0.80,
tempo correct 92 % of locked time, 2.6 re-locks per 4 min. See
[beat-evaluation.md](beat-evaluation.md).

These are clock-versus-analyser figures. They do not include projector latency
or the audio output path. That requires the end-to-end latency measurement.

## Deferred work

1. **Live routing check (next session at the decks).** Run `tools/run.sh live`
   and `tools/route_mixxx.sh`, and confirm that only the main mix reaches the
   analyser (no headphone cue). Port-name patterns are heuristics; see
   `--list`. Recording the route in the session header moves to Milestone 5.
2. **Evaluation follow-up (low priority).** Listening checks of suspect
   references, cross-rhythm passages, and a better downbeat estimator
   ([beat-evaluation.md](beat-evaluation.md#next-steps)). Beat tracking is
   good enough for the visuals. Revisit only if it shows on stage.
3. **Mixxx telemetry adapter.** A controller-script mapping that samples per-deck
   `bpm`, `beat_distance`, `play`, `volume`, `pregain` and `[Master] crossfader`
   and forwards them to a small bridge. The bridge chooses an audible reference
   deck, cross-checks it against audio onsets, and publishes
   `timing_source: "mixxx"` with the same schema. It sits behind a flag, and
   audio-only remains the fallback. Mixxx controller APIs must be checked
   against the installed version first.
4. **Recording and replay → Milestone 5.** A session directory with the audio, the state JSONL,
   telemetry, the route and versions. A Godot REPLAY-mode reader applies recorded
   states by `t_audio` against the replay clock.
5. **Audiovisual latency (at the venue).** A click/flash test that measures audio heard →
   projected frame (photodiode/camera, or software via capture timestamps)
   and sets `latency_compensation` per venue setup.
6. **Long-session soak.** Run the analyser and benchmark together for 2 h to
   check overruns, receiver cost and RSS.

## Known limitations

- `--bpm-range` folds octave errors. Material outside it (e.g. 87 vs 174 DnB)
  is tracked at half or double tempo.
- Lock takes about 4 s after the start of music or a hard cut, and longer for beatless intros.
- Breakdowns without kicks lose lock. The clock free-runs at the last tempo
  with decaying confidence, which is the intended fallback.
- Beat detections are rejected while the input has been silent for 0.5 s.
