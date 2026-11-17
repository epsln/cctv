#!/usr/bin/env bash
# Deterministic offline render with Godot Movie Maker (replay clock, fixed fps).
#
#   tools/render_movie.sh [-s show.json] [-f fps] [-t seconds] OUT.(avi|png)
#
# Uses $GODOT (default: godot). Rendering runs as fast as the machine allows,
# independent of real time; output frame N always represents clock N/fps.
set -euo pipefail
cd "$(dirname "$0")/.."
show=res://shows/demo.json fps=60 secs=10
while getopts "s:f:t:" o; do
  case $o in s) show=$OPTARG ;; f) fps=$OPTARG ;; t) secs=$OPTARG ;; *) exit 2 ;; esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || { sed -n '2,7p' "$0"; exit 2; }
out=$(realpath -m "$1")
mkdir -p "$(dirname "$out")"
"${GODOT:-godot}" --path . --audio-driver Dummy --write-movie "$out" --fixed-fps "$fps" \
  --quit-after $((fps * secs)) --resolution 1920x1080 \
  -- --replay --no-operator --no-projector --show="$show" --fps="$fps"
