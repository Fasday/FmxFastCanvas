#!/bin/sh
# Inside a container or a WSL distribution without a screen (tools\linux-compat.ps1): the distribution, its glibc and
# Vulkan devices, then PortProbe on a private Xvfb (FMX's Linux platform: GTK 3 on X11; Vulkan on Mesa's lavapipe)
# for a few seconds, with the frame FastCanvas presented last saved as a PNG.
#
#   linux-compat.sh <out-dir> <program> [args...]
set -u
OUT="$1"; shift
PROG="$1"; shift
mkdir -p "$OUT"
. /etc/os-release
echo "$PRETTY_NAME, glibc $(getconf GNU_LIBC_VERSION | awk '{print $2}')" > "$OUT/system.txt"
# A fresh state of PortProbe (it remembers failed starts) and of FMX's libfmux copy.
STATE=$(mktemp -d /tmp/portprobe-home.XXXXXX)
export HOME="$STATE" TMPDIR="$STATE"
unset WAYLAND_DISPLAY
D=:$(( $$ % 400 + 100 ))
Xvfb "$D" -screen 0 1280x1024x24 -nolisten tcp > "$OUT/xvfb.log" 2>&1 &
XPID=$!
i=0
while [ ! -S "/tmp/.X11-unix/X${D#:}" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
export DISPLAY="$D"
cd "$(dirname "$PROG")"
timeout 90 "$PROG" "$@" > "$OUT/program.log" 2>&1
echo "exit=$?" >> "$OUT/program.log"
for f in fastcanvas-failed.txt fastcanvas-pending.txt fmx-next.txt; do
  [ -f "$STATE/PortProbe/$f" ] && echo "state: $f: $(cat "$STATE/PortProbe/$f")" >> "$OUT/program.log"
done
for f in "$STATE"/.fmxlinux/*.so; do
  [ -f "$f" ] && echo "libfmux: $(basename "$f")" >> "$OUT/program.log"
done
kill $XPID 2>/dev/null
wait $XPID 2>/dev/null
rm -rf "$STATE"
