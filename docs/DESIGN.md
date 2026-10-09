# Trellis-style fractals in cosmic-comp — design

This document describes the goal, the gap analysis against upstream
cosmic-comp, and the incremental milestone plan. Milestone 1 (zoom-to-subtree)
is implemented; later milestones are planned.

## Objective

Give the COSMIC compositor a Trellis-like model of *fractal, dockable
workspaces*: windows tile into nested split/stack groups, and any group (a
"fractal" / panel) can be **zoomed** to fill the workspace while the rest of the
layout stays alive underneath. Native Wayland/X11 windows only.

## What upstream already gives us

Exploration of upstream (branch `master` @ `4d14528f`) established that most of
the Trellis *layout* model already exists:

- The tiling layer stores a tree of nodes (`Data::Group` with an orientation and
  child sizes, `Data::Stack`, `Data::Mapped`, `Data::Placeholder`).
- Dragging a tiled window enters the overview, a `TargetZone` previews the drop
  target, and `drop_window` inserts the window as a nested split or stack — i.e.
  **drag-to-split/stack already works**.

The genuinely missing pieces versus Trellis are:

1. **Zoom-to-subtree** — there is no per-group zoom. (`src/shell/zoom.rs` is the
   unrelated accessibility magnifier.) **This is Milestone 1.**
2. **Layout persistence** — the tiling tree is never serialized; there is no
   restore across sessions.
3. **Direct (non-overview) edge docking** — docking currently requires going
   through the overview/drag flow rather than dropping on a screen edge.

## Milestone plan

| # | Milestone | Status |
|---|-----------|--------|
| M1 | Zoom-to-subtree (`Action::ZoomWindow`) | **done** |
| M2 | Persist/restore the tiling tree per workspace/output | designed |
| M3 | Direct edge docking without entering the overview | planned |
| M4 | Polish: animations, window-menu entry, multi-output | planned |

## M1 — Zoom-to-subtree

### Semantics

`Super+z` (default binding) toggles zoom on the focused window's tiling node:

- If nothing is zoomed, the node becomes the zoom target and its subtree is
  scaled up to fill the workspace's usable area.
- If that node is already the target, zoom is cleared and the previous layout is
  restored.
- Windows outside the target subtree are **parked** off-screen but remain
  mapped, so their clients/surfaces stay alive (no unmap, no loss of state).
  This is the key difference from `Maximize`: untouched windows are not
  reconfigured and keep running underneath the zoom.
- Non-tiled (floating) windows and fullscreen windows are unaffected; zoom is a
  no-op if the focused window is not in the tiling tree.

### Implementation

State lives on `TilingLayout` (`src/shell/layout/tiling/mod.rs`):

- `zoom: Option<NodeId>` — the currently zoomed node.
- `zoom_toggle(&mut self, mapped: &CosmicMapped)` — resolves the window's node
  via `CosmicMapped::tiling_node_id`, flips `zoom`, and `recalculate()`s.
- `zoom_target(&self)` / `validate_zoom(&mut self)` — accessor and
  garbage-collector for stale targets (a zoomed window may close or move out of
  the tree). `validate_zoom` runs at the end of `refresh()`.
- `recalculate()` threads `self.zoom` into
  `update_positions(output, tree, gaps, zoom)`.

`update_positions` lays the tree out as before, then, when a zoom target is set,
calls `apply_zoom`:

- `parked_geometry()` = a 1×1 rectangle at `(-1_000_000, -1_000_000)`. Because
  input hit-testing (`toplevel_element_under`, `popup_element_under`,
  `mapped()`) is driven by each node's `last_geometry`, moving it here makes the
  window neither visible nor clickable, without a client round-trip.
- `apply_zoom(output, tree, target, full, &mut configures)` walks the target
  subtree, affine-scales each node's geometry from the target's bounding box to
  `full` (the usable output area), and pushes a `configure` for each affected
  `CosmicMapped` (skipping fullscreen/maximized ones). Every node *outside* the
  subtree is parked via `last_geometry`.

The action is dispatched from `src/input/actions.rs` (`Action::ZoomWindow`),
which resolves the focused output and calls
`Workspace::zoom_toggle_focused(seat)` in `src/shell/workspace.rs`; that mirrors
`toggle_floating_window_focused` and forwards to `tiling_layer.zoom_toggle`.

### The keybinding problem and the daemon fork

`Action` is **not** defined in this repository: it comes from the external crate
`cosmic-settings-config` (from `cosmic-settings-daemon`). To add a
`ZoomWindow` variant we fork that crate:

- Fork: `../cosmic-settings-daemon`, branch `cosmic-container`, based on the
  exact commit cosmic-comp's `Cargo.lock` already pins
  (`e37160f14d1e7ee428f973cd2848b4e95f83dfe1`, config crate 0.1.0). Newer HEAD
  would drag in a newer libcosmic.
- `config/src/shortcuts/action.rs` gains `ZoomWindow`.
- cosmic-comp's root `Cargo.toml` adds a `[patch]` pointing
  `cosmic-settings-config` (and `cosmic-settings-daemon-config`) at the fork.

All libcosmic references on both sides are pinned to the **same** revision
(`d922ac380134c00208d2acf93947d44fb217eec5`), otherwise Cargo resolves two
libcosmic revs and two incompatible `cosmic_config::Config` types.

The default binding is added to this repo's `data/keybindings.ron`
(`Super+z`). Note that shortcuts are ultimately read from the cosmic-config
entry `com.system76.CosmicSettings.Shortcuts` — the RON file is the distro
default installed to the system config path, not compiled in.

### Known limitations / follow-ups

- **Gaps are not yet accounted for** in `apply_zoom`'s target bounding box; the
  zoomed subtree currently fills the whole output including where outer
  gaps/panels would sit. Fine for M1, refine in M4.
- **Animations**: the transform is applied instantly on the next tree push; it
  does not animate from the previous geometry like move/resize grabs do.
- **Window menu**: a "Zoom to workspace" entry is available in the window
  context menu (`src/shell/grabs/menu/default.rs`), in addition to `Super+z`.
- Parking relies on `last_geometry`; if a future change starts using
  `last_geometry` for rendering or hit-testing elsewhere, revisit.

## M2 — Persist/restore the tiling tree

> Status: implemented (in progress). Decisions: match by **app_id first,
> title as tie-breaker**; **opt-in** behind a `CosmicCompConfig` flag (default
> off, like `autotile`); key saved layouts by **output name + workspace index**.

### Goal

After a session restart, reconstruct each workspace's tiling shape (nested
split/stack structure, orientation and relative sizes) and re-seat the windows
that map back into it. Only the *shape* is persisted — absolute pixel geometry
is recomputed from the output at restore time.

### Data model

Add a serde model to `cosmic-comp-config` (it must not depend on smithay, so
orientation is a `bool`) and expose it on `CosmicCompConfig` as
`saved_tiling: Vec<SavedLayout>`:

```rust
pub struct SavedLayout {
    pub output: String,   // output name
    pub index: usize,     // workspace index within the output
    pub root: SavedNode,
}

pub enum SavedNode {
    Group { vertical: bool, sizes: Vec<i32>, children: Vec<SavedNode> },
    Leaf  { windows: Vec<SavedWindow> }, // stack order, back-to-front
}

pub struct SavedWindow { pub app_id: String, pub title: String }
```

Mapping from the live tree:

- `Data::Group` → `SavedNode::Group` (orientation + `sizes` + children).
- `Data::Mapped` → `SavedNode::Leaf`, one `SavedWindow` per `CosmicSurface`
  (`app_id()` + `title()`), in stack order.
- `Data::Placeholder` → skipped (collapsed).
- `zoom` is **not** persisted; `parked_geometry` is ignored.

### Save

- `TilingLayout::save_snapshot() -> Option<SavedNode>` serializes a non-empty
  tiling tree.
- `Workspaces::persist_tiling()` walks `sets`/`workspaces`, snapshots each, and
  writes the whole `Vec<SavedLayout>` with
  `cosmic_helper.set("saved_tiling", …)` (the same mechanism as
  `pinned_workspaces`).
- Triggered next to tiling recalculation (`refresh`) but **debounced**: write
  only when the snapshot changed and at most ~once per second, so drags don't
  hammer the disk. `Workspace` already carries a `dirty: AtomicBool`.

### Restore

- `Config::load` already materializes `CosmicCompConfig`; `Workspaces` keeps
  `saved_tiling`, mirroring `pinned_workspaces`.
- When a `Workspace`/`TilingLayout` is created, if a saved layout matches its
  output (+ index) the tree is seeded with the skeleton: `Group` nodes with the
  saved orientation/sizes, and each `Leaf` becomes a `Data::Placeholder` tagged
  with that leaf's expected `(app_id, title)` list.
- As windows map, a window replaces the first placeholder whose expected list
  contains its `app_id` (title only as a tie-breaker), preserving the saved
  sibling order.
- Dangling placeholders are dropped once the window set settles (or after a
  short timeout); windows that match nothing insert as usual.

### Interaction with M1

`zoom` is cleared before snapshotting and on restore (parked geometry is not
meaningful to persist). Otherwise zoom and persistence are orthogonal.

### Decisions

1. **Identity key** — match by `app_id` first, `title` only as a tie-breaker;
   consume matching placeholders in map order.
2. **Trigger** — opt-in via a `CosmicCompConfig` flag
   (`persist_tiling`, default off, like `autotile`); when off nothing is
   written or restored.
3. **Workspace key** — `(output name, workspace index)`.

### Testing

Extend the VM harness: boot → split/stack windows → quit → reboot with the same
`XDG_CONFIG_HOME` → assert the tree shape is restored via the clients' `GEOM`
lines (same split ratios, same sibling order). A faster winit-based snapshot
round-trip test can cover the serialize/deserialize logic without a full boot.

## Repository layout / conventions

This is a personal fork. Work happens on branch `cosmic-container`; the Docker
sandbox is the primary dev/test environment (see `docs/SANDBOX.md`). Upstream's
`tiling/mod.rs` is under active development, so keep local diffs as surgical as
possible to ease rebasing.
