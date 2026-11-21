"""Link per-frame face detections into tracks (no identity recognition).

Detections are boxes ``[x, y, w, h]`` normalised to the source frame. Tracks
are formed by greedy IoU matching between consecutive samples; a track ends
when it has not been matched for ``max_gap`` seconds. Track IDs are arbitrary
per-asset integers and carry no identity information across assets.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

Box = tuple[float, float, float, float]


def iou(a: Box, b: Box) -> float:
    ax2, ay2 = a[0] + a[2], a[1] + a[3]
    bx2, by2 = b[0] + b[2], b[1] + b[3]
    iw = max(0.0, min(ax2, bx2) - max(a[0], b[0]))
    ih = max(0.0, min(ay2, by2) - max(a[1], b[1]))
    inter = iw * ih
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0.0


@dataclass
class Track:
    id: int
    samples: list[dict[str, Any]] = field(default_factory=list)

    @property
    def last_t(self) -> float:
        return float(self.samples[-1]["t"])

    @property
    def last_box(self) -> Box:
        b = self.samples[-1]["box"]
        return (b[0], b[1], b[2], b[3])


@dataclass
class Tracker:
    iou_threshold: float = 0.3
    max_gap: float = 1.0
    min_samples: int = 3
    _open: list[Track] = field(default_factory=list)
    _done: list[Track] = field(default_factory=list)
    _next_id: int = 1

    def add(self, t: float, detections: list[tuple[Box, float]]) -> None:
        """Add the detections of one sampled frame at time ``t`` (ascending)."""
        still_open = []
        for tr in self._open:
            if t - tr.last_t > self.max_gap:
                self._done.append(tr)
            else:
                still_open.append(tr)
        self._open = still_open
        pairs = sorted(
            (
                (iou(tr.last_box, box), ti, di)
                for ti, tr in enumerate(self._open)
                for di, (box, _) in enumerate(detections)
            ),
            reverse=True,
        )
        used_t: set[int] = set()
        used_d: set[int] = set()
        for score, ti, di in pairs:
            if score < self.iou_threshold:
                break
            if ti in used_t or di in used_d:
                continue
            used_t.add(ti)
            used_d.add(di)
            self._open[ti].samples.append(_sample(t, *detections[di]))
        for di, (box, conf) in enumerate(detections):
            if di not in used_d:
                self._open.append(Track(self._next_id, [_sample(t, box, conf)]))
                self._next_id += 1

    def finish(self) -> list[dict[str, Any]]:
        """Close all tracks; returns tracks with at least ``min_samples``, renumbered 1..n."""
        tracks = [t for t in self._done + self._open if len(t.samples) >= self.min_samples]
        tracks.sort(key=lambda tr: (tr.samples[0]["t"], tr.id))
        return [{"id": i + 1, "samples": tr.samples} for i, tr in enumerate(tracks)]


def _sample(t: float, box: Box, conf: float) -> dict[str, Any]:
    return {
        "t": round(t, 3),
        "box": [round(v, 4) for v in box],
        "conf": round(conf, 3),
    }
