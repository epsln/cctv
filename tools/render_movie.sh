#!/usr/bin/env bash
# Deterministic offline render with Godot Movie Maker (replay clock, fixed fps).
#
#   tools/render_movie.sh [-s show.json] [-f fps] [-t seconds] OUT.(avi|png)
#
# Godot: $GODOT, .godot-bin/godot (tools/get_godot.sh) or PATH. Rendering runs as fast as the machine allows,
# independent of real time; output frame N always represents clock N/fps.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/godot_path.sh
source tools/godot_path.sh
"$godot" --headless --path . --import >/dev/null 2>&1 || true
show=res://shows/demo.json fps=60 secs=10
while getopts "s:f:t:" o; do
  case $o in s) show=$OPTARG ;; f) fps=$OPTARG ;; t) secs=$OPTARG ;; *) exit 2 ;; esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || { sed -n '2,7p' "$0"; exit 2; }
out=$(realpath -m "$1")
mkdir -p "$(dirname "$out")"
"$godot" --path . --audio-driver Dummy --write-movie "$out" --fixed-fps "$fps" \
  --quit-after $((fps * secs)) --resolution 1920x1080 \
  -- --replay --no-operator --no-projector --show="$show" --fps="$fps"
