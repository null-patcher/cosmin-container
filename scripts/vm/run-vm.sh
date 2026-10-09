#!/usr/bin/env bash
# KMS acceptance test for the cosmic-container fork, inside QEMU.
#
# Boots cosmic-comp on the real KMS/DRM backend against QEMU's virtio-gpu,
# maps two resizable xdg-shell test clients, then presses Super+z (via the
# QEMU monitor) and asserts that the focused client's tile is zoomed to fill
# the workspace and restored on the second press.
#
# Evidence is taken from the serial console: each client prints
# "GEOM <tag> <w> <h>" for every configure, so no screenshot is needed
# (the QEMU in Dockerfile.vm only offers the none/curses display backends).
#
# No /dev/kvm in the reference environment, so this runs under TCG and is slow
# (boot can take minutes). Run inside the `vm` service:
#
#   podman-compose run --rm vm bash /work/scripts/vm/run-vm.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="${KERNEL:-$(ls /boot/vmlinuz-* | head -1)}"
INITRD="${INITRD:-/tmp/cosmic-vm-initramfs.cpio.gz}"
CLIENT="${CLIENT:-/tmp/cosmic-vm-toplevel}"
SERIAL="${SERIAL:-/tmp/cosmic-vm-serial.log}"
MON="${MON:-/tmp/cosmic-vm-monitor.sock}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
ZOOM_KEY="${ZOOM_KEY:-meta_l-z}"

XSD=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
BUILD=/tmp/cosmic-vm-client

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

echo "== building test client"
mkdir -p "$BUILD"
wayland-scanner client-header "$XSD" "$BUILD/xdg-shell-client-protocol.h"
wayland-scanner private-code  "$XSD" "$BUILD/xdg-shell-protocol.c"
cc -O2 -I"$BUILD" "$HERE/../test-client/toplevel.c" \
    "$BUILD/xdg-shell-protocol.c" -lwayland-client -o "$CLIENT"

CLIENT="$CLIENT" bash "$HERE/build-initramfs.sh" "$INITRD"

rm -f "$SERIAL" "$MON"

echo "kernel: $KERNEL"
echo "booting QEMU under TCG (slow) ..."
qemu-system-x86_64 \
    -accel tcg,thread=multi \
    -m 2048 -smp 2 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "console=ttyS0 rdinit=/init loglevel=4" \
    -vga none \
    -device virtio-gpu-pci \
    -device virtio-keyboard-pci \
    -device virtio-tablet-pci \
    -display none \
    -serial "file:$SERIAL" \
    -monitor "unix:$MON,server=on,wait=off" \
    -no-reboot &
QEMU_PID=$!

python3 - "$SERIAL" "$MON" "$BOOT_TIMEOUT" "$ZOOM_KEY" <<'PY'
import re, socket, sys, time

serial, mon, boot_timeout, zoom_key = (
    sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4],
)

TAGS = ("c1", "c2")
GEOM = re.compile(r"^GEOM (\S+) (\d+) (\d+)$", re.M)


def read_serial():
    try:
        with open(serial) as f:
            return f.read()
    except OSError:
        return ""


def areas():
    """tag -> area of the last GEOM line seen for that tag in the serial log."""
    out = {}
    for tag, w, h in GEOM.findall(read_serial()):
        out[tag] = int(w) * int(h)
    return {t: a for t, a in out.items() if t in TAGS}


def max_area():
    return max(areas().values(), default=0)


def wait_ready(timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        txt = read_serial()
        if "[init] ready" in txt:
            return
        if "Kernel panic" in txt or "[init] cosmic-comp exited" in txt:
            print("FAIL: guest failed during boot; serial tail:")
            print("\n".join(txt.splitlines()[-50:]))
            sys.exit(1)
        time.sleep(1.0)
    print("FAIL: timed out waiting for guest; serial tail:")
    print("\n".join(read_serial().splitlines()[-50:]))
    sys.exit(1)


def settle(timeout=180, quiet=3.0):
    """Block until no new GEOM lines have appeared for `quiet` seconds."""
    last = len(GEOM.findall(read_serial()))
    stable_since = time.monotonic()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(0.5)
        n = len(GEOM.findall(read_serial()))
        if n != last:
            last = n
            stable_since = time.monotonic()
        elif n > 0 and time.monotonic() - stable_since > quiet:
            return


def wait_area_above(threshold, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        area = max_area()
        if area > threshold:
            return area
        time.sleep(0.5)
    return max_area()


def wait_area_at_most(limit, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        area = max_area()
        if 0 < area <= limit:
            return area
        time.sleep(0.5)
    return max_area()


def monitor(cmd):
    for _ in range(100):
        s = socket.socket(socket.AF_UNIX)
        try:
            s.connect(mon)
            break
        except OSError:
            time.sleep(0.2)
    else:
        print("FAIL: could not connect to QEMU monitor")
        sys.exit(1)
    s.sendall((cmd + "\n").encode())
    time.sleep(0.3)
    s.settimeout(0.5)
    try:
        s.recv(4096)
    except OSError:
        pass
    s.close()


wait_ready(boot_timeout)
print("guest ready")
settle()
baseline = areas()
if not baseline:
    print("FAIL: clients produced no GEOM lines; serial tail:")
    print("\n".join(read_serial().splitlines()[-50:]))
    sys.exit(1)
base_area = max(baseline.values())
print("tiled areas before Super+z:", baseline)

monitor("sendkey " + zoom_key)
zoom_area = wait_area_above(base_area, 60)
print("after first Super+z, max area:", zoom_area)

monitor("sendkey " + zoom_key)
restore_area = wait_area_at_most(base_area, 60)
print("after second Super+z, max area:", restore_area)

if zoom_area > base_area and 0 < restore_area <= base_area:
    print(f"KMS ZOOM OK: tile grew {base_area} -> {zoom_area} -> {restore_area}")
    sys.exit(0)
print(f"KMS ZOOM FAIL: base={base_area} zoom={zoom_area} restore={restore_area}")
print("serial tail:")
print("\n".join(read_serial().splitlines()[-60:]))
sys.exit(1)
PY
