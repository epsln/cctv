#!/usr/bin/env bash
# Transcode videos to Theora (.ogv) for the built-in Godot video backend.
#
#   tools/transcode.sh [-H height] [-q quality] [-g gop] OUTDIR INPUT...
#
# Defaults: height 720, quality 7 (0-10), keyframe every 30 frames (short GOP
# keeps seek latency low at the cost of file size). Audio is dropped.
set -euo pipefail
height=720 quality=7 gop=30
while getopts "H:q:g:" o; do
  case $o in
    H) height=$OPTARG ;;
    q) quality=$OPTARG ;;
    g) gop=$OPTARG ;;
    *) sed -n '2,8p' "$0"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 2 ] || { sed -n '2,8p' "$0"; exit 2; }
out=$1; shift
mkdir -p "$out"
for in in "$@"; do
  name=$(basename "${in%.*}")
  ffmpeg -nostdin -loglevel error -y -i "$in" -an \
    -vf "scale=-2:${height}:flags=lanczos,format=yuv420p" \
    -c:v libtheora -q:v "$quality" -g "$gop" "$out/$name.ogv"
  echo "$out/$name.ogv"
done
