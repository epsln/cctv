#!/usr/bin/env bash
# Run the Milestone 1 benchmark (see docs/benchmark.md).
#
#   tools/bench.sh [SECONDS] [extra benchmark options...]
#
# Requires sample assets (tools/make_sample_assets.sh) or a show passed with
# --show=PATH. Godot: $GODOT, .godot-bin/godot (tools/get_godot.sh) or PATH. Results: bench/results/*.json
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/godot_path.sh
source tools/godot_path.sh
"$godot" --headless --path . --import >/dev/null 2>&1 || true
secs=${1:-60}; shift || true
[ -f assets/sample/library/manifest.json ] || tools/make_sample_assets.sh
"$godot" --path . --audio-driver Dummy --resolution 1920x1080 \
  res://scenes/benchmark.tscn -- --duration="$secs" "$@"
