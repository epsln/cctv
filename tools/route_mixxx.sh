#!/usr/bin/env bash
# Link Mixxx's main output to the analyser's PipeWire capture node.
#
#   tools/route_mixxx.sh          # link (run after both Mixxx and the analyser are started)
#   tools/route_mixxx.sh --list   # show candidate ports
#
# Only Mixxx's main/master output is linked: headphone cueing and other
# desktop audio must not reach the analyser. Port names differ between Mixxx
# versions and audio backends. Override the patterns if needed:
#   MIXXX_PORTS='Mixxx:out_[01]' ANALYSER_PORTS='python.*:input_F[LR]' tools/route_mixxx.sh
set -euo pipefail
mixxx_re=${MIXXX_PORTS:-'[Mm]ixxx.*(out(put)?_(FL|FR|0|1|1_2)|[Mm]aster|[Mm]ain)'}
ana_re=${ANALYSER_PORTS:-'(python|PortAudio|cctv).*:(input|capture)_(FL|FR|[0-9])'}
if [ "${1:-}" = "--list" ]; then
  echo "outputs:"; pw-link -o
  echo "inputs:"; pw-link -i
  exit 0
fi
mapfile -t outs < <(pw-link -o | grep -E "$mixxx_re" | grep -viE 'head|cue|phone' | head -2)
mapfile -t ins < <(pw-link -i | grep -E "$ana_re" | head -2)
if [ ${#outs[@]} -lt 2 ] || [ ${#ins[@]} -lt 2 ]; then
  echo "could not find 2 Mixxx main ports (${#outs[@]}) and 2 analyser inputs (${#ins[@]})." >&2
  echo "Is the analyser running (tools/run.sh live)? Use --list and set MIXXX_PORTS/ANALYSER_PORTS." >&2
  exit 1
fi
for i in 0 1; do
  pw-link "${outs[$i]}" "${ins[$i]}" 2>/dev/null || true
  echo "linked ${outs[$i]} -> ${ins[$i]}"
done
