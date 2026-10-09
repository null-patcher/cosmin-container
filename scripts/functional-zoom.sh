#!/usr/bin/env bash
# Functional check for zoom-to-subtree (Action::ZoomWindow / Super+z).
#
# Boots cosmic-comp (winit) under a bare Xvfb, maps two resizable xdg-shell
# test clients, then presses Super+z and asserts that the focused client is
# reconfigured to a substantially larger geometry (i.e. its tile was zoomed to
# fill the workspace). Intended to run inside the dev container.
#
#   podman-compose exec -T dev bash /work/scripts/functional-zoom.sh
set -u

COMP="${COMP:-/work/target/debug/cosmic-comp}"
SRC="$(cd "$(dirname "$0")" && pwd)/test-client"
DISPLAY_NUM="${DISPLAY_NUM:-:99}"
RUNTIME=/tmp/xdg-func
LOG=/tmp/functional-zoom.log
XSD=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
BUILD=/tmp/zoom-client

cleanup() {
    [ -n "${C1:-}" ] && kill "$C1" 2>/dev/null
    [ -n "${C2:-}" ] && kill "$C2" 2>/dev/null
    [ -n "${COMP_PID:-}" ] && kill "$COMP_PID" 2>/dev/null
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$BUILD"
wayland-scanner client-header "$XSD" "$BUILD/xdg-shell-client-protocol.h"
wayland-scanner private-code  "$XSD" "$BUILD/xdg-shell-protocol.c"
cc -O2 -I"$BUILD" "$SRC/toplevel.c" "$BUILD/xdg-shell-protocol.c" -lwayland-client -o "$BUILD/toplevel"

pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null
rm -rf "$RUNTIME"; mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME"
export XDG_RUNTIME_DIR="$RUNTIME"
export XDG_CONFIG_HOME="$RUNTIME/config"
export XDG_DATA_HOME="$RUNTIME/data"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
# The Shortcuts config (incl. our Super+z ZoomWindow default) is read from
# cosmic-config; install the repo's defaults so shortcuts are actually bound.
KDIR="$XDG_CONFIG_HOME/cosmic/com.system76.CosmicSettings.Shortcuts/v1"
mkdir -p "$KDIR"
cp "$(dirname "$0")/../data/keybindings.ron" "$KDIR/defaults"
# Enable autotiling for the workspace (defaults to false, i.e. floating).
CDIR="$XDG_CONFIG_HOME/cosmic/com.system76.CosmicComp/v1"
mkdir -p "$CDIR"
printf 'true' >"$CDIR/autotile"

Xvfb "$DISPLAY_NUM" -screen 0 1280x720x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
XVFB_PID=$!
sleep 1
export DISPLAY="$DISPLAY_NUM"

COSMIC_BACKEND=winit LIBGL_ALWAYS_SOFTWARE=1 RUST_LOG="${RUST_LOG:-warn}" \
    "$COMP" --no-xwayland >"$LOG" 2>&1 &
COMP_PID=$!

for i in $(seq 1 30); do
    SOCK=$(ls "$RUNTIME"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -n1)
    [ -n "$SOCK" ] && break
    kill -0 "$COMP_PID" 2>/dev/null || { echo "compositor died early"; tail -n 30 "$LOG"; exit 1; }
    sleep 0.5
done
SOCK=$(ls "$RUNTIME"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -n1)
[ -n "$SOCK" ] || { echo "no wayland socket"; tail -n 30 "$LOG"; exit 1; }
export WAYLAND_DISPLAY=$(basename "$SOCK")
echo "using $WAYLAND_DISPLAY"
sleep 2

TEST_COLOR=0xff3060a0 "$BUILD/toplevel" >/tmp/fz-c1.log 2>&1 &
C1=$!
sleep 1.5
TEST_COLOR=0xffa06030 "$BUILD/toplevel" >/tmp/fz-c2.log 2>&1 &
C2=$!
sleep 2.5

BEFORE_LINES=$(grep -c '^CONFIGURE' /tmp/fz-c2.log 2>/dev/null || echo 0)
echo "focused client configures before Super+z:"
grep '^CONFIGURE' /tmp/fz-c2.log || echo "  (none)"

WID=$(xdotool search --onlyvisible --name "." 2>/dev/null | head -n1)
[ -n "$WID" ] && { xdotool windowraise "$WID" 2>/dev/null; xdotool windowfocus --sync "$WID" 2>/dev/null; }
xdotool mousemove 640 360
sleep 0.5
xdotool key --clearmodifiers super+z
sleep 3

echo "focused client configures after Super+z:"
AFTER=$(grep '^CONFIGURE' /tmp/fz-c2.log | tail -n +$((BEFORE_LINES + 1)))
echo "$AFTER"

area() { awk '{print $2 * $3}' <<<"$1" | sort -n | tail -1; }
BEFORE_AREA=$(area "$(grep '^CONFIGURE' /tmp/fz-c2.log | head -n "$BEFORE_LINES")")
AFTER_AREA=$(area "$AFTER")
echo "max area before=$BEFORE_AREA after=$AFTER_AREA"

# Toggling again should restore the original tile.
ZOOM_LINES=$(grep -c '^CONFIGURE' /tmp/fz-c2.log)
xdotool key --clearmodifiers super+z
sleep 3
RESTORE=$(grep '^CONFIGURE' /tmp/fz-c2.log | tail -n +$((ZOOM_LINES + 1)))
echo "focused client configures after second Super+z:"
echo "$RESTORE"
RESTORE_AREA=$(area "$RESTORE")
echo "max area restored=$RESTORE_AREA"

if [ "${AFTER_AREA:-0}" -gt "${BEFORE_AREA:-0}" ] 2>/dev/null \
    && [ "${RESTORE_AREA:-0}" -le "${AFTER_AREA:-0}" ] 2>/dev/null \
    && [ "${RESTORE_AREA:-0}" -gt 0 ] 2>/dev/null; then
    echo "ZOOM OK: tile grew on Super+z and restored on toggle"
    exit 0
fi
echo "ZOOM FAIL: unexpected geometry (before=$BEFORE_AREA zoom=$AFTER_AREA restore=$RESTORE_AREA)"
tail -n 30 "$LOG"
exit 1
