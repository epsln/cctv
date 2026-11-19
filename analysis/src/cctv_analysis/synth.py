"""Synthetic test signals with known tempo and downbeats."""

from __future__ import annotations

import numpy as np

from .pcm import PcmBlock, Samples


def kick(sr: int, length_s: float = 0.15, f0: float = 120.0, f1: float = 45.0) -> Samples:
    n = int(sr * length_s)
    t = np.arange(n) / sr
    freq = f1 + (f0 - f1) * np.exp(-t / 0.03)
    phase = 2 * np.pi * np.cumsum(freq) / sr
    return (np.sin(phase) * np.exp(-t / 0.05)).astype(np.float32)


def hat(sr: int, length_s: float = 0.03, seed: int = 0) -> Samples:
    n = int(sr * length_s)
    rng = np.random.default_rng(seed)
    noise = rng.standard_normal(n).astype(np.float32)
    noise = np.diff(noise, prepend=0.0).astype(np.float32)  # crude high-pass
    return (noise * np.exp(-np.arange(n) / (sr * 0.008)) * 0.3).astype(np.float32)


def beat_track(
    sr: int,
    bpm: float,
    duration_s: float,
    offset_s: float = 0.0,
    beats_per_bar: int = 4,
    downbeat_gain: float = 1.0,
    other_gain: float = 0.5,
    hats: bool = True,
) -> Samples:
    """Kick on every beat (louder on downbeats), offbeat hats. Beat 0 at ``offset_s``."""
    y = np.zeros(int(sr * duration_s), np.float32)
    k = kick(sr)
    h = hat(sr)
    period = 60.0 / bpm
    i = 0
    while True:
        t = offset_s + i * period
        if t >= duration_s:
            break
        g = downbeat_gain if i % beats_per_bar == 0 else other_gain
        _add(y, k * g, int(t * sr))
        if hats:
            _add(y, h, int((t + period / 2) * sr))
        i += 1
    return y


def _add(y: Samples, x: Samples, at: int) -> None:
    if at >= len(y):
        return
    n = min(len(x), len(y) - at)
    y[at : at + n] += x[:n]


def blocks(y: Samples, sr: int, hop: int = 512) -> list[PcmBlock]:
    """Split ``y`` into external-clock blocks (t_mono = stream time)."""
    return [
        PcmBlock(np.ascontiguousarray(y[i : i + hop]), i, sr, i / sr)
        for i in range(0, len(y) - hop + 1, hop)
    ]
