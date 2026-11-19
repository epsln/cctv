"""Fast (per block) and slow (~2 Hz) causal features.

All normalisation is rolling: values only depend on audio that has already been
heard, so file and live inputs produce the same features at the same moments.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass

import numpy as np

from .pcm import Samples

BANDS: dict[str, tuple[float, float]] = {
    "bass": (20.0, 150.0),
    "mid": (150.0, 2000.0),
    "high": (2000.0, 16000.0),
}


def _coef(tau_s: float, dt: float) -> float:
    """One-pole smoothing coefficient for time constant ``tau_s``."""
    return 1.0 - math.exp(-dt / tau_s) if tau_s > 0 else 1.0


class RangeNorm:
    """Map a value to [0, 1] relative to its recent range.

    A peak (and floor) follower jumps to new extremes immediately and relaxes
    towards the signal with time constant ``tau_s``.
    """

    def __init__(self, tau_s: float, dt: float, min_span: float) -> None:
        self.k = _coef(tau_s, dt)
        self.min_span = min_span
        self.hi: float | None = None
        self.lo: float | None = None

    def __call__(self, x: float) -> float:
        if self.hi is None or self.lo is None:
            self.hi = self.lo = x
        self.hi = x if x > self.hi else self.hi + self.k * (x - self.hi)
        self.lo = x if x < self.lo else self.lo + self.k * (x - self.lo)
        span = max(self.hi - self.lo, self.min_span)
        return min(max((x - (self.hi - span)) / span, 0.0), 1.0)


class Envelope:
    """Attack/release follower."""

    def __init__(self, attack_s: float, release_s: float, dt: float) -> None:
        self.a = _coef(attack_s, dt)
        self.r = _coef(release_s, dt)
        self.value = 0.0

    def __call__(self, x: float) -> float:
        k = self.a if x > self.value else self.r
        self.value += k * (x - self.value)
        return self.value


@dataclass(slots=True)
class FastFeatures:
    bass: float = 0.0
    bass_amp: float = 0.0
    """Un-normalised bass band amplitude (for relative comparisons, e.g. downbeats)."""
    mid: float = 0.0
    high: float = 0.0
    level: float = 0.0
    onset: bool = False
    onset_strength: float = 0.0
    onset_envelope: float = 0.0
    transient_density: float = 0.0
    """Onsets per second, smoothed over ~2 s."""
    spectral_change: float = 0.0
    silent: bool = True


class FastAnalyser:
    """Band energies, envelopes and onsets for each ``hop``-sample block."""

    SILENCE_DB = -60.0
    SILENCE_HOLD_S = 0.5

    def __init__(self, sample_rate: int, hop: int = 512, win: int = 2048) -> None:
        self.sr = sample_rate
        self.hop = hop
        self.win = win
        dt = hop / sample_rate
        self.dt = dt
        self._buf = np.zeros(win, np.float32)
        self._window = np.hanning(win).astype(np.float32)
        freqs = np.fft.rfftfreq(win, 1.0 / sample_rate)
        self._masks = {b: (freqs >= lo) & (freqs < hi) for b, (lo, hi) in BANDS.items()}
        self._norm = {b: RangeNorm(8.0, dt, 18.0) for b in BANDS}
        self._env = {b: Envelope(0.005, 0.12, dt) for b in BANDS}
        self._level_norm = RangeNorm(8.0, dt, 24.0)
        self._flux_hist: deque[float] = deque(maxlen=max(3, round(0.2 / dt)))
        self._flux_peak = Envelope(0.0, 4.0, dt)
        self._above = False
        self._since_onset = 1e9
        self._min_ioi = 0.05
        self._onset_decay = math.exp(-dt / 0.12)
        self._density_k = _coef(2.0, dt)
        self._flux_norm = RangeNorm(4.0, dt, 1e-6)
        self._prev_mag: Samples | None = None
        self._prev_log: Samples | None = None
        self._quiet_s = self.SILENCE_HOLD_S
        self.out = FastFeatures()
        self.mag: Samples = np.zeros(len(freqs), np.float32)

    def _detect_onset(self, mag: Samples, silent: bool) -> tuple[bool, float]:
        """Log spectral flux with an adaptive threshold (median of the last 0.2 s
        plus a fraction of the recent peak). Fires on the rising edge only, so it
        adds no look-ahead latency."""
        log_mag = np.log1p(100.0 * mag)
        prev = self._prev_log
        self._prev_log = log_mag
        if prev is None:
            return False, 0.0
        flux = float(np.maximum(log_mag - prev, 0.0).sum())
        peak = self._flux_peak(flux)
        thr = (float(np.median(self._flux_hist)) if self._flux_hist else 0.0) + 0.15 * peak
        self._flux_hist.append(flux)
        self._since_onset += self.dt
        above = flux > thr and flux > 1e-3
        onset = above and not self._above and not silent and self._since_onset >= self._min_ioi
        self._above = above
        if onset:
            self._since_onset = 0.0
        return onset, flux

    def process(self, x: Samples) -> FastFeatures:
        if len(x) != self.hop:
            raise ValueError(f"block of {len(x)} samples, expected hop={self.hop}")
        self._buf = np.roll(self._buf, -self.hop)
        self._buf[-self.hop :] = x
        mag = np.abs(np.fft.rfft(self._buf * self._window)).astype(np.float32)
        self.mag = mag
        power = mag * mag
        f = self.out
        for b, mask in self._masks.items():
            p = float(power[mask].sum())
            db = 10.0 * math.log10(p + 1e-12)
            if b == "bass":
                f.bass_amp = math.sqrt(p)
            setattr(f, b, self._env[b](self._norm[b](db)))
        rms_db = 20.0 * math.log10(float(np.sqrt(np.mean(x * x))) + 1e-9)
        # Silent = nothing above the gate for SILENCE_HOLD_S (gaps between hits are not silence).
        self._quiet_s = self._quiet_s + self.dt if rms_db < self.SILENCE_DB else 0.0
        f.silent = self._quiet_s >= self.SILENCE_HOLD_S
        f.level = self._level_norm(rms_db)
        if f.silent:
            f.bass = f.mid = f.high = f.level = 0.0

        onset, flux = self._detect_onset(mag, f.silent)
        f.onset = onset
        f.onset_strength = self._flux_norm(flux)
        f.onset_envelope = 1.0 if onset else f.onset_envelope * self._onset_decay
        rate = (1.0 / self.dt) if onset else 0.0
        f.transient_density += self._density_k * (rate - f.transient_density)

        if self._prev_mag is not None:
            num = float(np.dot(mag, self._prev_mag))
            den = float(np.linalg.norm(mag) * np.linalg.norm(self._prev_mag)) + 1e-12
            f.spectral_change = 1.0 - num / den
        self._prev_mag = mag
        return f


@dataclass(slots=True)
class SlowFeatures:
    energy_short: float = 0.0
    """Level (0..1) smoothed over ~2 s."""
    energy_long: float = 0.0
    """Level (0..1) smoothed over ~30 s."""
    energy_trend: float = 0.0
    """energy_short - energy_long: > 0 building, < 0 breakdown."""
    novelty: float = 0.0
    """Spectral distance between the last ~2 s and the last ~16 s (section-change evidence)."""


class SlowAnalyser:
    """Updated every block, published at a low rate. Inputs come from ``FastAnalyser``."""

    N_BANDS = 24

    def __init__(self, sample_rate: int, hop: int, n_bins: int) -> None:
        dt = hop / sample_rate
        self._ks = _coef(2.0, dt)
        self._kl = _coef(30.0, dt)
        self._kspec_s = _coef(2.0, dt)
        self._kspec_l = _coef(16.0, dt)
        edges = np.unique(np.geomspace(1, n_bins - 1, self.N_BANDS + 1).astype(int))
        self._edges = edges
        self._spec_s: Samples | None = None
        self._spec_l: Samples | None = None
        self._novelty_norm = RangeNorm(30.0, dt, 0.02)
        self.out = SlowFeatures()

    def process(self, fast: FastFeatures, mag: Samples) -> SlowFeatures:
        s = self.out
        s.energy_short += self._ks * (fast.level - s.energy_short)
        s.energy_long += self._kl * (fast.level - s.energy_long)
        s.energy_trend = s.energy_short - s.energy_long
        bands = np.log1p(np.add.reduceat(mag, self._edges[:-1])).astype(np.float32)
        if self._spec_s is None or self._spec_l is None:
            self._spec_s = bands.copy()
            self._spec_l = bands.copy()
        self._spec_s += self._kspec_s * (bands - self._spec_s)
        self._spec_l += self._kspec_l * (bands - self._spec_l)
        num = float(np.dot(self._spec_s, self._spec_l))
        den = float(np.linalg.norm(self._spec_s) * np.linalg.norm(self._spec_l)) + 1e-12
        s.novelty = self._novelty_norm(1.0 - num / den)
        return s
