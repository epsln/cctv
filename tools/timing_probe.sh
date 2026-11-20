#!/usr/bin/env bash
# End-to-end timing check: analyser (file, real-time paced) -> UDP -> Godot
# MusicalClock + Scheduler (tools/timing_probe.gd).
#
#   tools/timing_probe.sh [AUDIO_FILE] [SECONDS] [-- extra cctv-analyse args]
#
# Without AUDIO_FILE a synthetic 126 BPM track is generated. Writes
# bench/results/timing_<epoch>.json and fails if the clock did not follow the
# analyser for most of the run.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/godot_path.sh
source tools/godot_path.sh
audio=${1:-}
secs=${2:-20}
shift $(($# > 2 ? 2 : $#))
[ "${1:-}" = "--" ] && shift
port=${CCTV_STATE_PORT:-9870}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; kill "${apid:-0}" 2>/dev/null || true' EXIT
if [ -z "$audio" ]; then
  audio=$tmp/synthetic.wav
  (cd analysis && uv run --quiet python -c "
import numpy as np, soundfile as sf
from cctv_analysis.synth import beat_track
y = beat_track(48000, 126.0, $secs + 5.0, 0.3)
sf.write('$audio', np.stack([y, y], 1) * 0.5, 48000)")
fi
out=bench/results/timing_$(date +%s).json
mkdir -p bench/results
(cd analysis && uv run --quiet cctv-analyse file "$audio" --realtime --duration "$((secs + 3))" \
  --udp "127.0.0.1:$port" "$@") &
apid=$!
"$godot" --headless --path . -s res://tools/timing_probe.gd -- \
  --duration="$secs" --port="$port" --out="res://$out" | tee "$tmp/summary.json"
wait "$apid" || true
python3 - "$out" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))["summary"]
ok = s["followed_ratio"] > 0.5 and s["phase_error_ms_p95"] < 20 and s["receiver"]["stats"]["rejected"] == 0
print(f"followed={s['followed_ratio']:.0%} phase_err_p95={s['phase_error_ms_p95']:.1f}ms "
      f"event_late_max={s['event_late_ms_max']:.1f}ms -> {'PASS' if ok else 'FAIL'}")
sys.exit(0 if ok else 1)
EOF
