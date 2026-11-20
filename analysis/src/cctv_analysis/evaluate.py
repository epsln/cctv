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


CHUNK_S = 120.0
LONG_S = 600.0
CHUNK_PAD_S = 15.0


def _madmom_chunk(job: tuple[str, float, float]) -> F64:
    """Beats with bar positions in [start, end), decoded with CHUNK_PAD_S context."""
    import soundfile as sf
    from madmom.audio.signal import Signal
    from madmom.features.downbeats import DBNDownBeatTrackingProcessor, RNNDownBeatProcessor

    path, start, end = job
    info = sf.info(path)
    sr = int(info.samplerate)
    a = max(0.0, start - CHUNK_PAD_S)
    b = min(info.duration, end + CHUNK_PAD_S)
    y, _ = sf.read(path, start=int(a * sr), stop=int(b * sr), dtype="float32", always_2d=True)
    act = RNNDownBeatProcessor()(Signal(y.mean(axis=1), sample_rate=sr))
    res = np.atleast_2d(DBNDownBeatTrackingProcessor(beats_per_bar=[3, 4], fps=100)(act))
    if res.size == 0:
        return np.zeros((0, 2))
    res[:, 0] += a
    keep = (res[:, 0] >= start) & (res[:, 0] < end)
    return np.asarray(res[keep], dtype=np.float64)


def madmom_reference(path: Path, cache: Path = DEFAULT_CACHE) -> Reference:
    """Offline (non-causal) downbeat tracking with madmom, cached per file."""
    cache.mkdir(parents=True, exist_ok=True)
    f = cache / f"{_cache_key(path)}.tsv"
    if not f.exists():
        import soundfile as sf

        dur = sf.info(str(path)).duration
        starts = np.arange(0.0, dur, CHUNK_S)
        if dur <= LONG_S:
            res = _madmom_chunk((str(path), 0.0, dur))
        else:
            # Long recordings (DJ sets): independent overlapping chunks, in parallel.
            # Whole-file DBN decoding would need tens of GB for a 2 h set.
            jobs = [(str(path), float(s), float(min(s + CHUNK_S, dur))) for s in starts]
            with multiprocessing.Pool(min(len(jobs), max(1, (os.cpu_count() or 2) // 2))) as pool:
                parts = pool.map(_madmom_chunk, jobs)
            res = np.vstack([p for p in parts if len(p)])
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
    relock_t: F64 = field(default_factory=lambda: np.zeros(0))
    sample_t: F64 = field(default_factory=lambda: np.zeros(0))
    """Every 10th state: time, locked flag and bar-confident flag (for segment scoring)."""
    sample_locked: npt.NDArray[np.bool_] = field(default_factory=lambda: np.zeros(0, bool))
    sample_bar: npt.NDArray[np.bool_] = field(default_factory=lambda: np.zeros(0, bool))

    def window(self, a: float, b: float) -> Estimate:
        """The estimate restricted to [a, b)."""

        def m(t: F64) -> npt.NDArray[np.bool_]:
            return np.asarray((t >= a) & (t < b))

        bm, sm, tm = m(self.beats), m(self.sample_t), m(self.bpm_t)
        locked_t = self.sample_t[sm & self.sample_locked]
        return Estimate(
            self.beats[bm],
            self.confidence[bm],
            self.downbeats[m(self.downbeats)],
            self.bpm_t[tm],
            self.bpm[tm],
            float(locked_t[0]) if len(locked_t) else math.inf,
            int(m(self.relock_t).sum()),
            float(self.sample_bar[sm].mean()) if sm.any() else 0.0,
            self.relock_t[m(self.relock_t)],
            self.sample_t[sm],
            self.sample_locked[sm],
            self.sample_bar[sm],
        )


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
    relock_t: list[float] = []
    st: list[float] = []
    sl: list[bool] = []
    sb: list[bool] = []
    for s in states:
        if n % 10 == 0:
            st.append(s.t_audio + offset_s)
            sl.append(not math.isnan(s.beat_position) and s.beat_confidence >= CLOCK_CONF)
            sb.append(s.bar_confidence >= BAR_CONF)
        n += 1
        bar_conf_n += s.bar_confidence >= BAR_CONF
        if s.discontinuity:
            relocks += 1
            relock_t.append(s.t_audio + offset_s)
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
        np.array(relock_t),
        np.array(st),
        np.array(sl, bool),
        np.array(sb, bool),
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
    tracker: str = "comb",
) -> TrackResult:
    ref_all = reference or reference_for(path, cache)
    est, end = run_estimate(path, start_s, duration_s, bpm_range, tracker)
    return score(str(path), ref_all, est, start_s, end)


def run_estimate(
    path: Path,
    start_s: float = 0.0,
    duration_s: float | None = None,
    bpm_range: tuple[float, float] = (MIN_BPM, MAX_BPM),
    tracker: str = "comb",
) -> tuple[Estimate, float]:
    """Run the causal analyser over the file; returns the estimate and the end time."""
    src = FilePcmSource(path, start_s=start_s, duration_s=duration_s)
    an = Analyser(src.sample_rate, realtime=False, bpm_range=bpm_range, tracker=tracker)
    est = causal_estimate((an.process(b) for b in src.blocks()), offset_s=start_s)
    end = start_s + (src.stats.blocks * src.block_size / src.sample_rate)
    src.close()
    return est, end


def score(name: str, ref_all: Reference, est: Estimate, start_s: float, end: float) -> TrackResult:
    """Score ``est`` against ``ref_all`` on [start_s, end)."""
    est = est.window(start_s, end)

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
        path=name,
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


# --- DJ sets ---------------------------------------------------------------------

#: Seconds after a cue index counted as the transition (the incoming track is
#: started at the index and mixed in during the following bars).
TRANSITION_S = 60.0


@dataclass
class CueTrack:
    number: int
    title: str
    performer: str
    start_s: float


def parse_cue(path: Path) -> list[CueTrack]:
    """Track starts from a cue sheet (INDEX 01 mm:ss:ff, 75 frames/s; mm may exceed 59)."""
    tracks: list[CueTrack] = []
    cur: dict[str, Any] = {}
    for raw in path.read_text(errors="replace").splitlines():
        ln = raw.strip()
        if ln.startswith("TRACK"):
            cur = {"number": int(ln.split()[1])}
        elif ln.startswith("TITLE") and cur:
            cur["title"] = ln.partition(" ")[2].strip('"')
        elif ln.startswith("PERFORMER") and cur:
            cur["performer"] = ln.partition(" ")[2].strip('"')
        elif ln.startswith("INDEX 01") and cur:
            mm, ss, ff = (int(x) for x in ln.split()[2].split(":"))
            tracks.append(
                CueTrack(
                    cur["number"],
                    cur.get("title", ""),
                    cur.get("performer", ""),
                    mm * 60 + ss + ff / 75.0,
                )
            )
    return tracks


@dataclass
class SetResult:
    overall: TrackResult
    tracks: list[TrackResult]
    transitions: list[TrackResult]
    steady: list[TrackResult]


def evaluate_set(
    path: Path,
    cue: Path,
    cache: Path = DEFAULT_CACHE,
    bpm_range: tuple[float, float] = (MIN_BPM, MAX_BPM),
    tracker: str = "comb",
    duration_s: float | None = None,
) -> SetResult:
    """Score a whole recorded set once, then per cue track, in the first TRANSITION_S
    after each cue index, and in the steady part of each track."""
    ref = reference_for(path, cache)
    est, end = run_estimate(path, 0.0, duration_s, bpm_range, tracker)
    cues = [c for c in parse_cue(cue) if c.start_s < end]
    bounds = [c.start_s for c in cues] + [end]
    tracks, trans, steady = [], [], []
    for i, c in enumerate(cues):
        a, b = bounds[i], bounds[i + 1]
        name = f"{c.number:02d} {c.title}"
        tracks.append(score(name, ref, est, a, b))
        if i > 0:
            trans.append(score(name, ref, est, a, min(b, a + TRANSITION_S)))
        if b - (a + TRANSITION_S) > 30:
            steady.append(score(name, ref, est, a + TRANSITION_S, b))
    return SetResult(score(str(path), ref, est, 0.0, end), tracks, trans, steady)


# --- Listening check -------------------------------------------------------


def click_track(
    n: int, sr: int, beats: F64, downbeats: F64, freq: float = 1800.0, gain: float = 0.5
) -> npt.NDArray[np.float32]:
    """Short sine clicks on ``beats`` (seconds); downbeats are an octave lower and longer."""
    y = np.zeros(n, np.float32)
    down = set(np.round(downbeats, 3))
    for t in beats:
        is_down = round(float(t), 3) in down
        dur = 0.06 if is_down else 0.03
        f = freq / 2 if is_down else freq
        k = int(dur * sr)
        env = np.exp(-np.arange(k) / (k / 4)).astype(np.float32)
        c = np.sin(2 * np.pi * f * np.arange(k) / sr).astype(np.float32) * env * gain
        i = int(t * sr)
        if 0 <= i < n:
            m = min(k, n - i)
            y[i : i + m] += c[:m]
    return y


def render_clicks(
    path: Path,
    out_dir: Path,
    start_s: float = 60.0,
    duration_s: float = 30.0,
    cache: Path = DEFAULT_CACHE,
    tracker: str = "comb",
) -> list[Path]:
    """Write ``<stem>.ref.wav`` and ``<stem>.est.wav``: the excerpt with reference
    or causal-estimate clicks mixed in, for checking the reference by ear."""
    import soundfile as sf

    ref = reference_for(path, cache)
    # Analyse from a few seconds earlier so the tracker is locked in the excerpt.
    lead = min(start_s, 10.0)
    src = FilePcmSource(path, start_s=start_s - lead, duration_s=duration_s + lead)
    an = Analyser(src.sample_rate, realtime=False, tracker=tracker)
    est = causal_estimate((an.process(b) for b in src.blocks()), offset_s=start_s - lead)
    sr = src.sample_rate
    src.close()
    with sf.SoundFile(str(path)) as f:
        f.seek(int(start_s * sr))
        music = f.read(int(duration_s * sr), dtype="float32", always_2d=True).mean(axis=1)
    music *= 0.6 / max(1e-6, float(np.abs(music).max()))
    out_dir.mkdir(parents=True, exist_ok=True)
    outs = []
    for name, b, d in (("ref", ref.beats, ref.downbeats), ("est", est.beats, est.downbeats)):
        clicks = click_track(len(music), sr, b - start_s, d - start_s)
        o = out_dir / f"{path.stem[:60]}.{name}.wav"
        sf.write(str(o), np.stack([music, music + clicks], axis=1), sr)
        outs.append(o)
    return outs


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


def _row(r: TrackResult) -> dict[str, Any]:
    return asdict(r)


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
    p.add_argument(
        "--clicks",
        type=Path,
        metavar="DIR",
        help="instead of scoring, write 30 s excerpts (from --start, default 60 s) with "
        "reference and estimate clicks for listening checks",
    )
    p.add_argument("--cue", help="cue sheet of a recorded DJ set: score per track/transition")
    p.add_argument("--tracker", choices=["aubio", "comb"], default="comb")
    p.add_argument("--jobs", type=int, default=os.cpu_count() or 1, help="parallel tracks")
    args = p.parse_args(argv)
    paths = _paths(args)
    if not paths:
        p.error("no tracks")
    if args.cue:
        if len(paths) != 1:
            p.error("--cue needs exactly one recording")
        sr = evaluate_set(
            paths[0],
            Path(args.cue),
            args.cache,
            tuple(args.bpm_range),
            args.tracker,
            args.duration or None,
        )
        print("Per track:\n" + format_table(sr.tracks))
        for label, rows in (("transitions", sr.transitions), ("steady", sr.steady)):
            m = summarize(rows)
            print(
                f"\n{label} ({len(rows)} windows): "
                + "  ".join(f"{h}={m[k]:.2f}" for k, h, _ in COLUMNS)
            )
        print("\nWhole set:\n" + format_table([sr.overall]).splitlines()[1])
        if args.json:
            Path(args.json).write_text(
                json.dumps(
                    {
                        "overall": _row(sr.overall),
                        "tracks": [_row(r) for r in sr.tracks],
                        "transitions": [_row(r) for r in sr.transitions],
                        "steady": [_row(r) for r in sr.steady],
                    },
                    indent=1,
                    default=float,
                )
            )
        return 0
    if args.clicks:
        for path in paths:
            for o in render_clicks(
                path, args.clicks, args.start or 60.0, 30.0, args.cache, args.tracker
            ):
                print(o)
        return 0
    job = functools.partial(
        _evaluate_or_none,
        start_s=args.start,
        duration_s=args.duration or None,
        cache=args.cache,
        bpm_range=tuple(args.bpm_range),
        tracker=args.tracker,
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
