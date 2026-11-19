from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from cctv_analysis.synth import beat_track

SR = 48000


@pytest.fixture
def wav_126(tmp_path: Path) -> Path:
    """20 s, 126 BPM, beat 0 (a downbeat) at 0.3 s, stereo."""
    y = beat_track(SR, 126.0, 20.0, 0.3)
    p = tmp_path / "set.wav"
    sf.write(p, np.stack([y, y], axis=1) * 0.5, SR)
    return p
