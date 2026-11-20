# Beat and bar tracking evaluation

[Documentation index](../README.md#documentation)

How well does the **causal** analyser find beats and bars in real music? This
document describes the evaluation method, the current results and their limits.

## Method

```sh
cd analysis && uv sync --group eval
uv run cctv-evaluate --list ../bench/eval/corpus.txt --json ../bench/eval/run.json
uv run cctv-evaluate --list ../bench/eval/corpus.txt --clicks ../bench/eval/clicks   # listening check
```

- **Reference.** madmom's offline RNN + DBN downbeat tracker
  (`RNNDownBeatProcessor` and `DBNDownBeatTrackingProcessor`, 3/4 and 4/4), cached in
  `~/.cache/cctv/reference-beats/`. Hand annotations take precedence when an
  `<audio>.beats` file exists (`time [beat_in_bar]` per line). The reference is
  only used for scoring. It is never published as musical state or used as a
  policy observation.
- **Estimate.** The analyser runs externally clocked over the file. Beats are
  the moments the *published* `beat_position` crosses an integer, which is what
  the Godot clock follows. Downbeats are beats the analyser marks as bar
  starts while `bar_confidence ≥ 0.5`.
- **Metrics** (`mir_eval`, ±70 ms window):

| Column | Meaning |
| --- | --- |
| F, CMLt, AMLt | F-measure, correct-metrical-level and any-metrical-level continuity (AMLt also accepts off-beat/double/half) |
| confP | Share of beats emitted while confidence ≥ 0.3 (those the clock follows) that are correct |
| confCov | Share of reference beats covered by a confident, correct beat |
| off ms, iqr | Median and IQR of the signed beat offset against the reference |
| tempo, tempo8 | Share of locked time with tempo within 4 % (tempo8 also accepts ×2 and ×½) |
| dbF, dbP, barCov | Downbeat F-measure, downbeat precision, share of time with bar confidence ≥ 0.5 |
| lock s, relock | Time to first lock and number of phase re-acquisitions (visible jumps) |

- **Corpus** (`bench/eval/corpus.txt`): 16 tracks drawn with a fixed seed from
  the local library across directories, plus a house track and a big-beat
  track. It covers industrial hardcore, techno, hard techno, house and
  breakbeat, at 111–167 BPM. The first 240 s of each track are used.

## Results (2026-11-19)

| Tracker | F | CMLt | AMLt | confP | confCov | off ms | iqr | tempo | dbF | dbP | barCov | relocks / 4 min |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| aubio + PLL (initial) | 0.63 | 0.60 | 0.63 | 0.66 | 0.56 | +7 | 46 | 0.78 | 0.01 | 0.06 | 0.10 | 4.4 |
| aubio + PLL, windowed re-lock | 0.65 | 0.63 | 0.66 | 0.66 | 0.64 | +10 | 30 | 0.85 | 0.18 | 0.27 | 0.51 | 11.1 |
| **comb (default)** | **0.80** | **0.77** | **0.81** | **0.83** | **0.76** | **+5** | **15** | **0.92** | 0.31 | 0.39 | 0.70 | **2.6** |

Per track, the comb tracker scores F ≥ 0.92 on 9 of 16 tracks and F ≥ 0.80 on
12. The remaining failures:

| Track | F / AMLt | Diagnosis |
| --- | --- | --- |
| Nasenbluten – Feeling Shit | 0.38 / 0.57 | Reference 111 BPM (probably half of ~222 BPM hardcore). Locks alternate between the two kick phases, so `--bpm-range` should be set for this genre |
| Raär – L'accomplissement | 0.35 / 0.61 | Off-beat lock. Ambient intro: first lock after 49 s |
| DJ Sun – Uh Ah | 0.47 / 0.51 | Every band has more onset energy *between* reference beats. Suspect the reference itself (listening check needed) |
| Vittorio di Mango – Kura Kura | 0.44 / 0.20 | Tracked at 4:3 of the reference tempo (166 vs 125 BPM) for most of the excerpt (cross-rhythm) |

## Recorded DJ set (2024-06-21, 145 min, 35 tracks, ~154 BPM)

`cctv-evaluate SET.wav --cue SET.cue --duration 0` scores the whole set, each
cue track, the first 60 s after each cue (transitions) and the rest of each
track (steady). The madmom reference is computed in overlapping 120 s chunks.

| Tracker | Whole-set F | CMLt | Tempo correct | Transitions F | Steady F | Re-locks (set) |
| --- | --- | --- | --- | --- | --- | --- |
| aubio + PLL | 0.39 | 0.34 | 0.79 | 0.41 | 0.40 | 434 |
| comb, first version | 0.74 | 0.59 | 0.65 | 0.72 | 0.73 | 208 |
| **comb, current** | **0.88** | **0.86** | **0.94** | **0.87** | **0.87** | **75** |

Corpus with the current tracker: F 0.84, tempo correct 0.91, 1.4 re-locks per 4 min.

The set exposed two problems that the single tracks did not:

- Tracks 20–31 were tracked at 2/3 or 1/2 tempo (103/78 vs 154 BPM). Rolling
  off-beat bass makes the 3:2 grid fit as well as the true pulse, and the narrow
  "locked" tempo prior kept the wrong lock alive for minutes. Fixes:
  - Rank the top 3 tempo candidates by beat-grid fit plus half-period
    (subdivision) fit.
  - Drop the locked prior.
  - Centre the global prior on 135 BPM.
- Tempo could drift with estimates that agreed on phase but not on tempo. The
  follower now accepts an update only if the tempo is within 4 %. A different
  tempo must win 12 consecutive updates before it switches.

Transitions score as well as steady parts. Remaining weak spots are
cross-rhythm passages (e.g. around 80 min, where even madmom reports 207 BPM).
There the confidence drops and the Godot clock free-runs, which is the
intended fallback.

The tempo prior is tuned on this library (hard techno, 125–170 BPM). For other
genres, set `cctv-analyse --tempo-prior BPM`.

## What changed and why

1. **Windowed re-lock in the aubio PLL.** A loop that had drifted to the wrong
   tempo (158 vs 133 BPM) never re-locked, because occasional chance hits reset
   the consecutive-miss counter. Re-locking when fewer than 4 of the last 8
   detections agree fixed the tempo (0.78 → 0.85), but re-locks rose to 11 per
   4 min.
2. **aubio onset methods and low-pass input** made no meaningful difference
   (F 0.59–0.67 across 12 combinations). The per-beat decisions were the
   bottleneck: aubio's detections fall on the off-beat about a third of the time
   on several tracks.
3. **Comb-filter tracker** (`comb.py`). It re-estimates tempo and phase every
   0.25 s from 8 s of onset strength:
   - The onset band is 20 Hz–2 kHz. Full-band flux was stronger *off* the beat
     on 7 of 16 tracks (hi-hats). 20–200 Hz and 100–2000 Hz scored lower.
   - Tempo comes from the autocorrelation at 1×, 2× and 4× the lag (beat, half
     bar, bar) with a log-normal prior centred on 128 BPM. Once locked, a narrow
     prior around the current tempo is added.
   - The period is refined jointly with the phase (±0.6 %), so the tempo is
     exact on synthetic material.
   - The phase is the grid that best fits the last 16 beats, weighted towards
     recent beats.
   - A hysteresis follower switches phase only after 12 consecutive consistent
     disagreements (3 s).
   - Swept parameters: band, window (6, 8, 12 s), phase memory, switch delay
     and priors. Differences were within ±0.02 F except for the band.
4. **Bias calibration.** On synthetic kicks the comb tracker's beats are
   within ±12 ms of the true onsets (`tests/test_comb.py`). Against madmom the
   median offset is +5 ms. madmom itself is about 12 ms early on the synthetic
   kick, so absolute offsets carry roughly ±10 ms of reference uncertainty.
   Projector latency is calibrated separately (`latency_compensation`).
5. **Downbeats.** Beat-synchronous spectral novelty replaced bass accent
   (dbF 0.03 → 0.31). On real techno the kick is equally loud on every beat, so
   bass accent carries no information. A per-track breakdown shows the estimator
   is usually *decisive but often consistently one beat off*: novelty peaks on
   fills and pickups before the bar. Precision (0.39) is far too low to drive
   `next_bar` events. **`MusicalClock.auto_bar_alignment` is therefore off by
   default.** The estimate is reported as a hint (`bar_estimate`), and operator
   alignment (`B`) is the supported path.

## Limitations of this evaluation

- **The reference is another algorithm.** madmom is strong on popular music, but
  its accuracy on hard techno and hardcore is unknown. At least one track
  (DJ Sun) looks like a reference error. Use `--clicks` to render 30 s excerpts
  with reference clicks (`*.ref.wav`) and estimate clicks (`*.est.wav`); the
  right channel carries the clicks, with downbeats lower and longer. Fix
  wrong references with an `<audio>.beats` annotation file.
- 16 tracks of 240 s is small. The parameter sweeps are prone to overfitting
  this corpus, so prefer changes that help broadly over those that help single
  tracks.
- Individual tracks are not DJ sets. Transitions between tracks (two
  overlapping tempi, pitch-fader drift) are not yet in the corpus. Recorded
  sets should be added as soon as available.

## Next steps

1. Listening check of the references for the four failing tracks. Annotate
   corrections.
2. Add 2–3 recorded DJ sets (with madmom reference over the whole set) to
   measure behaviour across transitions.
3. Address the cross-rhythm case (Kura Kura) by weighting the bar-level comb
   term more strongly, or by a downbeat-aware tempo check, once DJ sets are in
   the corpus.
4. Downbeats: a learned or pattern-based estimator (e.g. bar-level
   self-similarity) is needed before automatic bar alignment can be enabled.
