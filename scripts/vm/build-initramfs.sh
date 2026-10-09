#!/usr/bin/env bash
# Build a bootable initramfs that runs cosmic-comp on the KMS/DRM backend.
#
# Packages:
#   - busybox (static) as pid 1 + shell
#   - cosmic-comp (stripped), a seatd, and the test client
#   - just enough Mesa (virtio_gpu + swrast DRI) for EGL/GBM
#   - the virtio-gpu / virtio-input kernel modules and their dependencies
#
# The result is consumed by run-vm.sh. Intended to run inside the vm image
# (Dockerfile.vm), which provides the guest kernel and QEMU.
set -euo pipefail

OUT="${1:-/tmp/cosmic-vm-initramfs.cpio.gz}"
HERE="$(cd "$(dirname "$0")" && pwd)"
COMP="${COMP:-/work/target/debug/cosmic-comp}"
CLIENT="${CLIENT:-/tmp/cosmic-vm-toplevel}"
VER="$(ls /usr/lib/modules | head -1)"
ROOT=/tmp/cosmic-vm-root
LIB=/usr/lib/x86_64-linux-gnu

rm -rf "$ROOT" "$OUT"
mkdir -p "$ROOT"/{bin,sbin,usr/bin,usr/sbin,usr/lib,lib64,etc,proc,sys,dev,run,tmp}

copy_with_libs() {
    local src="$1" dest="$2"
    mkdir -p "$ROOT$(dirname "$dest")"
    cp "$src" "$ROOT$dest"
    copy_libs_of "$src"
}

copy_libs_of() {
    while read -r lib; do
        [ -e "$lib" ] || continue
        [ -e "$ROOT$lib" ] && continue
        mkdir -p "$ROOT$(dirname "$lib")"
        cp "$lib" "$ROOT$lib"
    done < <(ldd "$1" | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i}')
}

# --- static busybox ---
cp "$(command -v busybox)" "$ROOT/bin/busybox"
chmod +x "$ROOT/bin/busybox"

# --- userspace programs ---
copy_with_libs "$COMP" /usr/bin/cosmic-comp
strip --strip-all "$ROOT/usr/bin/cosmic-comp" 2>/dev/null || true
copy_with_libs "$CLIENT" /usr/bin/toplevel
copy_with_libs "$(command -v seatd)" /usr/sbin/seatd

# --- udev (libinput enumerates input devices via the udev database) ---
copy_with_libs "$(command -v udevadm)" /usr/bin/udevadm
mkdir -p "$ROOT/lib/systemd" "$ROOT/etc/udev/rules.d" "$ROOT/run/udev"
ln -sf /usr/bin/udevadm "$ROOT/lib/systemd/systemd-udevd"
if [ -d /usr/lib/udev ]; then
    mkdir -p "$ROOT/usr/lib/udev"
    cp -a /usr/lib/udev/. "$ROOT/usr/lib/udev/"
    for h in "$ROOT"/usr/lib/udev/*; do
        [ -f "$h" ] && [ -x "$h" ] && copy_libs_of "${h#"$ROOT"}"
    done
fi

# --- Mesa bits that are dlopen()ed (invisible to ldd) ---
for f in "$LIB"/libgallium-*.so* "$LIB"/libEGL_mesa.so.0 "$LIB"/libEGL.so.1 \
         "$LIB"/libGLESv2.so.2 "$LIB"/libGLdispatch.so.0 "$LIB"/libgbm.so.1 \
         "$LIB"/libGLX.so.0 "$LIB"/libOpenGL.so.0; do
    [ -e "$f" ] || continue
    mkdir -p "$ROOT$(dirname "$f")"
    cp -L "$f" "$ROOT$f"
    copy_libs_of "$f"
done
mkdir -p "$ROOT$LIB/dri"
for d in virtio_gpu_dri.so swrast_dri.so kms_swrast_dri.so; do
    [ -e "$LIB/dri/$d" ] || continue
    cp -L "$LIB/dri/$d" "$ROOT$LIB/dri/"
    copy_libs_of "$LIB/dri/$d"
done
# libgbm's DRI backend plugin (dlopen'ed from <libdir>/gbm/).
if [ -d "$LIB/gbm" ]; then
    mkdir -p "$ROOT$LIB/gbm"
    for g in "$LIB"/gbm/*.so; do
        [ -e "$g" ] || continue
        cp -L "$g" "$ROOT$LIB/gbm/"
        copy_libs_of "$g"
    done
fi
# glvnd EGL vendor config, so libEGL.so.1 loads Mesa (which provides the GBM
# platform extension) instead of the empty dispatch stub.
if [ -d /usr/share/glvnd/egl_vendor.d ]; then
    mkdir -p "$ROOT/usr/share/glvnd/egl_vendor.d"
    cp /usr/share/glvnd/egl_vendor.d/*.json "$ROOT/usr/share/glvnd/egl_vendor.d/"
fi

# --- cosmic-config defaults (read from XDG_CONFIG_HOME by the guest) ---
CFG="$ROOT/etc/xdg"
KDIR="$CFG/cosmic/com.system76.CosmicSettings.Shortcuts/v1"
CDIR="$CFG/cosmic/com.system76.CosmicComp/v1"
mkdir -p "$KDIR" "$CDIR"
cp "$HERE/../../data/keybindings.ron" "$KDIR/defaults"
printf 'true' >"$CDIR/autotile"

# xkb data (xkeyboard-config) and libinput quirks are looked up by absolute path.
mkdir -p "$ROOT/usr/share/X11"
cp -a /usr/share/X11/xkb "$ROOT/usr/share/X11/xkb"
if [ -d /usr/share/libinput ]; then
    mkdir -p "$ROOT/usr/share/libinput"
    cp -a /usr/share/libinput/. "$ROOT/usr/share/libinput/"
fi

# Minimal account database (seatd looks groups up by name).
printf 'root:x:0:0:root:/root:/bin/sh\n' >"$ROOT/etc/passwd"
printf 'root:x:0:\nvideo:x:44:\ninput:x:999:\n' >"$ROOT/etc/group"

# --- kernel modules (ordered, dependency-first, from modprobe) ---
# busybox insmod cannot read .ko.xz, so decompress each module up front.
# modprobe accepts a single module per call; query each and dedupe while
# preserving the dependency-first order.
: >/tmp/cosmic-vm-modsrc.list
for mod in virtio_gpu virtio_input bochs evdev mousedev; do
    modprobe -S "$VER" --show-depends "$mod" 2>/dev/null \
        | awk '$1 == "insmod" {print $2}' >>/tmp/cosmic-vm-modsrc.list || true
done
awk '!/^$/ && !seen[$0]++' /tmp/cosmic-vm-modsrc.list >/tmp/cosmic-vm-modsrc.uniq
: >"$ROOT/modules.list"
while read -r m; do
    [ -n "$m" ] || continue
    dest="${m%.xz}"
    if [ "$dest" != "$m" ]; then
        mkdir -p "$ROOT$(dirname "$dest")"
        xz -dc "$m" >"$ROOT$dest"
    else
        mkdir -p "$ROOT$(dirname "$m")"
        cp "$m" "$ROOT$m"
    fi
    echo "$dest" >>"$ROOT/modules.list"
done </tmp/cosmic-vm-modsrc.uniq

# --- init (pid 1) ---
cat >"$ROOT/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox --install -s /bin
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
LOG=/dev/console
exec >"$LOG" 2>&1

echo "[init] mounting filesystems"
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /run /tmp

# Optional overrides from the kernel command line (used by the interactive and
# virgl QEMU paths). e.g. cosmic_mesa=virtio_gpu cosmic_log=debug
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        cosmic_mesa=*) MESA_DRIVER="${arg#cosmic_mesa=}" ;;
        cosmic_log=*) RUST_LOG="${arg#cosmic_log=}" ;;
    esac
done

echo "[init] loading kernel modules"
while read -r m; do
    [ -n "$m" ] || continue
    insmod "$m" || echo "[init] insmod $m failed"
done </modules.list
echo "[init] modules loaded; dmesg tail:"
dmesg | tail -n 25
echo "[init] /proc/modules:"; cat /proc/modules

echo "[init] waiting for DRM device"
i=0
while [ ! -e /dev/dri/card0 ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
ls -l /dev/dri 2>&1 || true
ls -l /sys/class/drm 2>&1 || true

export XDG_RUNTIME_DIR=/run/xdg
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export HOME=/root
export XDG_CONFIG_HOME=/etc/xdg
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu
export SEATD_SOCK=/run/seatd.sock
export LIBSEAT_BACKEND=seatd

echo "[init] starting seatd"
/usr/sbin/seatd -g root &
sleep 1

export COSMIC_BACKEND=kms
export RUST_LOG="${RUST_LOG:-warn}"
export MESA_LOADER_DRIVER_OVERRIDE="${MESA_DRIVER:-kms_swrast}"
export LIBGL_ALWAYS_SOFTWARE=1

echo "[init] starting udevd"
/lib/systemd/systemd-udevd --daemon
sleep 1
udevadm trigger --action=add
udevadm settle --timeout=15
i=0
while ! ls /dev/input/event* >/dev/null 2>&1 && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
echo "[init] input devices:"; ls -l /dev/input 2>&1 || true

echo "[init] starting cosmic-comp"
/usr/bin/cosmic-comp --no-xwayland &
COSMIC_PID=$!

echo "[init] waiting for Wayland socket"
i=0
while ! ls "$XDG_RUNTIME_DIR"/wayland-* >/dev/null 2>&1; do
    if ! kill -0 "$COSMIC_PID" 2>/dev/null; then
        echo "[init] cosmic-comp exited during startup"
        break
    fi
    [ "$i" -ge 150 ] && { echo "[init] timed out waiting for socket"; break; }
    sleep 0.2
    i=$((i + 1))
done
WAYLAND_DISPLAY="$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1)")"
export WAYLAND_DISPLAY
echo "[init] wayland socket: ${WAYLAND_DISPLAY:-none}"

echo "[init] launching test clients"
TEST_TAG=c1 TEST_COLOR=0xff3060a0 /usr/bin/toplevel &
sleep 2
TEST_TAG=c2 TEST_COLOR=0xffa06030 /usr/bin/toplevel &
echo "[init] ready"

while true; do sleep 3600; done
INIT
chmod +x "$ROOT/init"

echo "[initramfs] packing $OUT (COSMIC_BACKEND config lives in init)"
( cd "$ROOT" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -1 ) >"$OUT"
ls -lh "$OUT"
