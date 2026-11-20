from pathlib import Path

import numpy as np
import pytest

from cctv_analysis.evaluate import (
    Reference,
    causal_estimate,
    evaluate_track,
    format_table,
    load_annotation,
    signed_offsets,
    tempo_agreement,
)
from cctv_analysis.state import MusicalState

pytest.importorskip("mir_eval")


def test_signed_offsets() -> None:
    ref = np.arange(0, 10, 0.5)
    est = ref[2:10] + 0.02
    assert np.allclose(signed_offsets(ref, est), 0.02)
    # Off-beat estimates are excluded (beyond a quarter beat).
    assert len(signed_offsets(ref, ref[2:10] + 0.25)) == 0


def test_causal_estimate_beat_crossings_and_downbeats() -> None:
    states = []
    for i in range(200):
        t = i * 0.01
        states.append(
            MusicalState(
                i,
                t,
                t,
                0,
                48000,
                "external",
                timing_source="audio",
                bpm=120.0,
                beat_position=t * 2.0,
                beat_confidence=0.9,
                downbeat=0,
                bar_confidence=0.9,
            )
        )
    e = causal_estimate(states, offset_s=10.0)
    assert np.allclose(e.beats, 10.0 + np.array([0.5, 1.0, 1.5]))
    assert len(e.downbeats) == 0  # positions 1, 2, 3: none starts a bar (downbeat 0)
    assert e.first_lock_s == 10.0


def test_tempo_agreement_octave() -> None:
    ref = np.arange(0, 20, 0.5)
    states = [
        MusicalState(i, i * 0.1, 0, 0, 48000, "external", bpm=240.0, beat_position=i * 0.4)
        for i in range(100)
    ]
    e = causal_estimate(states)
    t = tempo_agreement(ref, e)
    assert t["tempo_ok"] == 0.0 and t["tempo_ok_octave"] == 1.0


def test_annotation_file(tmp_path: Path) -> None:
    audio = tmp_path / "a.wav"
    audio.write_bytes(b"")
    (tmp_path / "a.wav.beats").write_text("# t pos\n0.5 1\n1.0 2\n1.5 3\n2.0 4\n2.5 1\n")
    r = load_annotation(audio)
    assert r is not None and list(r.downbeats) == [0.5, 2.5]


def test_evaluate_synthetic_against_truth(wav_126: Path) -> None:
    period = 60 / 126
    beats = 0.3 + np.arange(42, dtype=np.float64) * period
    ref = Reference(beats, beats[::4], "truth")
    r = evaluate_track(wav_126, duration_s=None, reference=ref)
    assert r.f_measure > 0.8 and r.tempo_ok > 0.95
    assert abs(r.offset_ms_median) < 15
    assert "MEAN" in format_table([r])
