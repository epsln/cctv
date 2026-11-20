import math

import numpy as np
import pytest

from cctv_analysis.analyser import Analyser
from cctv_analysis.beat import DownbeatEstimator
from cctv_analysis.state import MusicalState
from cctv_analysis.synth import beat_track, blocks

SR = 48000


def analyse(y: np.ndarray) -> list[MusicalState]:
    a = Analyser(SR, realtime=False)
    return [a.process(b) for b in blocks(y, SR)]


def phase_errors_ms(states: list[MusicalState], bpm: float, offset: float) -> np.ndarray:
    out = []
    for s in states[len(states) // 2 :]:
        assert not math.isnan(s.beat_position)
        e = s.beat_position - (s.t_audio - offset) * bpm / 60
        out.append(((e + 0.5) % 1 - 0.5) * 60 / bpm * 1000)
    return np.array(out)


@pytest.mark.parametrize("bpm", [118.0, 126.0, 135.0])
def test_tracks_tempo_and_phase(bpm: float) -> None:
    states = analyse(beat_track(SR, bpm, 40.0, 0.3))
    last = states[-1]
    assert last.timing_source == "audio"
    assert abs(last.bpm - bpm) < 1.0
    err = phase_errors_ms(states, bpm, 0.3)
    assert abs(err.mean()) < 15 and err.std() < 15
    assert last.beat_confidence > 0.5


def test_not_fooled_by_offbeat_hats() -> None:
    y = beat_track(SR, 126.0, 40.0, 0.3, hats=True)
    y += beat_track(SR, 126.0, 40.0, 0.3 + 60 / 126 / 2, hats=False, downbeat_gain=0, other_gain=0)
    err = phase_errors_ms(analyse(y), 126.0, 0.3)
    assert abs(err.mean()) < 15


def test_downbeat_estimate_matches_louder_kick() -> None:
    bpm, off = 126.0, 0.3
    a = Analyser(SR, realtime=False)
    a.bar = DownbeatEstimator(w_bass=1.0, w_novelty=0.0)
    y = beat_track(SR, bpm, 40.0, off, downbeat_gain=1.0, other_gain=0.5)
    states = [a.process(b) for b in blocks(y, SR)]
    s = states[-1]
    assert s.bar_source == "estimate" and s.bar_confidence > 0.5
    true_index_offset = round(s.beat_position - (s.t_audio - off) * bpm / 60)
    assert s.downbeat == true_index_offset % 4


def test_bass_cue_unknown_with_uniform_kicks() -> None:
    """With equal kicks the bass cue carries no bar information.

    (The default novelty cue is not tested here: on a perfectly static
    synthetic loop, the beat/block-grid alignment alone creates a periodic
    spectral difference, see docs/beat-evaluation.md. MusicalClock does not use
    estimates unless auto_bar_alignment is enabled.)"""
    a = Analyser(SR, realtime=False)
    a.bar = DownbeatEstimator(w_bass=1.0, w_novelty=0.0)
    for b in blocks(beat_track(SR, 126.0, 30.0, 0.3, downbeat_gain=1.0, other_gain=1.0), SR):
        s = a.process(b)
    assert s.bar_confidence < 0.3


def test_silence_has_no_timing() -> None:
    states = analyse(np.zeros(SR * 5, np.float32))
    assert all(s.timing_source == "none" and s.silent for s in states)
    assert all(math.isnan(s.beat_position) for s in states)


def test_manual_bar_alignment_overrides_estimate() -> None:
    d = DownbeatEstimator()
    d.align(6)
    s = d.process(10.1, 1.0)
    assert (s.downbeat, s.source, s.confidence) == (2, "manual", 1.0)
    d.clear_manual()
    assert d.process(10.2, 1.0).source == "none"
