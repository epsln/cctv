"""Common PCM interface for recorded files and live capture.

Every source yields mono float32 ``PcmBlock`` objects of a fixed size. Each block
carries the stream sample index of its first sample and the monotonic time
(``time.monotonic()``) at which that sample was audible at the capture point. The
analysis code is identical for all sources; only the timestamps differ:

- ``FilePcmSource(realtime=True)`` paces blocks against the monotonic clock
  (optionally playing them), so the output behaves like a live input.
- ``FilePcmSource(realtime=False)`` runs as fast as possible on an external
  clock: ``t_mono = sample_index / sample_rate``. Output is deterministic.
- ``LivePcmSource`` captures from PortAudio (the ``pipewire`` ALSA device on
  PipeWire systems), with a bounded queue that never blocks the audio thread.
"""

from __future__ import annotations

import os
import queue
import threading
import time
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

import numpy as np
import numpy.typing as npt

Samples = npt.NDArray[np.float32]


@dataclass(frozen=True, slots=True)
class PcmBlock:
    samples: Samples
    """Mono samples, shape ``(n,)``."""
    sample_index: int
    """Stream index of ``samples[0]``."""
    sample_rate: int
    t_mono: float
    """Monotonic time (s) at which ``samples[0]`` was audible."""

    @property
    def t_end(self) -> float:
        """Monotonic time just after the last sample of the block."""
        return self.t_mono + len(self.samples) / self.sample_rate


@dataclass(slots=True)
class SourceStats:
    blocks: int = 0
    overruns: int = 0
    """Blocks dropped because the consumer fell behind (live) or PortAudio overflows."""
    queue_depth: int = 0
    latency_s: float = 0.0
    """Estimated route/device latency included in timestamps."""


class PcmSource(Protocol):
    sample_rate: int
    block_size: int
    stats: SourceStats
    realtime: bool

    def blocks(self) -> Iterator[PcmBlock]: ...

    def close(self) -> None: ...


def to_mono(x: npt.NDArray[Any]) -> Samples:
    a = np.asarray(x, dtype=np.float32)
    if a.ndim == 2:
        a = a.mean(axis=1, dtype=np.float32)
    return np.ascontiguousarray(a, dtype=np.float32)


class FilePcmSource:
    """Read an audio file (anything libsndfile reads: WAV, FLAC, OGG, MP3...)."""

    def __init__(
        self,
        path: str | Path,
        block_size: int = 512,
        realtime: bool = False,
        play: bool = False,
        start_s: float = 0.0,
        duration_s: float | None = None,
    ) -> None:
        import soundfile as sf

        self._file = sf.SoundFile(str(path))
        self.sample_rate = int(self._file.samplerate)
        self.block_size = block_size
        self.realtime = realtime or play
        self.play = play
        self.stats = SourceStats()
        self._start = int(start_s * self.sample_rate)
        self._end = None if duration_s is None else self._start + int(duration_s * self.sample_rate)
        if self._start:
            self._file.seek(self._start)

    def blocks(self) -> Iterator[PcmBlock]:
        out = None
        if self.play:
            import sounddevice as sd

            out = sd.OutputStream(
                samplerate=self.sample_rate,
                channels=self._file.channels,
                blocksize=self.block_size,
                dtype="float32",
            )
            out.start()
            self.stats.latency_s = float(out.latency)
        idx = 0
        t0 = time.monotonic()
        try:
            for raw in self._file.blocks(
                blocksize=self.block_size, dtype="float32", always_2d=True
            ):
                if self._end is not None and self._start + idx >= self._end:
                    break
                if len(raw) < self.block_size:  # pad the tail so block size stays fixed
                    raw = np.vstack(
                        [raw, np.zeros((self.block_size - len(raw), raw.shape[1]), np.float32)]
                    )
                if out is not None:
                    t = time.monotonic() + float(out.latency)
                    out.write(raw)  # blocks: paces playback
                elif self.realtime:
                    t = t0 + idx / self.sample_rate
                    # A block is only complete once its last sample has happened.
                    delay = t + self.block_size / self.sample_rate - time.monotonic()
                    if delay > 0:
                        time.sleep(delay)
                else:
                    t = idx / self.sample_rate
                self.stats.blocks += 1
                yield PcmBlock(to_mono(raw), idx, self.sample_rate, t)
                idx += self.block_size
        finally:
            if out is not None:
                out.stop()
                out.close()

    def close(self) -> None:
        self._file.close()


class LivePcmSource:
    """Capture from a PortAudio input (default ``pipewire``; route Mixxx main into it).

    The audio callback only copies into a bounded queue. If the analyser falls
    behind, the newest block is dropped and counted as an overrun rather than
    blocking capture or growing latency.
    """

    def __init__(
        self,
        device: str | int | None = "pipewire",
        sample_rate: int = 48000,
        channels: int = 2,
        block_size: int = 512,
        queue_blocks: int = 32,
    ) -> None:
        self.device = device
        self.sample_rate = sample_rate
        self.channels = channels
        self.block_size = block_size
        self.realtime = True
        self.stats = SourceStats()
        self._q: queue.Queue[PcmBlock] = queue.Queue(maxsize=queue_blocks)
        self._idx = 0
        self._stop = threading.Event()
        self._stream: Any = None

    def _callback(self, indata: Any, frames: int, time_info: Any, status: Any) -> None:
        if status.input_overflow:
            self.stats.overruns += 1
        # Map PortAudio stream time to time.monotonic() (both are monotonic clocks).
        now = time.monotonic()
        t = now - (self._stream.time - time_info.inputBufferAdcTime)
        block = PcmBlock(to_mono(indata.copy()), self._idx, self.sample_rate, t)
        self._idx += frames
        try:
            self._q.put_nowait(block)
        except queue.Full:
            self.stats.overruns += 1

    def blocks(self) -> Iterator[PcmBlock]:
        ensure_pipewire_env()
        import sounddevice as sd

        try:
            self._stream = sd.InputStream(
                device=self.device,
                samplerate=self.sample_rate,
                channels=self.channels,
                blocksize=self.block_size,
                dtype="float32",
                latency="low",
                callback=self._callback,
            )
        except ValueError as e:
            raise RuntimeError(
                f"{e}.\nAvailable inputs (cctv-analyse devices):\n  "
                + "\n  ".join(list_input_devices())
                + "\nThe 'pipewire' device needs the pipewire-alsa package and a reachable "
                "PipeWire server (XDG_RUNTIME_DIR, currently "
                f"{os.environ.get('XDG_RUNTIME_DIR') or 'unset'})."
            ) from e
        self.stats.latency_s = float(self._stream.latency)
        self._stream.start()
        try:
            while not self._stop.is_set():
                try:
                    block = self._q.get(timeout=0.5)
                except queue.Empty:
                    continue
                self.stats.blocks += 1
                self.stats.queue_depth = self._q.qsize()
                yield block
        finally:
            # abort(), not stop(): stop() waits for pending buffers, which never
            # arrive while the PipeWire node is unlinked (it is not scheduled).
            self._stream.abort(ignore_errors=True)
            self._stream.close(ignore_errors=True)

    def close(self) -> None:
        self._stop.set()


def ensure_pipewire_env() -> None:
    """Point clients at the user's PipeWire server when XDG_RUNTIME_DIR is unset.

    PipeWire's ALSA plugin (the ``pipewire`` PortAudio device) finds the server
    through ``$XDG_RUNTIME_DIR/pipewire-0``. Shells started via ssh, su, sudo or
    some terminal multiplexers lack the variable, and then the device silently
    disappears. Must run before sounddevice is first imported (PortAudio
    enumerates devices at initialisation).
    """
    if not os.environ.get("XDG_RUNTIME_DIR"):
        candidate = Path(f"/run/user/{os.getuid()}")
        if (candidate / "pipewire-0").exists():
            os.environ["XDG_RUNTIME_DIR"] = str(candidate)
    # Stable, stereo, unconnected capture node: "cctv-analyser:input_FL/FR".
    # No auto-connection, so the default source (a microphone) never leaks in.
    # tools/route_mixxx.sh links Mixxx's main output to it explicitly.
    os.environ.setdefault(
        "PIPEWIRE_PROPS",
        '{ node.name=cctv-analyser node.description="CCTV analyser" '
        "node.autoconnect=false node.always-process=true media.role=Production }",
    )
    os.environ.setdefault("PIPEWIRE_ALSA", "{ audio.channels=2 audio.position=[FL FR] }")


def list_input_devices() -> list[str]:
    ensure_pipewire_env()
    import sounddevice as sd

    return [
        f"{i}: {d['name']} ({d['max_input_channels']} in, {int(d['default_samplerate'])} Hz)"
        for i, d in enumerate(sd.query_devices())
        if d["max_input_channels"] > 0
    ]
