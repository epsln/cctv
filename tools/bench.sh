#!/usr/bin/env bash
# Run the Milestone 1 benchmark (see docs/benchmark.md).
#
#   tools/bench.sh [SECONDS] [extra benchmark options...]
#
# Requires sample assets (tools/make_sample_assets.sh) or a show passed with
# --show=PATH. Uses $GODOT (default: godot). Results: bench/results/*.json
set -euo pipefail
cd "$(dirname "$0")/.."
secs=${1:-60}; shift || true
[ -f assets/sample/manifest.json ] || tools/make_sample_assets.sh
"${GODOT:-godot}" --path . --audio-driver Dummy --resolution 1920x1080 \
  res://scenes/benchmark.tscn -- --duration="$secs" "$@"
