#!/usr/bin/env bash
# Download the YuNet face detection model (OpenCV Zoo, MIT licence) used by
# `cctv-ingest --faces`.
#
#   tools/get_face_model.sh [DEST]   (default: .models/face_detection_yunet_2023mar.onnx)
set -euo pipefail
cd "$(dirname "$0")/.."
dest=${1:-.models/face_detection_yunet_2023mar.onnx}
url=https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx
mkdir -p "$(dirname "$dest")"
if [ ! -s "$dest" ]; then
  curl -fsSL -o "$dest.tmp" "$url"
  mv "$dest.tmp" "$dest"
fi
echo "$dest"
