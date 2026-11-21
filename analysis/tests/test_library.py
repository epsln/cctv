import json
import shutil
import subprocess
from pathlib import Path

import pytest

from cctv_library.ingest import Ingest, Options, library_version, proxy_heights, slug, tags_for
from cctv_library.tracking import Tracker, iou

needs_ffmpeg = pytest.mark.skipif(
    not (shutil.which("ffmpeg") and shutil.which("pdftoppm")), reason="ffmpeg/poppler missing"
)


def test_iou() -> None:
    assert iou((0, 0, 1, 1), (0, 0, 1, 1)) == pytest.approx(1.0)
    assert iou((0, 0, 1, 1), (2, 2, 1, 1)) == 0.0
    assert iou((0, 0, 2, 1), (1, 0, 2, 1)) == pytest.approx(1 / 3)


def test_tracker_links_and_splits() -> None:
    tr = Tracker(max_gap=0.5, min_samples=2)
    for i in range(5):
        t = i * 0.2
        tr.add(t, [((0.1 + 0.01 * i, 0.1, 0.2, 0.2), 0.9), ((0.7, 0.6, 0.1, 0.1), 0.8)])
    tr.add(3.0, [((0.1, 0.1, 0.2, 0.2), 0.9)])  # after the gap: a new track
    tr.add(3.2, [((0.1, 0.1, 0.2, 0.2), 0.9)])
    tracks = tr.finish()
    assert [len(t["samples"]) for t in tracks] == [5, 5, 2]
    assert [t["id"] for t in tracks] == [1, 2, 3]


def test_tracker_drops_short_tracks() -> None:
    tr = Tracker(min_samples=3)
    tr.add(0.0, [((0.0, 0.0, 0.1, 0.1), 0.9)])
    assert tr.finish() == []


def test_slug_tags_and_proxies() -> None:
    assert slug(Path("CCTV/Lobby Cam 2.mp4")) == "cctv/lobby_cam_2"
    assert tags_for(Path("tv_news/cctv/x.mp4"), {"tv_news/": ["broadcast"]}) == [
        "broadcast",
        "cctv",
        "tv_news",
    ]
    assert proxy_heights(1080, (540, 1080)) == [540, 1080]
    assert proxy_heights(720, (540, 1080)) == [540]
    assert proxy_heights(361, (540, 1080)) == [360]


def test_library_version_changes_with_content() -> None:
    a = [{"id": "x", "content_hash": "sha256:1", "analyses": {"probe": 1}}]
    b = [{"id": "x", "content_hash": "sha256:2", "analyses": {"probe": 1}}]
    assert library_version(a) != library_version(b)
    assert library_version(a) == library_version([dict(a[0])])


def _video(path: Path, size: str = "320x240") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
         f"testsrc2=size={size}:rate=10", "-t", "1", "-pix_fmt", "yuv420p", str(path)],
        check=True,
    )  # fmt: skip


@needs_ffmpeg
def test_ingest_end_to_end_and_cache(tmp_path: Path) -> None:
    src, out = tmp_path / "raw", tmp_path / "lib"
    _video(src / "cctv" / "cam1.mp4")
    subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
         "testsrc2=size=200x100", "-frames:v", "1", str(src / "cctv" / "still.png")],
        check=True,
    )  # fmt: skip
    (src / "text").mkdir()
    (src / "text" / "ticker.txt").write_text("# style: ticker\n# lang: en\nONE\n\nTWO\n")
    (src / "tags.json").write_text(json.dumps({"cctv/cam1.mp4": ["night"]}))

    ing = Ingest(src, out, Options(proxy_heights=(120, 540), log=lambda _m: None))
    m = ing.run()
    assert ing.report.errors == []
    assert m["schema"] == "cctv.manifest" and m["version"] == 2
    by_id = {a["id"]: a for a in m["assets"]}
    assert set(by_id) == {"cctv/cam1", "cctv/still", "text/ticker/1", "text/ticker/2"}
    v = by_id["cctv/cam1"]
    assert v["tags"] == ["cctv", "night"]
    assert [p["height"] for p in v["proxies"]] == [120]
    assert (out / v["path"]).exists() and (out / v["thumbnail"]).exists()
    assert v["size"] == [320, 240] and v["duration"] == pytest.approx(1.0, abs=0.2)
    assert by_id["text/ticker/2"] == {
        "id": "text/ticker/2",
        "type": "text",
        "source": "text/ticker.txt",
        "tags": ["text", "ticker"],
        "content_hash": by_id["text/ticker/1"]["content_hash"],
        "text": "TWO",
        "style": "ticker",
        "lang": "en",
    }

    # Second run reuses every step and yields the same library version.
    ing2 = Ingest(src, out, Options(proxy_heights=(120, 540), log=lambda _m: None))
    m2 = ing2.run()
    assert ing2.report.computed == []
    assert m2["library_version"] == m["library_version"]

    # Changing content invalidates only that file's steps.
    _video(src / "cctv" / "cam1.mp4", "160x120")
    ing3 = Ingest(src, out, Options(proxy_heights=(120, 540), log=lambda _m: None))
    m3 = ing3.run()
    assert sorted(c.split("/")[1] for c in ing3.report.computed) == ["probe", "proxy", "thumb"]
    assert m3["library_version"] != m["library_version"]


@needs_ffmpeg
def test_ingest_pdf_pages(tmp_path: Path) -> None:
    src, out = tmp_path / "raw", tmp_path / "lib"
    (src / "docs").mkdir(parents=True)
    tool = Path(__file__).resolve().parents[2] / "tools" / "make_pdf.py"
    subprocess.run(["python3", str(tool), str(src / "docs" / "d.pdf"), "A|B", "C"], check=True)
    m = Ingest(src, out, Options(dpi=30, log=lambda _m: None)).run()
    pages = [a for a in m["assets"] if a["type"] == "pdf_page"]
    assert [p["id"] for p in pages] == ["docs/d/p1", "docs/d/p2"]
    assert all((out / p["path"]).exists() for p in pages)


MODEL = Path(__file__).resolve().parents[2] / ".models" / "face_detection_yunet_2023mar.onnx"


@pytest.mark.skipif(not MODEL.exists(), reason="run tools/get_face_model.sh")
def test_face_detection_runs_on_video_and_image(tmp_path: Path) -> None:
    pytest.importorskip("cv2")
    src, out = tmp_path / "raw", tmp_path / "lib"
    _video(src / "cctv" / "cam.mp4")
    subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
         "color=gray:size=200x100", "-frames:v", "1", str(src / "cctv" / "s.png")],
        check=True,
    )  # fmt: skip
    ing = Ingest(src, out, Options(face_model=MODEL, log=lambda _m: None))
    m = ing.run()
    assert ing.report.errors == []
    for a in m["assets"]:
        assert a["analyses"]["faces"] == 1
        faces = json.loads((out / a["faces"]).read_text())
        assert faces["detector"] == "yunet-2023mar" and faces["version"] == 1
        assert faces["tracks"] == []  # synthetic test patterns contain no faces
        assert "has_faces" not in a["tags"]


@needs_ffmpeg
def test_ingest_procedural_and_face_sidecar(tmp_path: Path) -> None:
    src, out = tmp_path / "raw", tmp_path / "lib"
    _video(src / "talking_heads" / "anchor.mp4")
    tracks = {
        "tracks": [{"id": 1, "samples": [{"t": 0.0, "box": [0.1, 0.1, 0.2, 0.2], "conf": 1}]}]
    }
    (src / "talking_heads" / "anchor.mp4.faces.json").write_text(json.dumps(tracks))
    (src / "math").mkdir()
    (src / "math" / "osc.gen.json").write_text(
        json.dumps({"generator": "lissajous", "params": {"freq_a": 5}})
    )
    m = Ingest(src, out, Options(proxy_heights=(120,), log=lambda _m: None)).run()
    by_id = {a["id"]: a for a in m["assets"]}
    assert set(by_id) == {"talking_heads/anchor", "math/osc"}
    a = by_id["talking_heads/anchor"]
    assert "has_faces" in a["tags"]
    faces = json.loads((out / a["faces"]).read_text())
    assert faces["detector"] == "manual" and faces["tracks"] == tracks["tracks"]
    assert by_id["math/osc"]["generator"] == "lissajous"
    assert by_id["math/osc"]["size"] == [960, 540]
