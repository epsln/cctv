"""``cctv-analyse``: run the analyser on a file or live input and publish state."""

from __future__ import annotations

import argparse
import signal
import sys
from typing import Any

from .analyser import Sink, run_source
from .beat import MAX_BPM, MIN_BPM
from .pcm import FilePcmSource, LivePcmSource, PcmSource, list_input_devices
from .state import FEATURE_VERSION, SCHEMA_VERSION
from .transport import DEFAULT_PORT, JsonlRecorder, UdpPublisher, parse_addr


def _common(p: argparse.ArgumentParser) -> None:
    p.add_argument("--udp", default=f"127.0.0.1:{DEFAULT_PORT}", help="HOST:PORT, or 'off'")
    p.add_argument("--record", metavar="JSONL", help="write every state to this file")
    p.add_argument("--hop", type=int, default=512, help="block size in samples")
    p.add_argument(
        "--bpm-range",
        nargs=2,
        type=float,
        default=(MIN_BPM, MAX_BPM),
        metavar=("LO", "HI"),
        help="fold tempo octave errors into [LO, HI) (default %(default)s)",
    )
    p.add_argument(
        "--tempo-prior",
        type=float,
        metavar="BPM",
        help="centre of the comb tracker's tempo prior (default 135); set near the genre tempo",
    )
    p.add_argument(
        "--tracker",
        choices=["comb", "aubio"],
        default="comb",
        help="beat tracker (default comb; see docs/beat-evaluation.md)",
    )


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="cctv-analyse", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("file", help="analyse a recorded set")
    f.add_argument("path")
    mode = f.add_mutually_exclusive_group()
    mode.add_argument("--realtime", action="store_true", help="pace blocks in real time")
    mode.add_argument("--play", action="store_true", help="play the file (implies realtime)")
    f.add_argument("--start", type=float, default=0.0, help="start offset (s)")
    f.add_argument("--duration", type=float, help="seconds to analyse")
    _common(f)

    li = sub.add_parser("live", help="analyse a live input (e.g. Mixxx main via PipeWire)")
    li.add_argument("--device", default="pipewire", help="PortAudio device name or index")
    li.add_argument("--rate", type=int, default=48000)
    li.add_argument("--channels", type=int, default=2)
    _common(li)

    sub.add_parser("devices", help="list input devices")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.cmd == "devices":
        print("\n".join(list_input_devices()))
        return 0

    source: PcmSource
    header: dict[str, Any] = {
        "v": SCHEMA_VERSION,
        "features": FEATURE_VERSION,
        "hop": args.hop,
        "bpm_range": list(args.bpm_range),
        "tracker": args.tracker,
        "tempo_prior": args.tempo_prior,
    }
    if args.cmd == "file":
        source = FilePcmSource(
            args.path,
            args.hop,
            realtime=args.realtime,
            play=args.play,
            start_s=args.start,
            duration_s=args.duration,
        )
        header.update(source="file", path=args.path, start=args.start)
    else:
        device = int(args.device) if str(args.device).isdigit() else args.device
        source = LivePcmSource(device, args.rate, args.channels, args.hop)
        header.update(source="live", device=args.device)
        if str(args.device) == "pipewire":
            print(
                "cctv-analyse: capturing from PipeWire node 'cctv-analyser' (not auto-connected); "
                "link Mixxx's main output with tools/route_mixxx.sh",
                file=sys.stderr,
            )
    header.update(sample_rate=source.sample_rate, realtime=source.realtime)

    sinks: list[Sink] = []
    if args.udp != "off":
        sinks.append(UdpPublisher(parse_addr(args.udp)))
    if args.record:
        sinks.append(JsonlRecorder(args.record, header))

    signal.signal(signal.SIGTERM, lambda *_: source.close())
    try:
        a = run_source(
            source, sinks, args.hop, tuple(args.bpm_range), args.tracker, args.tempo_prior
        )
    except KeyboardInterrupt:
        return 130
    except RuntimeError as e:
        print(f"cctv-analyse: {e}", file=sys.stderr)
        return 1
    b = a.beat.pll.state
    print(
        f"blocks={source.stats.blocks} overruns={source.stats.overruns} "
        f"bpm={b.bpm:.2f} beat_conf={b.confidence:.2f} relocks={b.discontinuities} "
        f"bar={a.bar.state.source}:{a.bar.state.downbeat} ({a.bar.state.confidence:.2f})",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
