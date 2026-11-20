"""Causal comb-filter beat tracker.

Instead of per-beat decisions (aubio), tempo and phase are re-estimated every
``update_s`` from the last ``window_s`` of an onset-strength signal (OSS):

1. OSS: half-wave rectified log-spectral flux in 20 Hz - 2 kHz. That band
   favours kicks/snares over offbeat hi-hats (bench/eval shows full-band flux is
   often *stronger off the beat* in techno).
2. Tempo: autocorrelation of the OSS with multiples-of-lag comb summation,
   weighted by a log-normal tempo prior. Once locked, a narrow prior around the
   current tempo keeps the estimate from hopping between unrelated values.
3. Phase: the beat grid (period P) that best fits the recent OSS, with
   exponentially decaying weights for older beats.

A ``PhaseFollower`` turns these periodic estimates into a continuous beat
position. It applies hysteresis, so the phase only switches (a re-lock with
``discontinuity``) when another phase wins consistently.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass

import numpy as np
import numpy.typing as npt

from .beat import MAX_BPM, MIN_BPM, BeatState

F32 = npt.NDArray[np.float32]
F64 = npt.NDArray[np.float64]


@dataclass(slots=True)
class CombParams:
    window_s: float = 8.0
    update_s: float = 0.25
    band_hz: tuple[float, float] = (20.0, 2000.0)
    prior_bpm: float = 135.0
    """Centre of the tempo prior. Tuned on a hard techno library and set
    (docs/beat-evaluation.md); override with ``cctv-analyse --tempo-prior``."""
    prior_octaves: float = 0.6
    """Width (std, octaves) of the global tempo prior."""
    locked_octaves: float = 0.04
    """Width of the prior around the current tempo once locked (≈ 3 %)."""
    locked_mix: float = 0.0
    """Share of a narrow prior around the current tempo. 0 by default: on a DJ set it
    kept wrong 3:2 / half-tempo locks alive for minutes (set F 0.71 -> 0.86 without)."""
    comb_multiples: tuple[int, ...] = (1, 2, 4)
    comb_weights: tuple[float, ...] = (1.0, 0.5, 0.25)
    tempo_candidates: int = 3
    grid_rank: bool = True
    subdivision: bool = True
    period_refine: tuple[float, ...] = (-0.006, -0.003, 0.0, 0.003, 0.006)
    phase_beats: int = 16
    phase_decay: float = 0.9
    bias_s: float = -0.0135
    """Added to estimated beat times: the flux peak lags the onset by ~28 ms
    (calibrated on synthetic kicks, tests/test_comb.py)."""


@dataclass(slots=True)
class CombEstimate:
    t: float
    """Time of the estimate (end of the analysed audio)."""
    period_s: float
    last_beat_t: float
    salience: float
    """0..1: how clearly the best phase stands out."""
    score: float = 0.0


class CombEstimator:
    """Tempo + phase estimation from an OSS ring buffer."""

    def __init__(
        self,
        frame_rate: float,
        params: CombParams | None = None,
        bpm_range: tuple[float, float] = (MIN_BPM, MAX_BPM),
    ) -> None:
        self.fr = frame_rate
        self.p = params or CombParams()
        self.bpm_range = bpm_range
        self.n = int(self.p.window_s * frame_rate)
        self.buf: deque[float] = deque(maxlen=self.n)
        self.lags = np.arange(
            max(2, int(60.0 * frame_rate / bpm_range[1])),
            int(60.0 * frame_rate / bpm_range[0]) + 2,
        )
        self.locked_bpm: float | None = None

    def push(self, value: float) -> None:
        self.buf.append(value)

    def ready(self) -> bool:
        return len(self.buf) >= self.n // 2

    def _prior(self, bpm: F64) -> F64:
        p = self.p
        g = np.exp(-0.5 * (np.log2(bpm / p.prior_bpm) / p.prior_octaves) ** 2)
        if self.locked_bpm is None:
            return np.asarray(g)
        loc = np.exp(-0.5 * (np.log2(bpm / self.locked_bpm) / p.locked_octaves) ** 2)
        return np.asarray(p.locked_mix * loc + (1 - p.locked_mix) * g)

    def estimate(self, t_now: float) -> CombEstimate | None:
        if not self.ready():
            return None
        o = np.asarray(self.buf, dtype=np.float64)
        # Remove the slowly varying level so sustained sections don't dominate.
        k = max(3, int(0.25 * self.fr) | 1)
        o = np.maximum(o - np.convolve(o, np.ones(k) / k, mode="same"), 0.0)
        if not np.any(o > 0):
            return None
        o -= o.mean()
        m = len(o)
        spec = np.fft.rfft(o, 2 * m)
        ac = np.fft.irfft(spec * np.conj(spec))[:m]
        if ac[0] <= 0:
            return None
        ac /= ac[0]
        lags = self.lags[self.lags * 2 < m]
        # Comb: a true beat period also correlates at 2x (half bar) and 4x (bar).
        # The bar term separates the 4/4 pulse from 4:3 cross-rhythms.
        score = np.zeros(len(lags))
        for mult, wt in zip(self.p.comb_multiples, self.p.comb_weights, strict=True):
            score += wt * ac[np.minimum(mult * lags, m - 1)] * (mult * lags < m)
        bpm = 60.0 * self.fr / lags
        score = np.maximum(score, 0.0) * self._prior(bpm.astype(np.float64))
        raw = np.asarray(self.buf, dtype=np.float64)
        prior = self._prior((60.0 * self.fr / lags).astype(np.float64))
        best: CombEstimate | None = None
        best_rank = -math.inf
        for i in self._candidates(score):
            lag = float(lags[i])
            if 0 < i < len(lags) - 1:  # parabolic refinement for sub-frame period
                a, b, c = score[i - 1], score[i], score[i + 1]
                den = a - 2 * b + c
                if den < 0:
                    lag += 0.5 * (a - c) / den
            period = lag / self.fr
            # The autocorrelation period is only accurate to ~1 %. Refine it jointly
            # with the phase: a slightly wrong period skews the fitted grid.
            cands = [self._phase(raw, period * (1 + d), t_now) for d in self.p.period_refine]
            e = max(cands, key=lambda c: c.score)
            # Rank tempo candidates by how strongly their beat grid hits onsets
            # (mean OSS on the grid), weighted by the prior. Autocorrelation alone
            # confuses 3:2 cross-rhythms (rolling off-beat bass) with the pulse.
            # Duple-meter consistency: the half-period grid of a true pulse also hits
            # onsets (off-beats), while a 3:2 candidate's half grid does not.
            sub = self._phase(raw, e.period_s / 2, t_now).score if self.p.subdivision else 0.0
            rank = (e.score + sub) * float(prior[i]) if self.p.grid_rank else float(score[i])
            if rank > best_rank:
                best, best_rank = e, rank
        return best

    def _candidates(self, score: F64) -> list[int]:
        """Indices of the strongest local maxima of the tempo score."""
        k = self.p.tempo_candidates
        if k <= 1:
            return [int(np.argmax(score))]
        peaks = [
            i
            for i in range(len(score))
            if score[i] > 0
            and (i == 0 or score[i] >= score[i - 1])
            and (i == len(score) - 1 or score[i] >= score[i + 1])
        ]
        peaks.sort(key=lambda i: score[i], reverse=True)
        return peaks[:k] or [int(np.argmax(score))]

    def _phase(self, o: F64, period: float, t_now: float) -> CombEstimate:
        """Fit a beat grid with spacing ``period`` to the recent OSS."""
        p = self.p
        lag = period * self.fr
        # Tolerate ±1 frame jitter.
        om = np.maximum(o, np.maximum(np.roll(o, 1), np.roll(o, -1)))
        m = len(om)
        phis = np.arange(0.0, lag, 0.5)  # frames back from the newest sample
        ks = np.arange(p.phase_beats)
        w = p.phase_decay**ks
        pos = (m - 1) - phis[:, None] - ks[None, :] * lag
        valid = pos >= 0
        vals = np.interp(np.clip(pos, 0, m - 1), np.arange(m), om) * valid
        scores = (vals * w).sum(axis=1) / np.maximum((valid * w).sum(axis=1), 1e-9)
        j = int(np.argmax(scores))
        best = scores[j]
        med = float(np.median(scores))
        salience = float((best - med) / (best + 1e-12)) if best > 0 else 0.0
        last_beat = t_now - phis[j] / self.fr + p.bias_s
        return CombEstimate(t_now, period, last_beat, salience, float(best))


class PhaseFollower:
    """Continuous beat position from periodic (period, last-beat) estimates.

    Same position model and state as ``BeatPll``: ``pos(t) = n0 + (t - t0) / period``.
    """

    def __init__(
        self,
        alpha: float = 0.2,
        gamma: float = 0.15,
        beta: float = 0.02,
        tolerance: float = 0.2,
        switch_after: int = 12,
        tempo_tolerance: float = 0.04,
        confidence_tau: float = 8.0,
    ) -> None:
        self.alpha = alpha
        self.gamma = gamma
        self.beta = beta
        self.tolerance = tolerance
        self.switch_after = switch_after
        self.tempo_tolerance = tempo_tolerance
        self.k_conf = 1.0 - math.exp(-1.0 / confidence_tau)
        self.period = 0.0
        self.t0 = 0.0
        self.n0 = 0.0
        self._disagree = 0
        self._candidate: tuple[float, float] | None = None
        self.stats = {"hits": 0, "misses": 0, "relock_miss": 0, "relock_hint": 0}
        self.state = BeatState()

    def position(self, t: float) -> float:
        if not self.state.locked:
            return math.nan
        return self.n0 + (t - self.t0) / self.period

    def observe(self, e: CombEstimate, salience_min: float = 0.15) -> None:
        s = self.state
        s.discontinuity = False
        weak = e.salience < salience_min
        if not s.locked:
            if weak:
                return
            self.period, self.t0, self.n0 = e.period_s, e.last_beat_t, 0.0
            s.locked, s.confidence, s.last_beat_t = True, 0.5, e.last_beat_t
            s.bpm = 60.0 / self.period
            return
        pos = self.position(e.last_beat_t)
        err = pos - round(pos)
        if weak:
            s.confidence += self.k_conf * (0.0 - s.confidence)
            return
        same_tempo = abs(e.period_s / self.period - 1.0) <= self.tempo_tolerance
        if abs(err) <= self.tolerance and same_tempo:
            self._disagree = 0
            self._candidate = None
            self.stats["hits"] += 1
            self.n0 = pos - self.alpha * err
            self.t0 = e.last_beat_t
            self.period += self.gamma * (e.period_s - self.period)
            # Remove steady-state tempo error: running ahead (err > 0) -> slower.
            self.period *= 1.0 + self.beta * err
            s.confidence += self.k_conf * (min(1.0, e.salience * 2.0) - s.confidence)
            s.last_beat_t = e.last_beat_t
        else:
            self.stats["misses"] += 1
            s.confidence += self.k_conf * (0.0 - s.confidence)
            # Switch only if the same alternative (phase and tempo) keeps winning.
            c = self._candidate
            if (
                c is not None
                and abs(_wrap(err - c[0])) < self.tolerance
                and abs(e.period_s / c[1] - 1.0) <= self.tempo_tolerance
            ):
                self._disagree += 1
            else:
                self._disagree = 1
            self._candidate = (err, e.period_s)
            if self._disagree >= self.switch_after:
                self.n0 = float(round(pos))
                self.t0 = e.last_beat_t
                self.period = e.period_s
                self._disagree = 0
                self._candidate = None
                s.discontinuity = True
                s.discontinuities += 1
                s.last_beat_t = e.last_beat_t
                self.stats["relock_miss"] += 1
        s.bpm = 60.0 / self.period


def _wrap(x: float) -> float:
    return x - round(x)


class CombBeatTracker:
    """Drop-in alternative to ``BeatTracker`` (``.process()``, ``.pll``)."""

    def __init__(
        self,
        sample_rate: int,
        hop: int = 512,
        n_bins: int = 1025,
        bpm_range: tuple[float, float] = (MIN_BPM, MAX_BPM),
        params: CombParams | None = None,
    ) -> None:
        self.sr = sample_rate
        self.hop = hop
        self.params = params or CombParams()
        fr = sample_rate / hop
        self.est = CombEstimator(fr, self.params, bpm_range)
        freqs = np.fft.rfftfreq(2 * (n_bins - 1), 1.0 / sample_rate)
        lo, hi = self.params.band_hz
        self._band = (freqs >= lo) & (freqs < hi)
        self._prev: F64 | None = None
        self._every = max(1, round(self.params.update_s * fr))
        self._n = 0
        self.pll = PhaseFollower()
        self.last: CombEstimate | None = None

    def oss(self, mag: F32) -> float:
        lm = np.log1p(100.0 * mag[self._band].astype(np.float64))
        prev, self._prev = self._prev, lm
        if prev is None:
            return 0.0
        return float(np.maximum(lm - prev, 0.0).sum())

    def process(
        self,
        x: F32,
        sample_index: int,
        t_mono: float,
        silent: bool = False,
        mag: F32 | None = None,
    ) -> BeatState:
        if mag is None:
            raise ValueError("CombBeatTracker needs the block magnitude spectrum")
        self.pll.state.discontinuity = False
        self.est.push(0.0 if silent else self.oss(mag))
        self._n += 1
        t_end = t_mono + len(x) / self.sr
        if self._n % self._every == 0 and not silent:
            e = self.est.estimate(t_end)
            if e is not None:
                self.last = e
                self.pll.observe(e)
                self.est.locked_bpm = self.pll.state.bpm if self.pll.state.locked else None
        if silent and self.pll.state.locked:
            self.pll.state.confidence *= 0.995
        return self.pll.state
