# AGENTS.md

Personal fork of **cosmic-comp**, adding Trellis-style fractal/dockable
workspaces. Work is on branch `cosmic-container`. See `docs/DESIGN.md` for the
design and `docs/SANDBOX.md` for the full sandbox guide.

## Build & test (run inside the dev container)

```sh
# one-time
podman build -f Dockerfile.dev -t cosmic-comp-dev .
podman-compose up -d

# compile
podman-compose exec -T dev bash -lc 'cargo check'
podman-compose exec -T dev bash -lc 'cargo build'

# headless boot smoke test (winit + Xvfb)
podman-compose exec -T dev bash /work/scripts/smoke-winit.sh 12

# functional zoom-to-subtree test
podman-compose exec -T dev bash /work/scripts/functional-zoom.sh

# real KMS acceptance test (QEMU guest; TCG, slow — see docs/SANDBOX.md)
podman build -f Dockerfile.vm -t cosmic-comp-vm .
podman-compose run --rm -e BOOT_TIMEOUT=240 vm bash /work/scripts/vm/run-vm.sh

# visual capture (PNGs land in .vm-tmp/screenshots/ on the host)
podman-compose run --rm -e BOOT_TIMEOUT=240 vm bash /work/scripts/vm/screenshot.sh

# interactive host QEMU window (run on the HOST, not in the container)
scripts/vm/interactive.sh
```

There is no unit-test suite for the tiling changes; verify with the scripts
above. Always run at least `cargo check` after editing.

## Critical facts

- **Never test nested in the live session.** Use the container (winit/Xvfb) or,
  for real KMS, a VM.
- The keybind `Action` enum lives in the external crate `cosmic-settings-config`
  from the **forked** `../cosmic-settings-daemon` (branch `cosmic-container`),
  wired in via `[patch]` in the root `Cargo.toml`. Do not bump that fork past
  commit `e37160f1…`.
- **libcosmic must stay pinned to one rev** (`d922ac38…`) across this repo, the
  settings-daemon fork, and `cosmic-comp-config/Cargo.toml`, or Cargo resolves
  two incompatible `cosmic_config` types.
- Upstream defaults `autotile = false`, so new windows float. Tests must set
  `com.system76.CosmicComp/v1/autotile = true`.
- Shortcuts are read from the cosmic-config entry
  `com.system76.CosmicSettings.Shortcuts`; `data/keybindings.ron` is only the
  installed default. Tests copy it into `.../v1/defaults` under `XDG_CONFIG_HOME`.
- The Wayland socket may be `wayland-1`; discover via `$XDG_RUNTIME_DIR/wayland-*`.
- The VM harness needs `evdev` among the guest modules (else no
  `/dev/input/event*` and libinput never sees the virtio keyboard) and must run
  `systemd-udevd` + `udevadm trigger` before cosmic-comp.
- Match the surrounding code style; do **not** add comments unless asked.

## Where things live

- `src/shell/layout/tiling/mod.rs` — tiling tree, layout, `zoom` field and
  `zoom_toggle`/`apply_zoom`/`validate_zoom`.
- `src/shell/workspace.rs` — `zoom_toggle_focused`.
- `src/input/actions.rs` — `Action::ZoomWindow` dispatch.
- `data/keybindings.ron` — default `Super+z` binding.
- `scripts/` — sandbox test scripts + `test-client/toplevel.c`.
