import json
import math
import socket
import time
from pathlib import Path

import pytest

from cctv_analysis.analyser import Analyser
from cctv_analysis.cli import main
from cctv_analysis.pcm import FilePcmSource
from cctv_analysis.state import SCHEMA_VERSION, MusicalState
from cctv_analysis.transport import UdpPublisher, encode, parse_addr


def test_state_json_has_no_nan() -> None:
    d = json.loads(encode(MusicalState(1, 0.5, 0.5, 100, 48000, "external")))
    assert d["v"] == SCHEMA_VERSION
    assert d["beat_position"] is None
    assert "extra" not in d


def test_parse_addr() -> None:
    assert parse_addr("127.0.0.1:1234") == ("127.0.0.1", 1234)
    assert parse_addr(":99") == ("127.0.0.1", 99)


def test_udp_roundtrip() -> None:
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(("127.0.0.1", 0))
    rx.settimeout(1.0)
    pub = UdpPublisher(rx.getsockname())
    pub.send(MusicalState(7, 1.0, 1.0, 0, 48000, "realtime", bpm=126.0))
    d = json.loads(rx.recv(65536))
    assert d["seq"] == 7 and d["bpm"] == 126.0
    pub.close()
    rx.close()


def test_udp_without_receiver_does_not_raise() -> None:
    pub = UdpPublisher(("127.0.0.1", 9))
    for _ in range(10):
        pub.send(MusicalState(1, 0.0, 0.0, 0, 48000, "realtime"))
    pub.close()


def test_file_source_blocks(wav_126: Path) -> None:
    src = FilePcmSource(wav_126, 512, start_s=1.0, duration_s=2.0)
    bl = list(src.blocks())
    assert all(len(b.samples) == 512 and b.samples.ndim == 1 for b in bl)
    assert bl[0].t_mono == 0.0 and bl[1].sample_index == 512
    assert len(bl) == math.ceil(2.0 * 48000 / 512)


def test_realtime_matches_external_clock(wav_126: Path) -> None:
    """Live-paced and externally clocked runs yield the same features (parity)."""
    dur = 1.5
    ext = [Analyser(48000, realtime=False)]
    rt = [Analyser(48000, realtime=True)]
    se = [ext[0].process(b) for b in FilePcmSource(wav_126, duration_s=dur).blocks()]
    t0 = time.monotonic()
    sr = [rt[0].process(b) for b in FilePcmSource(wav_126, realtime=True, duration_s=dur).blocks()]
    assert time.monotonic() - t0 == pytest.approx(dur, abs=0.15)
    assert len(se) == len(sr)
    for a, b in zip(se, sr, strict=True):
        assert a.bass == b.bass and a.onset == b.onset and a.sample_index == b.sample_index
        # Timestamps differ only by the run's start time.
        assert b.t_audio - a.t_audio == pytest.approx(sr[0].t_audio - se[0].t_audio, abs=0.02)


def test_cli_records_jsonl(
    wav_126: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    out = tmp_path / "states.jsonl"
    assert main(["file", str(wav_126), "--udp", "off", "--record", str(out)]) == 0
    lines = out.read_text().splitlines()
    header = json.loads(lines[0])["header"]
    assert header["source"] == "file" and header["sample_rate"] == 48000
    last = json.loads(lines[-1])
    assert last["timing_source"] == "audio" and abs(last["bpm"] - 126) < 1
    assert "bpm=" in capsys.readouterr().err
