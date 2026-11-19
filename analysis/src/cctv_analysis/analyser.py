"""The analysis pipeline: one ``PcmBlock`` in, one ``MusicalState`` out."""

from __future__ import annotations

import time
from collections.abc import Iterable, Iterator
from typing import Protocol

from .beat import MAX_BPM, MIN_BPM, BeatTracker, DownbeatEstimator
from .comb import CombBeatTracker
from .features import FastAnalyser, SlowAnalyser
from .pcm import PcmBlock, PcmSource
from .state import MusicalState


class Sink(Protocol):
    def send(self, state: MusicalState) -> None: ...

    def close(self) -> None: ...


class Analyser:
    def __init__(
        self,
        sample_rate: int,
        hop: int = 512,
        beats_per_bar: int = 4,
        realtime: bool = True,
        slow_every_s: float = 0.5,
        bpm_range: tuple[float, float] = (MIN_BPM, MAX_BPM),
        tracker: str = "comb",
    ) -> None:
        self.sr = sample_rate
        self.hop = hop
        self.realtime = realtime
        self.fast = FastAnalyser(sample_rate, hop)
        self.slow = SlowAnalyser(sample_rate, hop, len(self.fast.mag))
        self.beat: BeatTracker | CombBeatTracker
        if tracker == "comb":
            self.beat = CombBeatTracker(sample_rate, hop, len(self.fast.mag), bpm_range=bpm_range)
        elif tracker == "aubio":
            self.beat = BeatTracker(sample_rate, hop, bpm_range=bpm_range)
        else:
            raise ValueError(f"unknown tracker {tracker!r}")
        self.bar = DownbeatEstimator(beats_per_bar)
        self.bpb = beats_per_bar
        self._slow_every = max(1, round(slow_every_s * sample_rate / hop))
        self._n = 0
        self._seq = 0
        self._slow_snapshot = self.slow.out
        self.overruns = 0

    def process(self, block: PcmBlock) -> MusicalState:
        t_start = time.perf_counter()
        f = self.fast.process(block.samples)
        s = self.slow.process(f, self.fast.mag)
        if self._n % self._slow_every == 0:  # slow values are published at a low rate
            self._slow_snapshot = type(s)(s.energy_short, s.energy_long, s.energy_trend, s.novelty)
        self._n += 1
        if isinstance(self.beat, CombBeatTracker):
            b = self.beat.process(
                block.samples, block.sample_index, block.t_mono, f.silent, self.fast.mag
            )
        else:
            b = self.beat.process(block.samples, block.sample_index, block.t_mono, f.silent)
        t = block.t_end
        pos = self.beat.pll.position(t)
        if b.discontinuity and self.bar.manual is None:
            self.bar.reset()
        bar = self.bar.process(pos, f.bass_amp, self.slow.bands)
        ss = self._slow_snapshot
        self._seq += 1
        return MusicalState(
            seq=self._seq,
            t_audio=t,
            t_sent=time.monotonic() if self.realtime else t,
            sample_index=block.sample_index + len(block.samples),
            sample_rate=self.sr,
            clock="realtime" if self.realtime else "external",
            timing_source="audio" if b.locked else "none",
            bpm=b.bpm,
            beat_position=pos,
            beat_confidence=b.confidence,
            beats_per_bar=self.bpb,
            downbeat=bar.downbeat,
            bar_confidence=bar.confidence,
            bar_source=bar.source,
            discontinuity=b.discontinuity,
            bass=f.bass,
            mid=f.mid,
            high=f.high,
            level=f.level,
            onset=f.onset,
            onset_envelope=f.onset_envelope,
            onset_strength=f.onset_strength,
            transient_density=f.transient_density,
            spectral_change=f.spectral_change,
            silent=f.silent,
            energy_short=ss.energy_short,
            energy_long=ss.energy_long,
            energy_trend=ss.energy_trend,
            novelty=ss.novelty,
            overruns=self.overruns,
            analysis_ms=(time.perf_counter() - t_start) * 1000.0,
        )

    def run(self, blocks: Iterable[PcmBlock]) -> Iterator[MusicalState]:
        for block in blocks:
            yield self.process(block)


def run_source(
    source: PcmSource,
    sinks: list[Sink],
    hop: int = 512,
    bpm_range: tuple[float, float] = (MIN_BPM, MAX_BPM),
    tracker: str = "comb",
) -> Analyser:
    """Analyse ``source`` until exhausted (or interrupted), publishing every state."""
    a = Analyser(
        source.sample_rate, hop, realtime=source.realtime, bpm_range=bpm_range, tracker=tracker
    )
    try:
        for block in source.blocks():
            a.overruns = source.stats.overruns
            st = a.process(block)
            for sink in sinks:
                sink.send(st)
    finally:
        source.close()
        for sink in sinks:
            sink.close()
    return a
