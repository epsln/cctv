"""Scan a raw media folder, run versioned preprocessing steps and write manifest v2.

Layout of the raw library (``SRC``)::

    SRC/<tag>/<tag>/.../file.ext   directory names become tags
    SRC/tags.json                  optional {"relative/path or dir/": ["tag", ...]}

Supported files: videos (proxied to Theora), images, PDFs (one asset per
page, rasterised), ``.txt`` text pools (one text asset per non-empty line;
header lines ``# style: ticker`` / ``# lang: en`` set defaults for the file;
the file stem is added as a tag)
and ``.gen.json`` procedural generators ({"generator", "params", "size"}).

Face tracks come from the YuNet detector (``--faces MODEL``) or from a
hand-made sidecar ``<file>.faces.json`` (same format, detector "manual"),
which takes precedence.

Output (``OUT``)::

    OUT/manifest.json
    OUT/cache/<hash16>/<step>@<version>/...   one directory per analysis step

A step is recomputed only when the file content (sha256) or the step version
changes; unchanged entries are reused, so re-running ingest is cheap.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import MANIFEST_SCHEMA, MANIFEST_VERSION

VIDEO_EXT = {".mp4", ".mov", ".mkv", ".webm", ".avi", ".ogv", ".m4v", ".mpg", ".mpeg"}
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp"}
PDF_EXT = {".pdf"}
TEXT_EXT = {".txt"}
TEXT_STYLES = {"caption", "ticker", "headline", "label", "stamp", "terminal"}

#: Step versions. Bump a version when its output format or algorithm changes.
STEP_VERSIONS = {"probe": 1, "proxy": 1, "thumb": 1, "copy": 1, "raster": 1, "faces": 1}
#: Proxy heights; each video gets every height <= its own (at least one).
DEFAULT_PROXY_HEIGHTS = (540, 1080)
THUMB_WIDTH = 320


@dataclass
class Options:
    proxy_heights: tuple[int, ...] = DEFAULT_PROXY_HEIGHTS
    dpi: int = 150
    theora_quality: int = 7
    gop: int = 30
    face_model: Path | None = None
    face_step: float = 0.2
    log: Callable[[str], None] = print


@dataclass
class Report:
    assets: int = 0
    computed: list[str] = field(default_factory=list)
    reused: int = 0
    errors: list[str] = field(default_factory=list)


def content_hash(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def slug(rel: Path) -> str:
    """Stable asset ID from a library-relative path (without extension)."""
    p = rel.as_posix()
    for suffix in (".gen.json", ".faces.json"):
        if p.endswith(suffix):
            p = p[: -len(suffix)] + ".x"
    s = Path(p).with_suffix("").as_posix().lower()
    return re.sub(r"[^a-z0-9/_-]+", "_", s).strip("_")


def kind_of(path: Path) -> str | None:
    if path.name.endswith(".faces.json"):
        return None
    if path.name.endswith(".gen.json"):
        return "procedural"
    ext = path.suffix.lower()
    for kind, exts in (
        ("video", VIDEO_EXT),
        ("image", IMAGE_EXT),
        ("pdf", PDF_EXT),
        ("text", TEXT_EXT),
    ):
        if ext in exts:
            return kind
    return None


def tags_for(rel: Path, sidecar: dict[str, list[str]]) -> list[str]:
    tags = [p.lower() for p in rel.parent.parts]
    posix = rel.as_posix()
    for key, extra in sidecar.items():
        if posix == key or (key.endswith("/") and posix.startswith(key)):
            tags.extend(t.lower() for t in extra)
    return sorted(set(tags))


class Cache:
    """Content-addressed step cache: ``cache/<hash16>/<step>@<version>/``."""

    def __init__(self, root: Path, report: Report) -> None:
        self.root = root
        self.report = report

    def step(
        self, digest: str, name: str, fn: Callable[[Path], dict[str, Any]]
    ) -> tuple[Path, dict[str, Any]]:
        d = self.root / digest[:16] / f"{name}@{STEP_VERSIONS[name]}"
        done = d / "done.json"
        if done.exists():
            self.report.reused += 1
            return d, dict(json.loads(done.read_text()))
        tmp = d.with_name(d.name + ".tmp")
        shutil.rmtree(tmp, ignore_errors=True)
        tmp.mkdir(parents=True)
        result = fn(tmp)
        (tmp / "done.json").write_text(json.dumps(result))
        shutil.rmtree(d, ignore_errors=True)
        tmp.rename(d)
        self.report.computed.append(f"{digest[:16]}/{name}")
        return d, result


def _run(cmd: list[str]) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def probe(path: Path) -> dict[str, Any]:
    out = json.loads(
        _run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=width,height,avg_frame_rate:format=duration",
                "-of",
                "json",
                str(path),
            ]
        )
    )
    st = out["streams"][0]
    num, _, den = str(st.get("avg_frame_rate", "0/1")).partition("/")
    fps = float(num) / float(den or 1) if float(den or 1) else 0.0
    dur = float(out.get("format", {}).get("duration", 0.0) or 0.0)
    return {
        "size": [int(st["width"]), int(st["height"])],
        "fps": round(fps, 3),
        "duration": round(dur, 3),
    }


def proxy_heights(src_h: int, wanted: tuple[int, ...]) -> list[int]:
    hs = sorted(h for h in wanted if h <= src_h)
    return hs or [src_h - src_h % 2]


def _thumb(src: Path, dst: Path, at: float = 0.0) -> dict[str, Any]:
    _run(
        [
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            f"{at:.3f}",
            "-i",
            str(src),
            "-frames:v",
            "1",
            "-vf",
            f"scale={THUMB_WIDTH}:-2",
            str(dst),
        ]
    )
    return {}


class Ingest:
    def __init__(self, src: Path, out: Path, opts: Options | None = None) -> None:
        self.src = src
        self.out = out
        self.opts = opts or Options()
        self.report = Report()
        self.cache = Cache(out / "cache", self.report)
        self._detector: Any = None

    def rel(self, p: Path) -> str:
        return p.relative_to(self.out).as_posix()

    def run(self) -> dict[str, Any]:
        sidecar_path = self.src / "tags.json"
        sidecar: dict[str, list[str]] = (
            json.loads(sidecar_path.read_text()) if sidecar_path.exists() else {}
        )
        assets: list[dict[str, Any]] = []
        files = sorted(p for p in self.src.rglob("*") if p.is_file() and kind_of(p))
        for path in files:
            rel = path.relative_to(self.src)
            kind = kind_of(path)
            base = {
                "source": rel.as_posix(),
                "tags": tags_for(rel, sidecar),
            }
            try:
                digest = content_hash(path)
                base["content_hash"] = "sha256:" + digest
                self.opts.log(f"{kind:5s} {rel}")
                if kind == "video":
                    assets.append(self.video(path, rel, digest, base))
                elif kind == "image":
                    assets.append(self.image(path, rel, digest, base))
                elif kind == "pdf":
                    assets.extend(self.pdf(path, rel, digest, base))
                elif kind == "text":
                    assets.extend(self.text(path, rel, base))
                elif kind == "procedural":
                    assets.append(self.procedural(path, rel, base))
            except (subprocess.CalledProcessError, ValueError, OSError, KeyError) as e:
                msg = f"{rel}: {e}"
                self.report.errors.append(msg)
                self.opts.log("  ERROR " + msg)
        ids = [a["id"] for a in assets]
        dupes = {i for i in ids if ids.count(i) > 1}
        if dupes:
            raise ValueError(f"duplicate asset ids: {sorted(dupes)}")
        self.report.assets = len(assets)
        manifest = {
            "schema": MANIFEST_SCHEMA,
            "version": MANIFEST_VERSION,
            "library_version": library_version(assets),
            "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "steps": STEP_VERSIONS,
            "assets": assets,
        }
        self.out.mkdir(parents=True, exist_ok=True)
        tmp = self.out / "manifest.json.tmp"
        tmp.write_text(json.dumps(manifest, indent=1))
        tmp.rename(self.out / "manifest.json")
        return manifest

    # -- per type ---------------------------------------------------------------

    def video(self, path: Path, rel: Path, digest: str, base: dict[str, Any]) -> dict[str, Any]:
        _, pr = self.cache.step(digest, "probe", lambda _d: probe(path))
        heights = proxy_heights(pr["size"][1], self.opts.proxy_heights)

        def make_proxies(d: Path) -> dict[str, Any]:
            out = []
            for h in heights:
                dst = d / f"{h}.ogv"
                _run(
                    [
                        "ffmpeg",
                        "-nostdin",
                        "-loglevel",
                        "error",
                        "-y",
                        "-i",
                        str(path),
                        "-an",
                        "-vf",
                        f"scale=-2:{h}:flags=lanczos,format=yuv420p",
                        "-c:v",
                        "libtheora",
                        "-q:v",
                        str(self.opts.theora_quality),
                        "-g",
                        str(self.opts.gop),
                        str(dst),
                    ]
                )
                out.append({"height": h, "file": dst.name})
            return {"proxies": out}

        pd, px = self.cache.step(digest, "proxy", make_proxies)
        td, _ = self.cache.step(
            digest,
            "thumb",
            lambda d: _thumb(path, d / "thumb.jpg", pr["duration"] * 0.1),
        )
        proxies = [{"height": p["height"], "path": self.rel(pd / p["file"])} for p in px["proxies"]]
        entry = {
            "id": slug(rel),
            "type": "video",
            **base,
            "path": proxies[-1]["path"],
            "proxies": proxies,
            "size": pr["size"],
            "fps": pr["fps"],
            "duration": pr["duration"],
            "thumbnail": self.rel(td / "thumb.jpg"),
            "analyses": {"probe": 1, "proxy": 1, "thumb": 1},
        }
        self._faces(entry, path, digest, video=True)
        return entry

    def image(self, path: Path, rel: Path, digest: str, base: dict[str, Any]) -> dict[str, Any]:
        _, pr = self.cache.step(digest, "probe", lambda _d: probe(path))

        def copy(d: Path) -> dict[str, Any]:
            dst = d / ("image" + path.suffix.lower())
            shutil.copyfile(path, dst)
            return {"file": dst.name}

        cd, cp = self.cache.step(digest, "copy", copy)
        td, _ = self.cache.step(digest, "thumb", lambda d: _thumb(path, d / "thumb.jpg"))
        entry = {
            "id": slug(rel),
            "type": "image",
            **base,
            "path": self.rel(cd / cp["file"]),
            "size": pr["size"],
            "thumbnail": self.rel(td / "thumb.jpg"),
            "analyses": {"probe": 1, "copy": 1, "thumb": 1},
        }
        self._faces(entry, cd / cp["file"], digest, video=False)
        return entry

    def pdf(self, path: Path, rel: Path, digest: str, base: dict[str, Any]) -> list[dict[str, Any]]:
        def raster(d: Path) -> dict[str, Any]:
            info = _run(["pdfinfo", str(path)])
            m = re.search(r"^Pages:\s+(\d+)", info, re.M)
            if not m:
                raise ValueError("cannot read page count")
            pages = int(m.group(1))
            out = []
            for p in range(1, pages + 1):
                stem = d / f"p{p}"
                _run(
                    [
                        "pdftoppm",
                        "-png",
                        "-r",
                        str(self.opts.dpi),
                        "-f",
                        str(p),
                        "-l",
                        str(p),
                        "-singlefile",
                        str(path),
                        str(stem),
                    ]
                )
                _thumb(stem.with_suffix(".png"), d / f"p{p}-thumb.jpg")
                out.append({"page": p, "size": probe(stem.with_suffix(".png"))["size"]})
            return {"pages": out, "dpi": self.opts.dpi}

        rd, rs = self.cache.step(digest, "raster", raster)
        entries = []
        for pg in rs["pages"]:
            p = pg["page"]
            entries.append(
                {
                    "id": f"{slug(rel)}/p{p}",
                    "type": "pdf_page",
                    **base,
                    "page": p,
                    "pages": len(rs["pages"]),
                    "path": self.rel(rd / f"p{p}.png"),
                    "size": pg["size"],
                    "thumbnail": self.rel(rd / f"p{p}-thumb.jpg"),
                    "analyses": {"raster": 1},
                }
            )
        return entries

    def text(self, path: Path, rel: Path, base: dict[str, Any]) -> list[dict[str, Any]]:
        # The pool's file name is a tag too (text/captions.txt -> "captions").
        base = {**base, "tags": sorted({*base["tags"], path.stem.lower()})}
        style, lang = "caption", ""
        entries = []
        n = 0
        for line in path.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if not s:
                continue
            m = re.match(r"#\s*(style|lang)\s*:\s*(\S+)", s)
            if m:
                if m.group(1) == "style":
                    if m.group(2) not in TEXT_STYLES:
                        raise ValueError(f"unknown text style {m.group(2)}")
                    style = m.group(2)
                else:
                    lang = m.group(2)
                continue
            if s.startswith("#"):
                continue
            n += 1
            e = {
                "id": f"{slug(rel)}/{n}",
                "type": "text",
                **base,
                "text": s,
                "style": style,
            }
            if lang:
                e["lang"] = lang
            entries.append(e)
        return entries

    def procedural(self, path: Path, rel: Path, base: dict[str, Any]) -> dict[str, Any]:
        spec = json.loads(path.read_text())
        if not isinstance(spec, dict) or "generator" not in spec:
            raise ValueError("procedural asset needs a 'generator'")
        return {
            "id": slug(rel),
            "type": "procedural",
            **base,
            "generator": spec["generator"],
            "params": spec.get("params", {}),
            "size": spec.get("size", [960, 540]),
        }

    def _faces(self, entry: dict[str, Any], path: Path, digest: str, video: bool) -> None:
        src = self.src / entry["source"]
        sidecar = src.with_name(src.name + ".faces.json")
        if sidecar.exists():
            data = json.loads(sidecar.read_text())

            def copy(d: Path) -> dict[str, Any]:
                data.setdefault("detector", "manual")
                data["version"] = STEP_VERSIONS["faces"]
                (d / "faces.json").write_text(json.dumps(data))
                return {"tracks": len(data.get("tracks", []))}

            fd, res = self.cache.step(content_hash(sidecar), "faces", copy)
            self._set_faces(entry, fd, res)
            return
        if self.opts.face_model is None:
            return
        from .faces import FaceDetector, detect_image, detect_video

        if self._detector is None:
            self._detector = FaceDetector(self.opts.face_model)
        det = self._detector

        def run(d: Path) -> dict[str, Any]:
            data = (
                detect_video(det, path, self.opts.face_step) if video else detect_image(det, path)
            )
            data["version"] = STEP_VERSIONS["faces"]
            (d / "faces.json").write_text(json.dumps(data))
            return {"tracks": len(data["tracks"])}

        fd, res = self.cache.step(digest, "faces", run)
        self._set_faces(entry, fd, res)

    def _set_faces(self, entry: dict[str, Any], fd: Path, res: dict[str, Any]) -> None:
        entry["analyses"]["faces"] = STEP_VERSIONS["faces"]
        entry["faces"] = self.rel(fd / "faces.json")
        if res["tracks"]:
            entry["tags"] = sorted({*entry["tags"], "has_faces"})


def library_version(assets: list[dict[str, Any]]) -> str:
    """Hash of everything that affects resolution and rendering: IDs, content,
    analysis versions and tags (collections resolve through tags)."""
    key = [
        (
            a["id"],
            a.get("content_hash", ""),
            a.get("text", ""),
            a.get("analyses", {}),
            a.get("tags", []),
        )
        for a in assets
    ]
    return hashlib.sha256(json.dumps(key, sort_keys=True).encode()).hexdigest()[:16]
