#!/bin/sh
# Runs TextProbe (Linux64 build) with each engine it has, in WSL (WSLg's X server, lavapipe):
#   wsl -d Ubuntu-26.04 -- sh tools/run-textprobe-linux.sh [<bin dir>] [<out dir>] [<bench paragraphs>]
# Out: <out>/pango and, when libsk4d.so is next to the program, <out>/skia (text.png, numbers.txt, bench.txt).
cd "$(dirname "$0")/.." || exit 1
BIN=${1:-bin/Linux64/Release}
OUT=${2:-results/raw/textprobe/linux}
BENCH=${3:-300}
mkdir -p "$OUT"
timeout 120 "$BIN/TextProbe" --engine=native --out="$OUT/pango" --bench="$BENCH"
echo "pango: exit $?"
if [ -f "$BIN/libsk4d.so" ]; then
  timeout 120 "$BIN/TextProbe" --engine=skia --out="$OUT/skia" --bench="$BENCH"
  echo "skia: exit $?"
fi
