import math

import numpy as np
import pytest

from cctv_analysis.analyser import Analyser
from cctv_analysis.comb import CombEstimate, PhaseFollower
from cctv_analysis.evaluate import causal_estimate, signed_offsets
from cctv_analysis.synth import beat_track, blocks

SR = 48000


@pytest.mark.parametrize(
    ("bpm", "hats"), [(95.0, True), (126.0, True), (150.0, False), (174.0, False)]
)
def test_phase_and_tempo_against_truth(bpm: float, hats: bool) -> None:
    """Calibrates CombParams.bias_s: beats within ~12 ms of the true onsets."""
    y = beat_track(SR, bpm, 40.0, 0.3, hats=hats)
    a = Analyser(SR, realtime=False, tracker="comb")
    e = causal_estimate(a.process(b) for b in blocks(y, SR))
    ref = 0.3 + np.arange(400, dtype=np.float64) * 60.0 / bpm
    off = signed_offsets(ref[ref < 40], e.beats[e.beats > 10]) * 1000
    assert len(off) > 0.9 * len(e.beats[e.beats > 10])
    assert abs(np.median(off)) < 12 and np.std(off) < 6
    assert abs(e.bpm[-1] - bpm) < 0.3
    assert e.relocks == 0


def _est(t: float, period: float, beat: float, sal: float = 0.5) -> CombEstimate:
    return CombEstimate(t, period, beat, sal)


def test_follower_hysteresis() -> None:
    f = PhaseFollower(switch_after=4)
    for i in range(8):
        f.observe(_est(i * 0.5, 0.5, i * 0.5))
    # A few off-beat estimates do not flip the phase...
    for i in range(3):
        f.observe(_est(4 + i * 0.5, 0.5, 4.25 + i * 0.5))
    assert f.state.discontinuities == 0
    assert abs(f.position(6.0) - round(f.position(6.0))) < 0.05
    # ...a persistent one does, keeping the count continuous.
    before = f.position(7.0)
    for i in range(4):
        f.observe(_est(7 + i * 0.5, 0.5, 7.25 + i * 0.5))
    assert f.state.discontinuities == 1
    p = f.position(8.75)
    assert abs(p - round(p)) < 0.05 and p > before


def test_follower_ignores_weak_estimates() -> None:
    f = PhaseFollower()
    f.observe(_est(0.0, 0.5, 0.0, sal=0.05))
    assert not f.state.locked and math.isnan(f.position(1.0))
