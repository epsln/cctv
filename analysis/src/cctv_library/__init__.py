"""Media library preprocessing: versioned asset manifest and analysis cache.

The core (probing, proxies, PDF rasterisation, thumbnails, manifest) needs only
the standard library plus ffmpeg/ffprobe and poppler on PATH, so it runs as
``PYTHONPATH=analysis/src python3 -m cctv_library``. Face detection needs the
optional ``faces`` dependency group (OpenCV).
"""

MANIFEST_SCHEMA = "cctv.manifest"
MANIFEST_VERSION = 2
