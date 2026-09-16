//! Workspace integration for the Focus + Reel layout model.
//!
//! [`Workspace`] keeps its column list as the authoritative *set* of managed
//! windows (so floating windows, minimization, persistence and the daemon's
//! window bookkeeping keep working unchanged). When a workspace runs in reel
//! mode, the [`FocusReelState`] stored in `Workspace::focus_reel` becomes the
//! geometry and focus source of truth: the columns are only membership.

use crate::focus_reel::{FocusReelState, ReelGeometry, ReelLayout, ReelSide};
use crate::types::{Rect, WindowId};
use crate::workspace::Workspace;

impl Workspace {
    // ========================================================================
    // Mode control
    // ========================================================================

    /// Whether this workspace is running the Focus + Reel model.
    pub fn is_focus_reel(&self) -> bool {
        self.focus_reel.is_some()
    }

    /// The reel state, if active.
    pub fn focus_reel(&self) -> Option<&FocusReelState> {
        self.focus_reel.as_ref()
    }

    /// Mutable reel state, if active.
    pub fn focus_reel_mut(&mut self) -> Option<&mut FocusReelState> {
        self.focus_reel.as_mut()
    }

    /// Enable the Focus + Reel model, seeding the ring from the current tiled
    /// windows in column order and promoting the current focus.
    pub fn enable_focus_reel(&mut self, geometry: ReelGeometry) {
        let mut state = FocusReelState::with_geometry(geometry);
        state.set_reduce_motion(self.reduce_motion);
        state.set_animation(self.scroll_duration_ms, self.scroll_easing);

        let ordered = self.tiled_window_ids();
        let focus = self.column_focused_window();
        state.sync_membership(&ordered, focus);
        if let Some(focus) = focus {
            if state.focus() != Some(focus) {
                state.focus_window(focus);
                if state.focus() != Some(focus) {
                    state.push_back(focus);
                }
            }
        }
        self.focus_reel = Some(state);
    }

    /// Disable the Focus + Reel model. The column layout takes over again.
    pub fn disable_focus_reel(&mut self) {
        self.focus_reel = None;
    }

    /// Swap in a different geometry.
    pub fn set_reel_geometry(&mut self, geometry: ReelGeometry) {
        if let Some(reel) = self.focus_reel.as_mut() {
            reel.set_geometry(geometry);
        }
    }

    // ========================================================================
    // Reel operations
    // ========================================================================

    /// Promote the item at visual slot `slot` to the focus window.
    pub fn reel_promote(&mut self, slot: i64) -> Option<WindowId> {
        let focused = self.focus_reel.as_mut()?.promote_slot(slot);
        self.reel_sync_column_focus();
        focused
    }

    /// Promote `window_id` if it is a reel member. Returns whether it moved.
    pub fn reel_focus_window(&mut self, window_id: WindowId) -> bool {
        let promoted = self
            .focus_reel
            .as_mut()
            .is_some_and(|reel| reel.focus_window(window_id));
        if promoted {
            self.reel_sync_column_focus();
        }
        promoted
    }

    /// Advance the reel by one (the item under the focus window becomes focus).
    pub fn reel_focus_next(&mut self) -> Option<WindowId> {
        let focused = self.focus_reel.as_mut()?.focus_next();
        self.reel_sync_column_focus();
        focused
    }

    /// Step the reel backwards by one.
    pub fn reel_focus_prev(&mut self) -> Option<WindowId> {
        let focused = self.focus_reel.as_mut()?.focus_prev();
        self.reel_sync_column_focus();
        focused
    }

    /// Scroll the reel by `delta` slots. Continuous while the wheel moves.
    pub fn reel_scroll_by(&mut self, delta: f64) {
        if let Some(reel) = self.focus_reel.as_mut() {
            reel.scroll_by(delta);
        }
    }

    /// Whether the reel has more items than the visible slots, i.e. whether
    /// scrolling can change what is shown.
    pub fn reel_can_scroll(&self) -> bool {
        self.focus_reel
            .as_ref()
            .is_some_and(|reel| reel.can_scroll())
    }

    /// Snap the reel to the nearest integer slot (call when the wheel stops).
    pub fn reel_settle(&mut self) {
        if let Some(reel) = self.focus_reel.as_mut() {
            reel.settle();
        }
    }

    /// Set the side the reel column occupies.
    pub fn reel_set_side(&mut self, side: ReelSide) {
        if let Some(reel) = self.focus_reel.as_mut() {
            reel.set_side(side);
        }
    }

    /// Toggle the reel side explicitly.
    pub fn reel_flip_side(&mut self) -> Option<ReelSide> {
        self.focus_reel.as_mut().map(|reel| reel.flip_side())
    }

    /// Move a ring member through the ring by `delta` positions.
    pub fn reel_move_in_ring(&mut self, window_id: WindowId, delta: i64) -> bool {
        self.focus_reel
            .as_mut()
            .is_some_and(|reel| reel.move_in_ring(window_id, delta))
    }

    /// Rotate the whole reel ring by `delta` positions. Serval counterpart of
    /// the strip's `move_window_*` commands.
    pub fn reel_rotate_ring(&mut self, delta: i64) -> bool {
        self.focus_reel
            .as_mut()
            .is_some_and(|reel| reel.rotate_ring(delta))
    }

    /// Current reel offset (animation-aware).
    pub fn reel_offset(&self) -> Option<f64> {
        self.focus_reel.as_ref().map(|reel| reel.effective_offset())
    }

    /// Resolved reel layout for a viewport.
    pub fn reel_layout(&self, viewport: Rect) -> Option<ReelLayout> {
        self.focus_reel.as_ref().map(|reel| reel.layout(viewport))
    }

    /// Hit-test a screen point against the reel column.
    pub fn reel_hit_test(&self, viewport: Rect, x: i32, y: i32) -> Option<(i64, WindowId)> {
        self.focus_reel
            .as_ref()
            .and_then(|reel| reel.hit_test(viewport, x, y))
    }

    /// The reel's focus window, if the model is active.
    pub fn reel_focused_window(&self) -> Option<WindowId> {
        self.focus_reel.as_ref().and_then(|reel| reel.focus())
    }

    // ========================================================================
    // Internal synchronization
    // ========================================================================

    /// Tiled (non-floating, non-minimized) windows in column order.
    pub(crate) fn tiled_window_ids(&self) -> Vec<WindowId> {
        self.columns
            .iter()
            .flat_map(|column| column.windows().iter().copied())
            .filter(|window_id| !self.minimized_windows.contains(window_id))
            .collect()
    }

    /// The window the column state currently points at (reel-independent).
    pub(crate) fn column_focused_window(&self) -> Option<WindowId> {
        self.columns
            .get(self.focused_column)
            .and_then(|column| column.windows().get(self.focused_window_in_column))
            .copied()
    }

    /// Mirror the reel focus into the column focus indices so all existing
    /// column-based consumers (daemon focus sync, tab strip, IPC summaries)
    /// report the same window the reel presents as the main window.
    pub(crate) fn reel_sync_column_focus(&mut self) {
        let Some(focus) = self.reel_focused_window() else {
            return;
        };
        let Some((column, window)) = self.find_window_location(focus) else {
            return;
        };
        self.focused_column = column;
        self.focused_window_in_column = window;
        self.sync_active_tab_to_focus();
    }

    /// Record a tiled window being added.
    pub(crate) fn reel_note_added(&mut self, window_id: WindowId) {
        if self.minimized_windows.contains(&window_id) {
            return;
        }
        if let Some(reel) = self.focus_reel.as_mut() {
            reel.push_back(window_id);
        }
    }

    /// Promote the column focus into the reel after a mutation that moved
    /// the column focus (new-window insertion, unfloat restore). No-op when
    /// the focused window is not a reel member.
    pub(crate) fn reel_sync_focus_from_columns(&mut self) {
        let Some(focus) = self.column_focused_window() else {
            return;
        };
        if let Some(reel) = self.focus_reel.as_mut() {
            if reel.focus() != Some(focus) && reel.contains(focus) {
                reel.focus_window(focus);
            }
        }
    }

    /// Record a tiled window being removed.
    pub(crate) fn reel_note_removed(&mut self, window_id: WindowId) {
        let Some(reel) = self.focus_reel.as_mut() else {
            return;
        };
        let was_focus = reel.focus() == Some(window_id);
        reel.remove(window_id);
        if was_focus {
            self.reel_sync_column_focus();
        }
    }
}
