#!/usr/bin/env bash
# Download the pinned Godot editor binary to .godot-bin/godot (gitignored).
#
#   tools/get_godot.sh [version]     (default 4.5-stable)
set -euo pipefail
cd "$(dirname "$0")/.."
ver=${1:-4.5-stable}
mkdir -p .godot-bin
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/godot.zip" \
  "https://github.com/godotengine/godot/releases/download/${ver}/Godot_v${ver}_linux.x86_64.zip"
unzip -q "$tmp/godot.zip" -d "$tmp"
mv "$tmp/Godot_v${ver}_linux.x86_64" .godot-bin/godot
chmod +x .godot-bin/godot
.godot-bin/godot --version
