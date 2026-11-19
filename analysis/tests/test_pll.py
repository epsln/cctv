import math

import numpy as np

from cctv_analysis.beat import BeatPll, fold_bpm


def feed(pll: BeatPll, times: list[float], bpm: float) -> None:
    for t in times:
        pll.observe(t, bpm)


def test_fold_bpm() -> None:
    assert fold_bpm(63.0) == 126.0
    assert fold_bpm(252.0) == 126.0
    assert fold_bpm(126.0) == 126.0


def test_locks_after_three_consistent_detections() -> None:
    pll = BeatPll()
    feed(pll, [0.0, 0.5], 120.0)
    assert not pll.state.locked
    pll.observe(1.0, 120.0)
    assert pll.state.locked
    assert math.isclose(pll.position(1.25), 0.5)


def test_tracks_jittered_beats_and_corrects_tempo() -> None:
    rng = np.random.default_rng(1)
    true_period = 60 / 124.0
    times = [i * true_period + rng.normal(0, 0.008) for i in range(64)]
    pll = BeatPll()
    feed(pll, times, 126.0)  # detector tempo hint slightly off
    assert pll.state.locked
    assert abs(pll.state.bpm - 124.0) < 0.5
    t = 64 * true_period
    err = pll.position(t) - round(pll.position(t))
    assert abs(err) < 0.05
    assert pll.state.confidence > 0.5


def test_ignores_isolated_outliers() -> None:
    pll = BeatPll()
    times = [i * 0.5 for i in range(16)]
    times.insert(8, 3.77)  # spurious detection between beats
    feed(pll, times, 120.0)
    assert pll.state.discontinuities == 0
    assert abs(pll.position(8.0) - round(pll.position(8.0))) < 0.02


def test_new_track_reacquired_with_continuous_count() -> None:
    pll = BeatPll()
    feed(pll, [i * 0.5 for i in range(16)], 120.0)
    before = pll.position(7.5)
    # New track: 128 BPM, phase shifted by ~0.4 beat.
    p2 = 60 / 128.0
    last = 7.7 + 31 * p2
    feed(pll, [7.7 + i * p2 for i in range(32)], 128.0)
    assert abs(pll.state.bpm - 128.0) < 1.0
    pos = pll.position(last)
    assert abs(pos - round(pos)) < 0.05
    # The beat count advanced by roughly the elapsed beats; it did not restart at 0.
    assert pos > before + 28


def test_phase_jump_forces_relock() -> None:
    pll = BeatPll()
    feed(pll, [i * 0.5 for i in range(16)], 120.0)
    feed(pll, [7.75 + i * 0.5 for i in range(12)], 120.0)  # same tempo, half-beat shift
    assert pll.state.discontinuities == 1
    assert abs(pll.position(13.25) - round(pll.position(13.25))) < 0.02


def test_confidence_decays_without_detections() -> None:
    pll = BeatPll()
    feed(pll, [i * 0.5 for i in range(16)], 120.0)
    c = pll.state.confidence
    for k in range(2000):
        pll.tick(7.5 + k * 0.01)
    assert pll.state.confidence < 0.1 < c


def test_follows_small_tempo_drift_without_relock() -> None:
    """A pitch-fader move (+2 %) is tracked by the loop, not by a re-lock."""
    pll = BeatPll()
    feed(pll, [i * 0.5 for i in range(16)], 120.0)
    p2 = 0.5 / 1.02
    feed(pll, [7.5 + i * p2 for i in range(1, 48)], 122.4)
    assert pll.state.discontinuities == 0
    assert abs(pll.state.bpm - 122.4) < 0.5


def test_hint_relock_is_optional() -> None:
    pll = BeatPll(hint_relock_after=4)
    feed(pll, [i * 0.5 for i in range(16)], 120.0)
    feed(pll, [8.0 + i * 0.5 for i in range(6)], 100.0)  # unrelated hint, same beats
    assert pll.state.discontinuities == 0  # 3 consistent beats at 100 BPM needed: not met
