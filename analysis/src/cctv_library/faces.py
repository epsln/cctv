"""Offline face detection with OpenCV's YuNet detector (CPU, laptop friendly).

Requires the optional ``faces`` dependency group (``opencv-python-headless``)
and the YuNet ONNX model (``tools/get_face_model.sh``). Detection only: no
landmarks or embeddings are stored and nothing identifies a person.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .tracking import Box, Tracker

DETECTOR = "yunet-2023mar"
#: Detection runs on frames downscaled to this width.
DETECT_WIDTH = 640


class FaceDetector:
    def __init__(self, model: Path, score_threshold: float = 0.7) -> None:
        import cv2

        self._cv2 = cv2
        self._model = str(model)
        self._threshold = score_threshold
        self._det: Any = None
        self._size: tuple[int, int] = (0, 0)

    def detect(self, frame: Any) -> list[tuple[Box, float]]:
        """Detect faces in a BGR frame; boxes normalised to the frame."""
        cv2 = self._cv2
        h, w = frame.shape[:2]
        scale = min(1.0, DETECT_WIDTH / w)
        sw, sh = round(w * scale), round(h * scale)
        small = cv2.resize(frame, (sw, sh)) if scale < 1.0 else frame
        if self._det is None:
            self._det = cv2.FaceDetectorYN.create(self._model, "", (sw, sh), self._threshold)
        if self._size != (sw, sh):
            self._det.setInputSize((sw, sh))
            self._size = (sw, sh)
        _, faces = self._det.detect(small)
        out: list[tuple[Box, float]] = []
        for f in faces if faces is not None else []:
            x, y, bw, bh = (float(v) for v in f[:4])
            x0, y0 = max(0.0, x / sw), max(0.0, y / sh)
            x1, y1 = min(1.0, (x + bw) / sw), min(1.0, (y + bh) / sh)
            if x1 > x0 and y1 > y0:
                out.append(((x0, y0, x1 - x0, y1 - y0), float(f[-1])))
        return out


def detect_image(det: FaceDetector, path: Path) -> dict[str, Any]:
    import cv2

    img = cv2.imread(str(path))
    if img is None:
        raise ValueError(f"cannot read image {path}")
    faces = det.detect(img)
    tracks = [
        {"id": i + 1, "samples": [{"t": 0.0, "box": [round(v, 4) for v in b], "conf": round(c, 3)}]}
        for i, (b, c) in enumerate(faces)
    ]
    return {"detector": DETECTOR, "tracks": tracks}


def detect_video(det: FaceDetector, path: Path, step: float = 0.2) -> dict[str, Any]:
    """Sample every ``step`` seconds and link detections into tracks."""
    import cv2

    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise ValueError(f"cannot open video {path}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
    every = max(1, round(step * fps))
    tracker = Tracker(max_gap=max(1.0, 4 * step))
    i = 0
    while True:
        ok = cap.grab()
        if not ok:
            break
        if i % every == 0:
            ok, frame = cap.retrieve()
            if ok:
                tracker.add(i / fps, det.detect(frame))
        i += 1
    cap.release()
    return {"detector": DETECTOR, "step": step, "tracks": tracker.finish()}
