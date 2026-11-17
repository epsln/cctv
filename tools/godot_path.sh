# Sourced by tools/*.sh. Sets $godot to a usable Godot binary:
# $GODOT, then .godot-bin/godot (tools/get_godot.sh), then godot/godot4 on PATH.
# shellcheck shell=bash
find_godot() {
  local root c
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  for c in "${GODOT:-}" "$root/.godot-bin/godot" "$(command -v godot || true)" "$(command -v godot4 || true)"; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  echo "Godot not found. Run tools/get_godot.sh, or set GODOT=/path/to/godot." >&2
  return 1
}
godot=$(find_godot)
