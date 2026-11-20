#!/usr/bin/env bash
# Start the analyser and the Godot runtime together.
#
#   tools/run.sh live [ANALYSER ARGS...]          # PipeWire input (see tools/route_mixxx.sh)
#   tools/run.sh file SET.wav [ANALYSER ARGS...]  # play a recorded set
#
# Godot arguments go in $CCTV_GODOT_ARGS (e.g. "--show=res://shows/demo.json
# --projector-screen=1"). Stopping either process stops both.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/godot_path.sh
source tools/godot_path.sh
mode=${1:?usage: tools/run.sh live|file [args...]}
shift
port=${CCTV_STATE_PORT:-9870}
case "$mode" in
  live) analyse=(live "$@") ;;
  file) analyse=(file "${1:?audio file}" --play "${@:2}") ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
# shellcheck disable=SC2086
"$godot" --path . -- --state-port="$port" ${CCTV_GODOT_ARGS:-} &
gpid=$!
(cd analysis && exec uv run --quiet cctv-analyse "${analyse[@]}" --udp "127.0.0.1:$port") &
apid=$!
trap 'kill "$gpid" "$apid" 2>/dev/null || true' EXIT INT TERM
wait -n "$gpid" "$apid"
