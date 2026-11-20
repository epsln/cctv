"""Versioned musical-state message (see docs/musical-state.md)."""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass, field
from typing import Any

SCHEMA_VERSION = 1
FEATURE_VERSION = "fast1-slow1-beat1"


def _r(x: float, nd: int = 5) -> float | None:
    return None if math.isnan(x) or math.isinf(x) else round(x, nd)


@dataclass(slots=True)
class MusicalState:
    seq: int
    t_audio: float
    """Monotonic time (s) of the analysed audio (end of the latest block). All
    musical values below describe this instant."""
    t_sent: float
    """Monotonic time (s) when the message was produced; receivers use it to map
    clocks and measure transport age."""
    sample_index: int
    sample_rate: int
    clock: str
    """``realtime`` (t_* are time.monotonic()) or ``external`` (stream time)."""

    # Timing
    timing_source: str = "none"
    """``audio``, ``mixxx`` or ``none``."""
    bpm: float = 0.0
    beat_position: float = math.nan
    """Continuous beat count at ``t_audio``; NaN when not locked."""
    beat_confidence: float = 0.0
    beats_per_bar: int = 4
    downbeat: int = -1
    """Beat index modulo ``beats_per_bar`` that starts a bar; -1 if unknown."""
    bar_confidence: float = 0.0
    bar_source: str = "none"
    discontinuity: bool = False
    """Tempo/phase re-acquired (new track, seek): don't slew, jump."""

    # Fast features (0..1 unless noted)
    bass: float = 0.0
    mid: float = 0.0
    high: float = 0.0
    level: float = 0.0
    onset: bool = False
    onset_envelope: float = 0.0
    onset_strength: float = 0.0
    transient_density: float = 0.0
    """Onsets per second."""
    spectral_change: float = 0.0
    silent: bool = True

    # Slow features
    energy_short: float = 0.0
    energy_long: float = 0.0
    energy_trend: float = 0.0
    novelty: float = 0.0

    # Health
    overruns: int = 0
    analysis_ms: float = 0.0
    """Processing time of the latest block."""
    extra: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        for k, v in d.items():
            if isinstance(v, float):
                d[k] = _r(v)
        d["v"] = SCHEMA_VERSION
        d["features"] = FEATURE_VERSION
        if not d["extra"]:
            del d["extra"]
        return d
