#!/usr/bin/env bash
# Run the test suite.
#
#   tools/test.sh [gl|headless]
#
# gl (default): real OpenGL rendering under Xvfb when no display is present,
#   so pixel read-back tests run (Mesa llvmpipe works).
# headless: dummy renderer; pixel tests are skipped.
# Godot: $GODOT, .godot-bin/godot (tools/get_godot.sh) or PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/godot_path.sh
source tools/godot_path.sh
mode=${1:-gl}
"$godot" --headless --path . --import >/dev/null 2>&1 || true
if [ "$mode" = headless ]; then
  exec "$godot" --headless --path . -s res://tests/run_tests.gd
fi
cmd=("$godot" --path . --rendering-driver opengl3 --audio-driver Dummy -s res://tests/run_tests.gd)
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  exec xvfb-run -a -s "-screen 0 1920x1080x24" "${cmd[@]}"
fi
exec "${cmd[@]}"
