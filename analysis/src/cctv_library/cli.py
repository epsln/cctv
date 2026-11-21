"""``cctv-ingest SRC OUT``: preprocess a raw media folder into a manifest v2 library."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .ingest import DEFAULT_PROXY_HEIGHTS, Ingest, Options


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="cctv-ingest", description=__doc__)
    p.add_argument("src", type=Path, help="raw media folder (directory names become tags)")
    p.add_argument("out", type=Path, help="library output folder (manifest.json + cache/)")
    p.add_argument(
        "--proxy-heights",
        default=",".join(map(str, DEFAULT_PROXY_HEIGHTS)),
        help="comma-separated video proxy heights (default %(default)s)",
    )
    p.add_argument("--dpi", type=int, default=150, help="PDF raster resolution")
    p.add_argument(
        "--faces",
        type=Path,
        metavar="MODEL.onnx",
        help="run YuNet face detection with this model (needs the 'faces' extra)",
    )
    p.add_argument("--face-step", type=float, default=0.2, help="video sampling interval (s)")
    p.add_argument("-q", "--quiet", action="store_true")
    a = p.parse_args(argv)
    if not a.src.is_dir():
        p.error(f"{a.src} is not a directory")
    opts = Options(
        proxy_heights=tuple(int(h) for h in a.proxy_heights.split(",") if h),
        dpi=a.dpi,
        face_model=a.faces,
        face_step=a.face_step,
        log=(lambda _m: None) if a.quiet else print,
    )
    ing = Ingest(a.src, a.out, opts)
    m = ing.run()
    r = ing.report
    print(
        f"{r.assets} assets, {len(r.computed)} steps computed, {r.reused} reused, "
        f"{len(r.errors)} errors; library {m['library_version']} -> {a.out / 'manifest.json'}"
    )
    return 1 if r.errors else 0


if __name__ == "__main__":
    sys.exit(main())
