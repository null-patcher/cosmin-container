# Sandboxed development and testing

cosmic-comp is a compositor: running it inside the live COSMIC session would
nest it awkwardly and could disturb the host session. This fork therefore
develops and tests in a **sandbox**, never nested in the daily driver.

Two environments are planned:

| Environment | Purpose | Status |
|-------------|---------|--------|
| podman container + Xvfb (winit backend) | fast compile + headless behavioural tests | ready |
| QEMU/KVM VM with virtio-gpu (KMS backend) | real DRM/KMS acceptance | planned |

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

## 2. VM with KMS (planned)

The container path cannot exercise real DRM/KMS, libinput seats or the session
backend. For acceptance testing, run cosmic-comp as the session compositor in a
QEMU/KVM guest with a virtio-gpu display:

1. Boot a VM (QEMU `-device virtio-vga-gl` / `virtio-gpu`, `-display sdl` or a
   VNC/SPICE display) with a minimal Linux + the same Mesa/DRM userspace.
2. Start cosmic-comp on the DRM node (`COSMIC_BACKEND` unset, no
   `DISPLAY`/`WAYLAND_DISPLAY`) inside a seat (logind/libseat).
3. Drive it with a Wayland client and real input, and capture the framebuffer.

This environment is not scripted yet; it is the remaining task for real KMS
coverage.
