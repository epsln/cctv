#!/usr/bin/env bash
# Link Mixxx's main output to the analyser's PipeWire capture node.
#
#   tools/route_mixxx.sh          # link (run after Mixxx and `tools/run.sh live` are started)
#   tools/route_mixxx.sh --list   # show candidate ports
#   tools/route_mixxx.sh --unlink # remove the links
#
# The analyser creates the node "cctv-analyser" (input_FL/input_FR) without
# auto-connection, so only what is linked here reaches it. Only Mixxx's main
# output is linked: headphone cueing and other desktop audio must not reach
# the analyser. Mixxx port names depend on its sound API and output mapping.
# If the default pattern finds nothing, check --list and set MIXXX_PORTS, e.g.
#   MIXXX_PORTS='^Mixxx:out_[01]$' tools/route_mixxx.sh
set -euo pipefail
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -S "/run/user/$(id -u)/pipewire-0" ]; then
  export XDG_RUNTIME_DIR=/run/user/$(id -u)  # ssh/su shells lack it; pw-link needs it
fi
mixxx_re=${MIXXX_PORTS:-'[Mm]ixxx'}
ana_re=${ANALYSER_PORTS:-'^cctv-analyser:input_F[LR]$'}
if [ "${1:-}" = "--list" ]; then
  echo "== outputs"; pw-link -o
  echo "== inputs"; pw-link -i
  exit 0
fi
mapfile -t ana < <(pw-link -i | grep -E "$ana_re")
if [ ${#ana[@]} -gt 2 ]; then
  echo "several analyser nodes are running; stop the extra cctv-analyse processes:" >&2
  printf '  %s\n' "${ana[@]}" >&2
  exit 1
fi
# Left/right chosen explicitly (never by list order).
ins=("$(printf '%s\n' "${ana[@]}" | grep -m1 'FL$' || true)" "$(printf '%s\n' "${ana[@]}" | grep -m1 'FR$' || true)")
if [ -z "${ins[0]}" ] || [ -z "${ins[1]}" ]; then
  echo "analyser inputs not found ($ana_re). Is 'tools/run.sh live' running?" >&2
  exit 1
fi
# Main output only: drop headphone/cue/monitor ports.
mapfile -t cand < <(pw-link -o | grep -E "$mixxx_re" | grep -viE 'head|cue|phone|monitor')
outs=("$(printf '%s\n' "${cand[@]}" | grep -m1 -E '(FL|_0|_1_?L?)$' || true)"
      "$(printf '%s\n' "${cand[@]}" | grep -m1 -E '(FR|_1|_2_?R?)$' || true)")
if [ -z "${outs[0]}" ] || [ -z "${outs[1]}" ] || [ ${#cand[@]} -gt 2 ]; then
  if [ ${#cand[@]} -gt 2 ]; then
    echo "more than one Mixxx output pair found; set MIXXX_PORTS to the main pair:" >&2
    printf '  %s\n' "${cand[@]}" >&2
    exit 1
  fi
  echo "Mixxx main output ports not found (pattern '$mixxx_re'). Is Mixxx running with" >&2
  echo "its Main output on a PipeWire/JACK/Pulse device? See --list; set MIXXX_PORTS." >&2
  exit 1
fi
for i in 0 1; do
  if [ "${1:-}" = "--unlink" ]; then
    pw-link -d "${outs[$i]}" "${ins[$i]}" 2>/dev/null && echo "unlinked ${outs[$i]} -> ${ins[$i]}" || true
  else
    pw-link "${outs[$i]}" "${ins[$i]}" 2>/dev/null || true
    echo "linked ${outs[$i]} -> ${ins[$i]}"
  fi
done
