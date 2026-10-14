#!/bin/sh
# Runs PortProbe (Linux64 build) for a few seconds in WSL (WSLg) and saves the frame FastCanvas presented:
#   wsl -d Ubuntu-26.04 -- sh tools/run-portprobe-linux.sh <bin dir> <out png> [<seconds>] [PortProbe options]
# The state of earlier starts (/tmp/PortProbe) is cleared first, so FastCanvas is tried.
cd "$(dirname "$0")/.." || exit 1
BIN=$1
SHOT=$2
SECONDS_=${3:-6}
shift 3 2>/dev/null
rm -rf /tmp/PortProbe
mkdir -p "$(dirname "$SHOT")"
ls "$BIN"
timeout $((SECONDS_ + 60)) "$BIN/PortProbe" --seconds="$SECONDS_" --shot="$SHOT" --time=2 "$@"
echo "exit $?"
ls -la "$SHOT"
