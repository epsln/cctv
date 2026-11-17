#!/usr/bin/env bash
# Rasterize PDF pages to PNG using the naming PdfPageSource expects:
#   <OUTDIR>/<stem>-<page>.png
#
#   tools/rasterize_pdf.sh [-r dpi] [-f first] [-l last] OUTDIR FILE.pdf...
set -euo pipefail
dpi=150 first="" last=""
while getopts "r:f:l:" o; do
  case $o in
    r) dpi=$OPTARG ;;
    f) first=$OPTARG ;;
    l) last=$OPTARG ;;
    *) sed -n '2,6p' "$0"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 2 ] || { sed -n '2,6p' "$0"; exit 2; }
out=$1; shift
mkdir -p "$out"
for pdf in "$@"; do
  stem=$(basename "${pdf%.*}")
  pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/^Pages:/ {print $2}')
  [ -n "$pages" ] || { echo "cannot read $pdf" >&2; exit 1; }
  for ((p = ${first:-1}; p <= ${last:-$pages}; p++)); do
    pdftoppm -png -r "$dpi" -f "$p" -l "$p" -singlefile "$pdf" "$out/$stem-$p"
    echo "$out/$stem-$p.png"
  done
done
