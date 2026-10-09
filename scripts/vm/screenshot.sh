#!/usr/bin/env bash
# Capture PNG screenshots of the KMS session inside QEMU.
#
# Boots cosmic-comp on the virtio-gpu DRM node, maps two tiled test clients and
# writes three PNGs showing the tiled layout, the zoomed tile after Super+z, and
# the restored layout. QEMU's monitor "screendump" grabs the real virtio-gpu
# framebuffer, so this works with -display none.
#
# Run inside the `vm` service; the PNGs land in $OUTDIR (default
# /work/.vm-tmp/screenshots, i.e. .vm-tmp/screenshots on the host):
#
#   podman-compose run --rm -e BOOT_TIMEOUT=240 vm bash /work/scripts/vm/screenshot.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="${KERNEL:-$(ls /boot/vmlinuz-* | head -1)}"
INITRD="${INITRD:-/tmp/cosmic-vm-initramfs.cpio.gz}"
CLIENT="${CLIENT:-/tmp/cosmic-vm-toplevel}"
SERIAL="${SERIAL:-/tmp/cosmic-vm-serial.log}"
MON="${MON:-/tmp/cosmic-vm-monitor.sock}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
ZOOM_KEY="${ZOOM_KEY:-meta_l-z}"
OUTDIR="${OUTDIR:-/work/.vm-tmp/screenshots}"

XSD=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
BUILD=/tmp/cosmic-vm-client

mkdir -p "$OUTDIR"

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

python3 - "$SERIAL" "$MON" "$BOOT_TIMEOUT" "$ZOOM_KEY" "$OUTDIR" <<'PY'
import os, re, socket, subprocess, sys, time

serial, mon, boot_timeout, zoom_key, outdir = (
    sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4], sys.argv[5],
)

GEOM = re.compile(r"^GEOM (\S+) (\d+) (\d+)$", re.M)


def read_serial():
    try:
        with open(serial) as f:
            return f.read()
    except OSError:
        return ""


def max_area():
    out = {}
    for tag, w, h in GEOM.findall(read_serial()):
        out[tag] = int(w) * int(h)
    return max(out.values(), default=0)


def wait_ready(timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if "[init] ready" in read_serial():
            return
        time.sleep(1.0)
    print("FAIL: timed out waiting for guest")
    sys.exit(1)


def settle(timeout=180, quiet=3.0):
    last = len(GEOM.findall(read_serial()))
    stable_since = time.monotonic()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(0.5)
        n = len(GEOM.findall(read_serial()))
        if n != last:
            last, stable_since = n, time.monotonic()
        elif n > 0 and time.monotonic() - stable_since > quiet:
            return


def tags_seen():
    return {t for t, _, _ in GEOM.findall(read_serial())}


# A tile occupies roughly half the output; a zoom fills nearly all of it. The
# threshold sits between the two so transient configures do not fool us.
FULL = 1280 * 800
HALF_LIMIT = int(FULL * 0.7)


def wait_tiled(timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        settle(timeout=20)
        if tags_seen() >= {"c1", "c2"} and max_area() < HALF_LIMIT:
            return
        time.sleep(1.0)


def wait_area(test, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if test(max_area()):
            return
        time.sleep(0.5)


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


def shot(name):
    ppm = os.path.join(outdir, name + ".ppm")
    png = os.path.join(outdir, name + ".png")
    for _ in range(10):
        monitor("screendump " + ppm)
        for _ in range(50):
            if os.path.exists(ppm) and os.path.getsize(ppm) > 0:
                break
            time.sleep(0.2)
        time.sleep(0.3)
        if subprocess.run(["convert", ppm, png]).returncode == 0:
            os.remove(ppm)
            print("wrote", png)
            return
    print("WARN: could not capture", name)


wait_ready(boot_timeout)
print("guest ready")
wait_tiled()
base = max_area()
print("tiled, max area", base)
time.sleep(3)
shot("1-tiled")

monitor("sendkey " + zoom_key)
wait_area(lambda a: a > HALF_LIMIT, 60)
time.sleep(5)
shot("2-zoomed")

monitor("sendkey " + zoom_key)
wait_area(lambda a: 0 < a < HALF_LIMIT, 60)
time.sleep(5)
shot("3-restored")

print("screenshots in", outdir)
PY
