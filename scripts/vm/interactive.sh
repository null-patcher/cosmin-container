#!/usr/bin/env bash
# Run the KMS guest interactively in a real QEMU window.
#
# Builds the guest artifacts inside the `vm` container (into .vm-tmp/), then
# launches the *host's* qemu-system-x86_64 with a graphical display so the
# composited desktop is visible and the keyboard/mouse reach the guest. This is
# a demo/debug tool; the automated pass/fail test is run-vm.sh.
#
# Run this on the host (not inside the container):
#
#   scripts/vm/interactive.sh            # software rendering (reliable)
#   VIRGL=1 scripts/vm/interactive.sh    # virgl/GL acceleration
#   DISPLAY_BACKEND=gtk scripts/vm/interactive.sh
#
# Close the QEMU window to quit. The guest serial console is written to
# .vm-tmp/interactive-serial.log (tail -f it in another terminal to watch boot).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$ROOT/.vm-tmp"
mkdir -p "$TMP"
cd "$ROOT"

DISPLAY_BACKEND="${DISPLAY_BACKEND:-sdl}"
SERIAL="$TMP/interactive-serial.log"

echo "== building guest artifacts in the vm container"
podman-compose run --rm vm bash -lc '
set -e
BUILD=/tmp/vmb; mkdir -p $BUILD
XSD=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
wayland-scanner client-header $XSD $BUILD/xdg-shell-client-protocol.h
wayland-scanner private-code  $XSD $BUILD/xdg-shell-protocol.c
cc -O2 -I$BUILD /work/scripts/test-client/toplevel.c $BUILD/xdg-shell-protocol.c \
   -lwayland-client -o /tmp/cosmic-vm-toplevel
CLIENT=/tmp/cosmic-vm-toplevel bash /work/scripts/vm/build-initramfs.sh \
   /work/.vm-tmp/initramfs.cpio.gz
cp "$(ls /boot/vmlinuz-* | head -1)" /work/.vm-tmp/vmlinuz
'

append="console=ttyS0 rdinit=/init loglevel=4"
gpu=(-vga none -device virtio-gpu-pci)
display="$DISPLAY_BACKEND"
if [ "${VIRGL:-0}" = 1 ]; then
    gpu=(-vga none -device virtio-gpu-gl-pci)
    display="$DISPLAY_BACKEND,gl=on"
    append="$append cosmic_mesa=virtio_gpu"
fi

echo "== launching QEMU ($display); this is TCG, so boot takes a few minutes"
echo "   once the desktop appears, click the window and press Super+z to zoom"
echo "   serial log: $SERIAL"
exec qemu-system-x86_64 \
    -accel tcg,thread=multi \
    -m 2048 -smp 2 \
    -kernel "$TMP/vmlinuz" \
    -initrd "$TMP/initramfs.cpio.gz" \
    -append "$append" \
    "${gpu[@]}" \
    -device virtio-keyboard-pci \
    -device virtio-tablet-pci \
    -display "$display" \
    -serial "file:$SERIAL" \
    -name "cosmic-container KMS demo"
