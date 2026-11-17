#!/usr/bin/env bash
# Generate a synthetic sample library in assets/sample/ (gitignored):
# 1 "news" video (720p), 4 "CCTV" videos (360p), a still, a 3-page PDF with
# rasterized pages, text assets and a manifest with a synthetic face track.
#
#   tools/make_sample_assets.sh [-d seconds] [-H news_height]
set -euo pipefail
cd "$(dirname "$0")/.."
dur=30 h=720
while getopts "d:H:" o; do
  case $o in d) dur=$OPTARG ;; H) h=$OPTARG ;; *) exit 2 ;; esac
done
out=assets/sample
mkdir -p "$out/raw" "$out/pdf_cache"
touch "$out/.gdignore"  # raw library files, not Godot-imported resources
font=$(fc-match -f '%{file}' monospace 2>/dev/null || true)
label() {  # label TEXT -> drawtext filter (or null if no font)
  if [ -n "$font" ]; then
    echo ",drawtext=fontfile=$font:text='$1 %{pts\\:hms}':x=20:y=20:fontsize=28:fontcolor=white:box=1:boxcolor=black@0.6"
  fi
}
gen() {  # gen NAME LAVFI_SOURCE
  ffmpeg -nostdin -loglevel error -y -f lavfi -i "$2" -t "$dur" -pix_fmt yuv420p -c:v libx264 -preset ultrafast "$out/raw/$1.mp4"
}
w=$((h * 16 / 9))
gen news "testsrc2=size=${w}x${h}:rate=30$(label 'NEWS 24')"
gen cam1 "mandelbrot=size=640x360:rate=30,hue=s=0$(label 'CAM 01')"
gen cam2 "life=size=640x360:rate=30:mold=10:ratio=0.1:death_color=#202020:life_color=#a0ffa0,scale=640:360$(label 'CAM 02')"
gen cam3 "cellauto=size=640x360:rate=30:rule=110,scale=640:360$(label 'CAM 03')"
gen cam4 "gradients=size=640x360:rate=30:speed=0.05,hue=s=0.3$(label 'CAM 04')"
tools/transcode.sh -H "$h" "$out" "$out/raw/news.mp4" >/dev/null
tools/transcode.sh -H 360 "$out" "$out"/raw/cam?.mp4 >/dev/null
ffmpeg -nostdin -loglevel error -y -f lavfi -i "testsrc2=size=800x800" -frames:v 1 "$out/face.png"
python3 tools/make_pdf.py "$out/dossier.pdf" \
  "SURVEILLANCE REPORT 07|CLASSIFICATION: RESTRICTED||Subject observed at 02:14.|Vehicle registration withheld.|Signal intercepted on channel 4." \
  "APPENDIX A|TRANSCRIPT|...the meeting will proceed as planned...|...no further contact..." \
  "APPENDIX B|CAMERA INDEX|CAM 01 NORTH GATE|CAM 02 LOBBY|CAM 03 TUNNEL|CAM 04 ROOF"
tools/rasterize_pdf.sh -r 120 "$out/pdf_cache" "$out/dossier.pdf" >/dev/null
rm -rf "$out/raw"

# Synthetic face track for the news clip: a box drifting across the frame.
track=$(python3 -c "
import json, math
print(json.dumps([{'t': i * 0.5, 'boxes': [[0.35 + 0.15 * math.sin(i * 0.3), 0.25, 0.2, 0.35]]} for i in range(int($dur * 2))]))")
cat > "$out/manifest.json" <<EOF
{"version": 1, "assets": [
  {"id": "news", "type": "video", "path": "news.ogv", "metadata": {"face_track": $track}},
  {"id": "cam1", "type": "video", "path": "cam1.ogv"},
  {"id": "cam2", "type": "video", "path": "cam2.ogv"},
  {"id": "cam3", "type": "video", "path": "cam3.ogv"},
  {"id": "cam4", "type": "video", "path": "cam4.ogv"},
  {"id": "face", "type": "image", "path": "face.png", "metadata": {"faces": [[0.3, 0.2, 0.4, 0.5]]}},
  {"id": "doc_p1", "type": "image", "path": "pdf_cache/dossier-1.png", "metadata": {"pdf": "dossier.pdf", "page": 1}},
  {"id": "doc_p2", "type": "image", "path": "pdf_cache/dossier-2.png", "metadata": {"pdf": "dossier.pdf", "page": 2}},
  {"id": "doc_p3", "type": "pdf_page", "path": "dossier.pdf", "page": 3},
  {"id": "ticker", "type": "text", "style": "ticker", "text": "BREAKING  //  SIGNAL LOST ON CHANNEL 4  //  SUBJECT LAST SEEN NORTH GATE 02:14  //  NO FURTHER CONTACT  //"},
  {"id": "caption", "type": "text", "style": "caption", "text": "LIVE  -  4 FEEDS"}
]}
EOF
echo "sample assets in $out"
