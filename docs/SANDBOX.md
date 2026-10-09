# Sandboxed development and testing

cosmic-comp is a compositor: running it inside the live COSMIC session would
nest it awkwardly and could disturb the host session. This fork therefore
develops and tests in a **sandbox**, never nested in the daily driver.

Two environments are provided:

| Environment | Purpose | Status |
|-------------|---------|--------|
| podman container + Xvfb (winit backend) | fast compile + headless tests | implemented |
| QEMU guest, virtio-gpu (KMS backend) | real DRM/KMS acceptance | implemented |

## 1. Container + Xvfb (winit)

Everything lives in `Dockerfile.dev` (Debian trixie + full build deps + Rust
1.93 + Xvfb + Mesa llvmpipe + weston/xdotool for tests) and is orchestrated by
`docker-compose.yml`.

The `dev` service mounts:

- this repo at `/work`
- the settings-daemon fork at `/cosmic-settings-daemon` (needed by the
  `[patch]` in `Cargo.toml`)
- named volumes `cargo-registry`, `cargo-git`, `target` for caching

### Build and start

```sh
podman build -f Dockerfile.dev -t cosmic-comp-dev .
podman-compose up -d
```

### Build / check / test

```sh
podman-compose exec -T dev bash -lc 'cargo check'
podman-compose exec -T dev bash -lc 'cargo build'
```

The compositor binary lands at `/work/target/debug/cosmic-comp`.

### Smoke test (does it boot?)

`scripts/smoke-winit.sh` starts an Xvfb X server, runs `cosmic-comp` in the
winit backend with software GL, waits, and succeeds if the compositor stays
alive:

```sh
podman-compose exec -T dev bash /work/scripts/smoke-winit.sh 12
```

Non-fatal noise you will see: `Failed to initialize session DBus connection`
(there is no DBus in the container) and
`EglExtensionNotSupported(["EGL_EXT_device_drm"])` (no DRM device — expected
under winit/Xvfb).

### Functional test: zoom-to-subtree

`scripts/functional-zoom.sh` boots the compositor, maps two resizable
`xdg-shell` test clients (`scripts/test-client/toplevel.c`, built on the fly
with `wayland-scanner`), presses `Super+z`, and asserts the focused client is
reconfigured to a larger geometry, then presses it again and asserts the tile is
restored.

```sh
podman-compose exec -T dev bash /work/scripts/functional-zoom.sh
```

The script sets up the two pieces of config the compositor needs to behave like
a real session:

- `com.system76.CosmicSettings.Shortcuts/v1/defaults` ← `data/keybindings.ron`
  (otherwise **no** shortcuts are bound),
- `com.system76.CosmicComp/v1/autotile` = `true` (upstream defaults
  `autotile=false`, so new windows float and are never tiled).

Successful output ends with:

```
max area before=492352 after=1024000
max area restored=492352
ZOOM OK: tile grew on Super+z and restored on toggle
```

Notes for anyone extending the tests:

- The Wayland socket is usually `wayland-1`, not `wayland-0`; discover it by
  globbing `$XDG_RUNTIME_DIR/wayland-*` (excluding `.lock`).
- The winit backend only receives keyboard input while its X window holds focus;
  the scripts do `xdotool windowfocus --sync <win> && xdotool mousemove` before
  sending keys.
- Some Weston demo clients are unsuitable: `weston-terminal` /
  `weston-simple-shm` set `min_size == max_size`, which makes cosmic-comp treat
  them as dialogs and float them. The custom `toplevel.c` client is resizable
  and tiles correctly.

## 2. QEMU guest with KMS

The container path cannot exercise real DRM/KMS, libinput seats or the session
backend. `scripts/vm/` boots cosmic-comp as the session compositor in a minimal
QEMU guest on the virtio-gpu DRM node, so the KMS code path, libinput device
enumeration and the seatd session are all the real thing.

### Build and run

`Dockerfile.vm` (built as the `vm` service) adds QEMU, a Debian guest kernel
(`/boot/vmlinuz-*`) and the `busybox`/`kmod`/`cpio`/`xz` tooling to the dev
image. `scripts/vm/build-initramfs.sh` packages a bootable initramfs; then
`scripts/vm/run-vm.sh` boots it and drives the acceptance test:

```sh
podman build -f Dockerfile.vm -t cosmic-comp-vm .   # build the vm image
podman-compose run --rm -e BOOT_TIMEOUT=240 vm bash /work/scripts/vm/run-vm.sh
```

There is no `/dev/kvm` in the reference environment, so QEMU runs under TCG and
a full boot takes minutes; pass a large `BOOT_TIMEOUT`. Successful output ends
with:

```
tiled areas before Super+z: {'c1': 492352, 'c2': 492352}
KMS ZOOM OK: tile grew 492352 -> 1024000 -> 492352
```

### How it works

- The initramfs carries memory-only config: `Shortcuts/v1/defaults` from
  `data/keybindings.ron` and `CosmicComp/v1/autotile = true`, both under
  `XDG_CONFIG_HOME=/etc/xdg`.
- `seatd -g root` provides the seat (`LIBSEAT_BACKEND=seatd`); the kernel
  modules are decompressed from `.ko.xz` because busybox `insmod` cannot read a
  compressed module.
- `systemd-udevd` runs before cosmic-comp and `udevadm trigger` populates the
  udev database. **`evdev` must be in the module list** — without
  `/dev/input/event*`, libinput never surfaces the virtio keyboard and no
  shortcuts fire.
- cosmic-comp runs with `COSMIC_BACKEND=kms`, `MESA_LOADER_DRIVER_OVERRIDE=
  kms_swrast` and `LIBGL_ALWAYS_SOFTWARE=1`; virtio-gpu provides the render node
  (`renderD128`) that GBM/EGL needs (the `bochs`/`-vga std` device does not).
- Evidence is the serial console: each client prints `GEOM <tag> <w> <h>` on
  every configure (the QEMU in `Dockerfile.vm` has no screendump-capable
  display). `run-vm.sh` waits for the tiling to settle, sends `sendkey meta_l-z`
  through the QEMU monitor, and asserts the focused tile grows then restores.

### Notes

- The plain `-device virtio-gpu-pci` device plus software `kms_swrast` is used
  because the container QEMU only offers the `none`/`curses` display backends
  (no `egl-headless`), so virgl is unavailable. On a host QEMU with
  `-display egl-headless -device virtio-gpu-gl-pci` you can set
  `MESA_DRIVER=virtio_gpu` for a hardware-ish path.
- `.vm-tmp/` holds the last serial log for debugging and is git-ignored.
