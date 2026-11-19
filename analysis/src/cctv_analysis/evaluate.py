"""Offline evaluation of the causal beat/bar tracker against reference beats.

Reference beats and downbeats come from madmom's offline RNN + DBN downbeat
tracker (or from hand annotations next to the audio file). They are used **only**
to score the causal analyser. They are never published as musical state and
never become policy observations (docs/05-mixxx-and-audio.md, "Train/live
parity").

Requires the ``eval`` dependency group: ``uv sync --group eval``.

    uv run --group eval cctv-evaluate TRACK... [--list FILE] [--duration 240]
        [--json out.json] [--cache DIR]
"""

from __future__ import annotations

import argparse
import functools
import hashlib
import json
import math
import multiprocessing
import os
import sys
from collections.abc import Iterable, Sequence
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from .analyser import Analyser
from .beat import MAX_BPM, MIN_BPM
from .pcm import FilePcmSource
from .state import MusicalState

F64 = npt.NDArray[np.float64]

#: Beat-tracking tolerance window (s), the MIREX/mir_eval standard.
WINDOW = 0.07
#: The runtime clock ignores external timing below this confidence
#: (MusicalClock.min_confidence) and uses bars at or above BAR_CONF.
CLOCK_CONF = 0.3
BAR_CONF = 0.5
DEFAULT_CACHE = Path.home() / ".cache" / "cctv" / "reference-beats"


# --- Reference ----------------------------------------------------------------


@dataclass
class Reference:
    beats: F64
    """Beat times (s) from the start of the file."""
    downbeats: F64
    source: str


def _cache_key(path: Path) -> str:
    st = path.stat()
    h = hashlib.sha1(f"{path.resolve()}|{st.st_size}|{int(st.st_mtime)}".encode())
    return h.hexdigest()[:16]


def load_annotation(path: Path) -> Reference | None:
    """Hand annotations: ``<audio>.beats`` (or ``.beats.txt``) with ``time [beat_in_bar]`` lines."""
    for cand in (path.with_suffix(path.suffix + ".beats"), path.with_suffix(".beats.txt")):
        if cand.exists():
            rows = [
                ln.split()
                for ln in cand.read_text().splitlines()
                if ln.strip() and not ln.startswith("#")
            ]
            t = np.array([float(r[0]) for r in rows])
            pos = [int(float(r[1])) if len(r) > 1 else 0 for r in rows]
            db = np.array([ti for ti, p in zip(t, pos, strict=True) if p == 1])
            return Reference(t, db, f"annotation:{cand.name}")
    return None


def madmom_reference(path: Path, cache: Path = DEFAULT_CACHE) -> Reference:
    """Offline (non-causal) downbeat tracking with madmom, cached per file."""
    cache.mkdir(parents=True, exist_ok=True)
    f = cache / f"{_cache_key(path)}.tsv"
    if not f.exists():
        import soundfile as sf
        from madmom.features.downbeats import (
            DBNDownBeatTrackingProcessor,
            RNNDownBeatProcessor,
        )

        y, sr = sf.read(str(path), dtype="float32", always_2d=True)
        mono = y.mean(axis=1)
        from madmom.audio.signal import Signal

        act = RNNDownBeatProcessor()(Signal(mono, sample_rate=sr))
        res = DBNDownBeatTrackingProcessor(beats_per_bar=[3, 4], fps=100)(act)
        np.savetxt(f, res, fmt="%.3f\t%d", header=f"madmom downbeats for {path}")
    res = np.atleast_2d(np.loadtxt(f))
    return Reference(res[:, 0], res[res[:, 1] == 1, 0], "madmom")


def reference_for(path: Path, cache: Path = DEFAULT_CACHE) -> Reference:
    return load_annotation(path) or madmom_reference(path, cache)


# --- Causal estimate ------------------------------------------------------------


@dataclass
class Estimate:
    beats: F64
    """Times (s, file time) at which the live clock's beat position crossed an integer."""
    confidence: F64
    downbeats: F64
    """Beats the analyser marked as bar starts while bar confidence >= BAR_CONF."""
    bpm_t: F64
    bpm: F64
    first_lock_s: float
    relocks: int
    bar_confident_ratio: float


def causal_estimate(states: Iterable[MusicalState], offset_s: float = 0.0) -> Estimate:
    """Beats as the runtime sees them: where the published beat position crosses integers.

    ``offset_s`` converts state time (stream time of the analysed excerpt) to file time.
    """
    beats: list[float] = []
    conf: list[float] = []
    downs: list[float] = []
    bpm_t: list[float] = []
    bpm: list[float] = []
    prev: MusicalState | None = None
    first_lock = math.inf
    relocks = 0
    n = 0
    bar_conf_n = 0
    for s in states:
        n += 1
        bar_conf_n += s.bar_confidence >= BAR_CONF
        if s.discontinuity:
            relocks += 1
        if not math.isnan(s.beat_position):
            first_lock = min(first_lock, s.t_audio + offset_s)
            bpm_t.append(s.t_audio + offset_s)
            bpm.append(s.bpm)
            if prev is not None and not math.isnan(prev.beat_position):
                k = math.floor(s.beat_position)
                if k > math.floor(prev.beat_position) and not s.discontinuity:
                    frac = (k - prev.beat_position) / (s.beat_position - prev.beat_position)
                    t = prev.t_audio + frac * (s.t_audio - prev.t_audio) + offset_s
                    beats.append(t)
                    conf.append(s.beat_confidence)
                    if (
                        s.bar_confidence >= BAR_CONF
                        and s.downbeat >= 0
                        and (k - s.downbeat) % s.beats_per_bar == 0
                    ):
                        downs.append(t)
        prev = s
    return Estimate(
        np.array(beats),
        np.array(conf),
        np.array(downs),
        np.array(bpm_t),
        np.array(bpm),
        first_lock,
        relocks,
        bar_conf_n / max(n, 1),
    )


# --- Metrics --------------------------------------------------------------------


def _matches(ref: F64, est: F64, window: float) -> npt.NDArray[np.bool_]:
    """For each estimated beat: is there a reference beat within ``window``?"""
    if len(ref) == 0 or len(est) == 0:
        return np.zeros(len(est), bool)
    idx = np.clip(np.searchsorted(ref, est), 1, len(ref) - 1)
    d = np.minimum(np.abs(est - ref[idx - 1]), np.abs(est - ref[idx]))
    return np.asarray(d <= window)


def signed_offsets(ref: F64, est: F64) -> F64:
    """est - nearest ref, for estimates within a quarter of the local beat period."""
    if len(ref) < 2 or len(est) == 0:
        return np.array([])
    idx = np.clip(np.searchsorted(ref, est), 1, len(ref) - 1)
    lo, hi = ref[idx - 1], ref[idx]
    near = np.where(np.abs(est - lo) < np.abs(est - hi), lo, hi)
    d = est - near
    ibi = hi - lo
    return np.asarray(d[np.abs(d) < 0.25 * ibi])


def tempo_agreement(ref: F64, est: Estimate) -> dict[str, float]:
    """Fraction of locked time with tempo within 4 % of the reference (and octave-tolerant)."""
    if len(ref) < 3 or len(est.bpm) == 0:
        return {"tempo_ok": 0.0, "tempo_ok_octave": 0.0}
    mids = (ref[1:] + ref[:-1]) / 2
    ref_bpm = 60.0 / np.diff(ref)
    inside = (est.bpm_t >= ref[0]) & (est.bpm_t <= ref[-1])
    if not inside.any():
        return {"tempo_ok": 0.0, "tempo_ok_octave": 0.0}
    rb = np.interp(est.bpm_t[inside], mids, ref_bpm)
    eb = est.bpm[inside]
    r = eb / rb
    ok = np.abs(r - 1) < 0.04
    octave = ok | (np.abs(r - 2) < 0.08) | (np.abs(r - 0.5) < 0.02)
    return {"tempo_ok": float(ok.mean()), "tempo_ok_octave": float(octave.mean())}


def f_measure(ref: F64, est: F64, window: float = WINDOW) -> float:
    import mir_eval

    if len(ref) == 0 and len(est) == 0:
        return 1.0
    if len(ref) == 0 or len(est) == 0:
        return 0.0
    return float(mir_eval.beat.f_measure(ref, est, window))


def continuity(ref: F64, est: F64) -> dict[str, float]:
    import mir_eval

    if len(ref) < 2 or len(est) < 2:
        return {"cmlt": 0.0, "amlt": 0.0}
    _cmlc, cmlt, _amlc, amlt = mir_eval.beat.continuity(ref, est)
    return {"cmlt": float(cmlt), "amlt": float(amlt)}


@dataclass
class TrackResult:
    path: str
    reference: str
    start_s: float
    duration_s: float
    ref_beats: int
    est_beats: int
    ref_bpm: float
    f_measure: float
    cmlt: float
    amlt: float
    confident_precision: float
    """Of beats emitted while confidence >= CLOCK_CONF (the clock follows them): share correct."""
    confident_coverage: float
    """Share of reference beats matched by a confident estimated beat."""
    offset_ms_median: float
    offset_ms_iqr: float
    tempo_ok: float
    tempo_ok_octave: float
    downbeat_f: float
    downbeat_precision: float
    bar_confident_ratio: float
    first_lock_s: float
    relocks: int
    extra: dict[str, Any] = field(default_factory=dict)


def evaluate_track(
    path: Path,
    start_s: float = 0.0,
    duration_s: float | None = 240.0,
    cache: Path = DEFAULT_CACHE,
    bpm_range: tuple[float, float] = (MIN_BPM, MAX_BPM),
    reference: Reference | None = None,
) -> TrackResult:
    ref_all = reference or reference_for(path, cache)
    src = FilePcmSource(path, start_s=start_s, duration_s=duration_s)
    an = Analyser(src.sample_rate, realtime=False, bpm_range=bpm_range)
    est = causal_estimate((an.process(b) for b in src.blocks()), offset_s=start_s)
    end = start_s + (src.stats.blocks * src.block_size / src.sample_rate)
    src.close()

    def crop(x: F64) -> F64:
        return x[(x >= start_s) & (x < end)]

    ref, ref_db = crop(ref_all.beats), crop(ref_all.downbeats)
    conf_mask = est.confidence >= CLOCK_CONF
    conf_beats = est.beats[conf_mask]
    conf_ok = _matches(ref, conf_beats, WINDOW)
    ref_hit = _matches(conf_beats, ref, WINDOW) if len(conf_beats) else np.zeros(len(ref), bool)
    off = signed_offsets(ref, est.beats) * 1000.0
    cont = continuity(ref, est.beats)
    tempo = tempo_agreement(ref, est)
    db_ok = _matches(ref_db, est.downbeats, WINDOW)
    return TrackResult(
        path=str(path),
        reference=ref_all.source,
        start_s=start_s,
        duration_s=end - start_s,
        ref_beats=len(ref),
        est_beats=len(est.beats),
        ref_bpm=float(60.0 / np.median(np.diff(ref))) if len(ref) > 2 else 0.0,
        f_measure=f_measure(ref, est.beats),
        cmlt=cont["cmlt"],
        amlt=cont["amlt"],
        confident_precision=float(conf_ok.mean()) if len(conf_ok) else 0.0,
        confident_coverage=float(ref_hit.mean()) if len(ref_hit) else 0.0,
        offset_ms_median=float(np.median(off)) if len(off) else math.nan,
        offset_ms_iqr=float(np.subtract(*np.percentile(off, [75, 25]))) if len(off) else math.nan,
        tempo_ok=tempo["tempo_ok"],
        tempo_ok_octave=tempo["tempo_ok_octave"],
        downbeat_f=f_measure(ref_db, est.downbeats),
        downbeat_precision=float(db_ok.mean()) if len(db_ok) else 0.0,
        bar_confident_ratio=est.bar_confident_ratio,
        first_lock_s=est.first_lock_s - start_s,
        relocks=est.relocks,
    )


# --- Reporting ------------------------------------------------------------------

COLUMNS = [
    ("f_measure", "F", "{:.2f}"),
    ("cmlt", "CMLt", "{:.2f}"),
    ("amlt", "AMLt", "{:.2f}"),
    ("confident_precision", "confP", "{:.2f}"),
    ("confident_coverage", "confCov", "{:.2f}"),
    ("offset_ms_median", "off ms", "{:+.0f}"),
    ("offset_ms_iqr", "iqr", "{:.0f}"),
    ("tempo_ok", "tempo", "{:.2f}"),
    ("tempo_ok_octave", "tempo8", "{:.2f}"),
    ("downbeat_f", "dbF", "{:.2f}"),
    ("downbeat_precision", "dbP", "{:.2f}"),
    ("bar_confident_ratio", "barCov", "{:.2f}"),
    ("first_lock_s", "lock s", "{:.1f}"),
    ("relocks", "relock", "{:d}"),
]


def summarize(results: Sequence[TrackResult]) -> dict[str, float]:
    out: dict[str, float] = {}
    for key, _, _ in COLUMNS:
        vals = [float(getattr(r, key)) for r in results]
        vals = [v for v in vals if not math.isnan(v) and not math.isinf(v)]
        out[key] = float(np.mean(vals)) if vals else math.nan
    return out


def format_table(results: Sequence[TrackResult]) -> str:
    head = f"{'track':34s} {'bpm':>5s} " + " ".join(f"{h:>7s}" for _, h, _ in COLUMNS)
    lines = [head]
    for r in results:
        name = Path(r.path).stem[:34]
        cells = []
        for key, _, fmt in COLUMNS:
            v = getattr(r, key)
            cells.append(
                f"{(fmt.format(v) if not (isinstance(v, float) and math.isnan(v)) else '-'):>7s}"
            )
        lines.append(f"{name:34s} {r.ref_bpm:5.1f} " + " ".join(cells))
    m = summarize(results)
    cells = []
    for key, _, fmt in COLUMNS:
        v = m[key]
        f = fmt.replace(":d", ":.1f")
        cells.append(f"{(f.format(v) if not math.isnan(v) else '-'):>7s}")
    lines.append(f"{'MEAN':34s} {'':5s} " + " ".join(cells))
    return "\n".join(lines)


def _evaluate_or_none(path: Path, **kw: Any) -> TrackResult | None:
    """Keep going when one file is unreadable."""
    print(f"... {path.name}", file=sys.stderr, flush=True)
    try:
        return evaluate_track(path, **kw)
    except Exception as e:
        print(f"    skipped {path.name}: {e}", file=sys.stderr)
        return None


def _paths(args: argparse.Namespace) -> list[Path]:
    paths = [Path(p) for p in args.tracks]
    if args.list:
        for ln in Path(args.list).read_text().splitlines():
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                paths.append(Path(ln).expanduser())
    return paths


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="cctv-evaluate", description=__doc__.split("\n\n")[0])
    p.add_argument("tracks", nargs="*")
    p.add_argument("--list", help="file with one audio path per line")
    p.add_argument("--start", type=float, default=0.0)
    p.add_argument("--duration", type=float, default=240.0, help="seconds per track (0 = all)")
    p.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    p.add_argument("--bpm-range", nargs=2, type=float, default=(MIN_BPM, MAX_BPM))
    p.add_argument("--json", help="write per-track results and summary here")
    p.add_argument("--jobs", type=int, default=os.cpu_count() or 1, help="parallel tracks")
    args = p.parse_args(argv)
    paths = _paths(args)
    if not paths:
        p.error("no tracks")
    job = functools.partial(
        _evaluate_or_none,
        start_s=args.start,
        duration_s=args.duration or None,
        cache=args.cache,
        bpm_range=tuple(args.bpm_range),
    )
    if args.jobs > 1 and len(paths) > 1:
        with multiprocessing.Pool(min(args.jobs, len(paths))) as pool:
            out = pool.map(job, paths)
    else:
        out = [job(p) for p in paths]
    results = [r for r in out if r is not None]
    print(format_table(results))
    if args.json:
        Path(args.json).write_text(
            json.dumps(
                {"tracks": [asdict(r) for r in results], "summary": summarize(results)},
                indent=1,
                default=float,
            )
        )
    return 0 if results else 1


if __name__ == "__main__":
    sys.exit(main())
