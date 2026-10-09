// SPDX-License-Identifier: GPL-3.0-only

//! Serializable form of a workspace's tiling tree, used by the
//! `persist_tiling` feature to restore layouts across sessions.

use serde::{Deserialize, Serialize};

/// A saved tiling tree for one workspace.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct SavedLayout {
    /// Output name the workspace was on.
    pub output: String,
    /// Workspace index within that output.
    pub index: usize,
    pub root: SavedNode,
}

/// A node in a saved tiling tree: either an internal split group or a leaf
/// (one tiled window, or a stack of them).
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub enum SavedNode {
    Group {
        vertical: bool,
        sizes: Vec<i32>,
        children: Vec<SavedNode>,
    },
    /// Stack order is back-to-front.
    Leaf { windows: Vec<SavedWindow> },
}

/// Identity of a window to match on restore: `app_id` first, `title` as a
/// tie-breaker.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct SavedWindow {
    pub app_id: String,
    pub title: String,
}
