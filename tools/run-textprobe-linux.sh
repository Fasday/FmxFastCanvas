#!/bin/sh
# Runs TextProbe (Linux64 build) with each engine it has, in WSL (WSLg's X server, lavapipe):
#   wsl -d Ubuntu-26.04 -- sh tools/run-textprobe-linux.sh [<bin dir>] [<out dir>] [<paragraphs>] [<skia paragraphs>]
# Out: <out>/pango and, when libsk4d.so is next to the program, <out>/skia (text.png, numbers.txt, bench.txt).
# Skia's paragraphs take tens of milliseconds each on Linux: its benchmark has fewer (default 30).
cd "$(dirname "$0")/.." || exit 1
BIN=${1:-bin/Linux64/Release}
OUT=${2:-results/raw/textprobe/linux}
BENCH=${3:-300}
SKIABENCH=${4:-30}
mkdir -p "$OUT"
timeout 120 "$BIN/TextProbe" --engine=native --out="$OUT/pango" --bench="$BENCH"
echo "pango: exit $?"
if [ -f "$BIN/libsk4d.so" ]; then
  timeout 300 "$BIN/TextProbe" --engine=skia --out="$OUT/skia" --bench="$SKIABENCH"
  echo "skia: exit $?"
fi
