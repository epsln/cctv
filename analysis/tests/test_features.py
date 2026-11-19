import numpy as np

from cctv_analysis.features import Envelope, FastAnalyser, RangeNorm

SR = 48000
HOP = 512


def run(y: np.ndarray) -> FastAnalyser:
    fa = FastAnalyser(SR, HOP)
    for i in range(0, len(y) - HOP + 1, HOP):
        fa.process(y[i : i + HOP])
    return fa


def tone(freq: float, seconds: float, amp: float = 0.5) -> np.ndarray:
    t = np.arange(int(SR * seconds)) / SR
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def test_bands_follow_spectrum() -> None:
    # Quiet then loud: the loud band rises to the top of its recent range.
    fa = run(np.concatenate([tone(60, 2, 0.01), tone(60, 1, 0.5)]))
    assert fa.out.bass > 0.8
    assert fa.out.bass_amp > 0
    fa = run(np.concatenate([tone(5000, 2, 0.01), tone(5000, 1, 0.5)]))
    assert fa.out.high > 0.8


def test_silence() -> None:
    fa = run(np.zeros(SR, np.float32))
    assert fa.out.silent and fa.out.bass == 0.0 and not fa.out.onset


def test_onsets_and_density() -> None:
    y = np.zeros(SR * 4, np.float32)
    rng = np.random.default_rng(0)
    for k in range(16):  # 4 per second
        at = int(k * SR / 4)
        y[at : at + 400] = rng.standard_normal(400).astype(np.float32) * 0.5
    fa = FastAnalyser(SR, HOP)
    onsets = 0
    for i in range(0, len(y) - HOP + 1, HOP):
        onsets += fa.process(y[i : i + HOP]).onset
    assert 12 <= onsets <= 17
    assert 2.0 < fa.out.transient_density < 6.0


def test_wrong_block_size_rejected() -> None:
    fa = FastAnalyser(SR, HOP)
    try:
        fa.process(np.zeros(100, np.float32))
    except ValueError:
        return
    raise AssertionError("expected ValueError")


def test_range_norm_and_envelope() -> None:
    n = RangeNorm(1.0, 0.01, 1.0)
    assert n(0.0) == 1.0  # first value is its own peak
    assert n(10.0) == 1.0
    assert n(0.0) == 0.0
    e = Envelope(0.0, 1.0, 0.01)
    assert e(1.0) == 1.0
    assert 0.98 < e(0.0) < 1.0
