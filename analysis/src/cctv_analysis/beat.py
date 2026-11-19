"""Causal beat tracking: aubio beat detections smoothed by a phase-locked loop,
plus a downbeat (bar) estimator.

Conventions match the Godot ``MusicalClock``: beat position is a continuous
count of beats; ``beat_phase`` is 0 at an onset and rises to 1. Bar phase is
only meaningful with bar confidence > 0.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass

import aubio
import numpy as np

from .pcm import Samples

MIN_BPM = 70.0
MAX_BPM = 180.0


def fold_bpm(bpm: float, lo: float = MIN_BPM, hi: float = MAX_BPM) -> float:
    """Fold octave errors (half/double tempo) into [lo, hi)."""
    if bpm <= 0:
        return bpm
    while bpm < lo:
        bpm *= 2.0
    while bpm >= hi:
        bpm /= 2.0
    return bpm


@dataclass(slots=True)
class BeatState:
    locked: bool = False
    bpm: float = 0.0
    confidence: float = 0.0
    discontinuity: bool = False
    """True for the update in which the phase/tempo was re-acquired."""
    discontinuities: int = 0
    last_beat_t: float = -math.inf
    """Time of the last detection that agreed with the loop."""


class BeatPll:
    """Phase-locked loop over beat detection times.

    Position model: ``pos(t) = n0 + (t - t0) / period``. Each detection at time
    ``tb`` is compared with the nearest integer position; the loop corrects
    phase by ``alpha`` and period by ``beta`` of that error. Consistently
    disagreeing detections (a tempo change, a new track, a seek) trigger a
    re-lock which keeps the beat count continuous so downstream bar alignment
    survives where possible.

    ``hint_relock_after`` also re-locks when aubio's tempo estimate disagrees
    for that many detections. It is off by default: on real techno the
    estimate wanders between unrelated values (e.g. 143 vs 164 BPM) and caused
    more spurious re-locks than it caught. Small tempo changes (pitch fader)
    are followed by the loop; large ones produce misses and re-lock.
    """

    def __init__(
        self,
        alpha: float = 0.25,
        beta: float = 0.05,
        tolerance: float = 0.2,
        relock_after: int = 8,
        hint_relock_after: int | None = None,
        hit_window: int = 8,
        min_hits: int = 4,
        confidence_tau_beats: float = 6.0,
        lost_after_s: float = 2.5,
        bpm_range: tuple[float, float] = (MIN_BPM, MAX_BPM),
    ) -> None:
        self.bpm_range = bpm_range
        self.alpha = alpha
        self.beta = beta
        self.tolerance = tolerance
        self.relock_after = relock_after
        self.hint_relock_after = hint_relock_after
        self.min_hits = min_hits
        self._recent: deque[bool] = deque(maxlen=hit_window)
        self.stats = {"hits": 0, "misses": 0, "relock_miss": 0, "relock_hint": 0}
        self.k_conf = 1.0 - math.exp(-1.0 / confidence_tau_beats)
        self.lost_after_s = lost_after_s
        self.period = 0.0
        self.t0 = 0.0
        self.n0 = 0.0
        self._misses = 0
        self._hint_misses = 0
        self._pending: list[float] = []
        self.state = BeatState()

    def position(self, t: float) -> float:
        if not self.state.locked:
            return math.nan
        return self.n0 + (t - self.t0) / self.period

    def observe(self, tb: float, tempo_hint_bpm: float) -> None:
        """Feed a detection at time ``tb`` with the detector's current tempo estimate."""
        s = self.state
        hint = fold_bpm(tempo_hint_bpm, *self.bpm_range)
        if not s.locked:
            self._try_lock(tb, hint, continue_from=None)
            return
        self._pending.append(tb)
        self._pending = self._pending[-3:]
        pos = self.position(tb)
        err = pos - round(pos)
        # The detector consistently reports an unrelated tempo (new track): re-acquire.
        # Metrically related tempi (x2, x3/2, x4/3...) are ambiguity, not change.
        self._hint_misses = self._hint_misses + 1 if self._unrelated(hint) else 0
        if self.hint_relock_after is not None and self._hint_misses >= self.hint_relock_after:
            if self._try_lock(tb, hint, continue_from=pos, already_added=True):
                self.stats["relock_hint"] += 1
        elif abs(err) <= self.tolerance:
            self._misses = 0
            self._recent.append(True)
            self.stats["hits"] += 1
            # Phase: pull the loop towards the detection.
            self.n0 = pos - self.alpha * err
            self.t0 = tb
            # Period: err > 0 means we ran ahead -> slow down.
            self.period *= 1.0 + self.beta * err
            # Drift slowly towards the detector's tempo when it agrees (±4 %).
            if hint > 0 and abs(60.0 / hint - self.period) < 0.04 * self.period:
                self.period += 0.02 * (60.0 / hint - self.period)
            s.confidence += self.k_conf * ((1.0 - abs(err) / self.tolerance) - s.confidence)
            s.last_beat_t = tb
        else:
            self._misses += 1
            self._recent.append(False)
            self.stats["misses"] += 1
            s.confidence += self.k_conf * (0.0 - s.confidence)
            # Re-lock after a run of misses, or when most recent detections disagree
            # (a loop drifted to the wrong tempo still gets occasional chance hits).
            losing = len(self._recent) == self._recent.maxlen and sum(self._recent) < self.min_hits
            if (self._misses >= self.relock_after or losing) and self._try_lock(
                tb, hint, continue_from=pos, already_added=True
            ):
                self.stats["relock_miss"] += 1
        s.bpm = 60.0 / self.period

    RELATED_RATIOS = (1.0, 2.0, 0.5, 1.5, 2 / 3, 4 / 3, 0.75)

    def _unrelated(self, hint: float) -> bool:
        if hint <= 0:
            return False
        r = hint * self.period / 60.0
        return all(abs(r / q - 1.0) > 0.04 for q in self.RELATED_RATIOS)

    def _try_lock(
        self, tb: float, hint: float, continue_from: float | None, already_added: bool = False
    ) -> bool:
        """Lock once three detections agree on a period close to the tempo hint."""
        if not already_added:
            self._pending.append(tb)
            self._pending = self._pending[-3:]
        if len(self._pending) < 3 or hint <= 0:
            return False
        d1 = self._pending[1] - self._pending[0]
        d2 = self._pending[2] - self._pending[1]
        target = 60.0 / hint
        ok = all(abs(d / max(1, round(d / target)) - target) < 0.08 * target for d in (d1, d2))
        if not ok:
            return False
        s = self.state
        was_locked = s.locked
        self.period = target
        self.t0 = tb
        if continue_from is None:
            self.n0 = 0.0
        else:
            self.n0 = float(math.ceil(continue_from - 0.5))  # keep the count continuous
        self._misses = 0
        self._hint_misses = 0
        self._recent.clear()
        self._pending.clear()
        s.locked = True
        s.bpm = hint
        s.confidence = 0.5
        s.last_beat_t = tb
        if was_locked:
            s.discontinuity = True
            s.discontinuities += 1
        return True

    def tick(self, t: float) -> None:
        """Decay confidence while no detections agree (breakdowns, silence)."""
        s = self.state
        if s.locked and t - s.last_beat_t > self.lost_after_s:
            s.confidence *= 0.995
        if s.locked and t - s.last_beat_t > 4 * self.lost_after_s:
            s.confidence = min(s.confidence, 0.05)


class BeatTracker:
    """aubio ``tempo`` detector feeding a ``BeatPll``.

    ``method="energy"`` follows the kick/bass; spectral methods (aubio's
    ``default``/``specflux``) lock onto offbeat hi-hats in dance music (see
    tests/test_beat.py). ``bias_s`` is added to detection times to compensate
    the detector's systematic offset (about -28 ms for a synthetic kick).
    """

    def __init__(
        self,
        sample_rate: int,
        hop: int = 512,
        win: int = 1024,
        method: str = "energy",
        bias_s: float = 0.028,
        bpm_range: tuple[float, float] = (MIN_BPM, MAX_BPM),
    ) -> None:
        self.sr = sample_rate
        self.hop = hop
        self.bias_s = bias_s
        self._tempo = aubio.tempo(method, win, hop, sample_rate)

        self._tempo.set_silence(-60.0)
        self._last = 0
        self.pll = BeatPll(bpm_range=bpm_range)
        self.detections = 0

    def process(
        self, x: Samples, sample_index: int, t_mono: float, silent: bool = False
    ) -> BeatState:
        """Process one block whose first sample is ``sample_index`` heard at ``t_mono``.

        Detections in silent blocks are ignored (aubio reports spurious beats there)."""
        self.pll.state.discontinuity = False
        self._tempo(x)
        # The returned flag is 0 when a beat falls exactly on the block start, so
        # detect new beats from get_last() instead.
        last = int(self._tempo.get_last())
        if last != self._last:
            self._last = last
            if silent:
                self.pll.tick(t_mono)
                return self.pll.state
            # aubio reports beat times in seconds of processed stream (delay-compensated).
            last_s = float(self._tempo.get_last_s())
            tb = t_mono + (last_s - sample_index / self.sr) + self.bias_s
            self.detections += 1
            self.pll.observe(tb, float(self._tempo.get_bpm()))
        self.pll.tick(t_mono)
        return self.pll.state


@dataclass(slots=True)
class BarState:
    downbeat: int = -1
    """Beat index (mod beats_per_bar) that starts a bar, or -1 when unknown."""
    confidence: float = 0.0
    source: str = "none"
    """``none``, ``estimate`` or ``manual``."""


class DownbeatEstimator:
    """Score each beat-in-bar hypothesis with beat-synchronous evidence.

    Two cues, weighted by ``w_bass`` and ``w_novelty``:

    - bass: peak bass amplitude at the start of the beat, relative to the
      loudest beat of the last bar. This works when downbeat kicks are accented.
    - novelty: positive spectral change of the beat's mean spectrum against the
      previous beat, relative to the recent mean. Pattern and harmony changes
      tend to happen on bar starts.

    Defaults come from docs/beat-evaluation.md. Novelty beats bass on real
    techno (downbeat F 0.31 vs 0.03), but it is still often consistently one
    beat off, so estimates are hints. MusicalClock only uses them when
    ``auto_bar_alignment`` is enabled.

    Scores decay over ``decay_bars``. Confidence is the margin between the best
    and second-best hypotheses. Beat phase alone never implies a bar; consumers
    must check ``confidence``.
    """

    def __init__(
        self,
        beats_per_bar: int = 4,
        decay_bars: float = 16.0,
        min_beats: int = 16,
        w_bass: float = 0.0,
        w_novelty: float = 1.0,
        confidence_gain: float = 4.0,
    ) -> None:
        self.bpb = beats_per_bar
        self.decay = math.exp(-1.0 / (decay_bars * beats_per_bar))
        self.min_beats = min_beats
        self.w_bass = w_bass
        self.w_novelty = w_novelty
        self.confidence_gain = confidence_gain
        self.manual: int | None = None
        self.state = BarState()
        self.reset()

    def reset(self) -> None:
        self.scores = [0.0] * self.bpb
        self.beats = 0
        self._last_index: int | None = None
        self._peak = 0.0
        self._recent = [0.0] * self.bpb
        self._acc: Samples | None = None
        self._acc_n = 0
        self._prev_spec: Samples | None = None
        self._nov_mean = 0.0

    def align(self, downbeat_index: int) -> None:
        """Operator override: beat ``downbeat_index`` is a bar's first beat."""
        self.manual = downbeat_index % self.bpb

    def clear_manual(self) -> None:
        self.manual = None

    def _bank(self, slot: int) -> None:
        self._recent[slot] = self._peak
        ref = max(self._recent) or 1.0
        bass = self._peak / ref
        nov = 0.0
        if self._acc is not None and self._acc_n:
            spec = (self._acc / self._acc_n).astype(np.float32)
            if self._prev_spec is not None:
                raw = float(np.maximum(spec - self._prev_spec, 0.0).sum())
                self._nov_mean += 0.1 * (raw - self._nov_mean)
                nov = raw / (self._nov_mean + 1e-9)
            self._prev_spec = spec
        self.scores = [v * self.decay for v in self.scores]
        self.scores[slot] += self.w_bass * bass + self.w_novelty * nov
        self.beats += 1
        self._peak = 0.0
        self._acc = None
        self._acc_n = 0

    def process(self, position: float, bass_amp: float, bands: Samples | None = None) -> BarState:
        s = self.state
        if math.isnan(position):
            self._last_index = None
            s.downbeat, s.confidence, s.source = -1, 0.0, "none"
            if self.manual is not None:
                s.downbeat, s.confidence, s.source = self.manual, 1.0, "manual"
            return s
        idx = math.floor(position)
        if self._last_index is not None and idx != self._last_index:
            self._bank(self._last_index % self.bpb)
        self._last_index = idx
        # Peak bass amplitude in the first ~quarter of each beat (the kick).
        if position - idx < 0.25:
            self._peak = max(self._peak, bass_amp)
        if bands is not None:
            self._acc = bands.astype(np.float32) if self._acc is None else self._acc + bands
            self._acc_n += 1
        if self.manual is not None:
            s.downbeat, s.confidence, s.source = self.manual, 1.0, "manual"
        elif self.beats >= self.min_beats:
            ranked = sorted(range(self.bpb), key=lambda i: self.scores[i], reverse=True)
            best, second = self.scores[ranked[0]], self.scores[ranked[1]]
            s.downbeat = ranked[0]
            margin = (best - second) / (abs(best) + 1e-9)
            s.confidence = max(0.0, min(1.0, margin * self.confidence_gain))
            s.source = "estimate"
        else:
            s.downbeat, s.confidence, s.source = -1, 0.0, "none"
        return s
