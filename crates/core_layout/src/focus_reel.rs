//! Focus + Reel layout model — main window plus a slot-machine reel of thumbnails.
//!
//! This is the state machine for the "Focus + Reel" workspace shape:
//!
//! ```text
//! [ F ]  [ R0, R1, R2, R3, ... ]
//! ```
//!
//! where `F` is the single 2048×1152 (reference geometry) interactive focus
//! window and `R*` is a ring of windows presented as scaled-down DWM
//! thumbnails in a vertical slot-machine reel on one side of the screen.
//!
//! Promoting a reel item is a *cyclic permutation* of the merged
//! `[F, R0, R1, ...]` sequence — no tile tree is rebuilt:
//!
//! ```text
//! [F, R0, R1, R2, R3] -> [R2, R3, F, R0, R1]   (promote R2)
//! ```
//!
//! The reel scrolls continuously: `reel_offset ∈ ℝ` and the on-screen item at
//! visual slot `i` sits at
//!
//! ```text
//! y_i = top_inset + (i - reel_offset) * slot_height
//! ```
//!
//! Releasing the wheel snaps `reel_offset` to the nearest integer slot using
//! the same [`ScrollAnimation`] easing/duration machinery as horizontal
//! scrolling.
//!
//! The layout can be mirrored explicitly via [`ReelSide`] instead of relying
//! on the order windows happen to be in.

use serde::{Deserialize, Serialize};
use std::collections::{HashSet, VecDeque};

use crate::animation::{Easing, ScrollAnimation, DEFAULT_ANIMATION_DURATION_MS};
use crate::types::{Rect, WindowId};

/// Reference main-window width in pixels (2560×1440 target canvas).
pub const DEFAULT_MAIN_WIDTH: i32 = 2048;
/// Reference main-window height in pixels.
pub const DEFAULT_MAIN_HEIGHT: i32 = 1152;
/// Reference reel slot width in pixels.
pub const DEFAULT_SLOT_WIDTH: i32 = 512;
/// Reference reel slot height (and vertical stride) in pixels.
pub const DEFAULT_SLOT_HEIGHT: i32 = 288;
/// Pixels reserved above the focus window for the widget host.
pub const DEFAULT_TOP_INSET: i32 = 216;
/// Pixels reserved below the focus window for the taskbar.
pub const DEFAULT_BOTTOM_INSET: i32 = 72;
/// Number of reel items visible at once.
pub const DEFAULT_VISIBLE_SLOTS: usize = 4;
/// Milliseconds of wheel silence before the reel snaps to the nearest slot.
pub const REEL_SETTLE_DELAY_MS: u64 = 120;

/// Minimum focus-window width after clamping to a small viewport.
const MIN_MAIN_WIDTH: i32 = 200;
/// Minimum slot width after clamping to a small viewport.
const MIN_SLOT_WIDTH: i32 = 100;

/// Which side of the screen the reel column occupies.
///
/// The focus window fills the remaining width on the opposite side. Each
/// promotion can optionally toggle the side (`flip_side_on_promote`) so the
/// layout alternates between `2048 + 512` and `512 + 2048` mirror shapes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ReelSide {
    /// Reel on the left, focus window on the right.
    Left,
    /// Reel on the right, focus window on the left.
    #[default]
    Right,
}

impl ReelSide {
    /// The opposite side.
    pub fn flipped(self) -> Self {
        match self {
            ReelSide::Left => ReelSide::Right,
            ReelSide::Right => ReelSide::Left,
        }
    }
}

/// Geometry knobs for the Focus + Reel layout.
///
/// Defaults match the reference 2560×1440 canvas: a 2048×1152 focus window,
/// four 512×288 reel slots, 216px widget strip at the top and 72px taskbar
/// strip at the bottom. On smaller viewports the focus width and slot height
/// are clamped; on wider viewports the `main + reel` cluster is centered.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ReelGeometry {
    /// Preferred focus width. `0` fills `viewport.width - slot_width`.
    pub main_width: i32,
    /// Preferred focus height.
    pub main_height: i32,
    /// Reel slot width.
    pub slot_width: i32,
    /// Reel slot height (also the vertical stride).
    pub slot_height: i32,
    /// Pixels reserved above the layout for the widget host.
    pub top_inset: i32,
    /// Pixels reserved below the layout for the taskbar.
    pub bottom_inset: i32,
    /// Padding between adjacent windows. The horizontal gap between the focus
    /// window and the reel is split evenly (each side gives `gap / 2`, rounded
    /// up for the focus); each reel slot gives up `gap` of its content height.
    /// `0` keeps the edge-to-edge layout.
    #[serde(default)]
    pub gap: i32,
    /// How many reel slots are visible at once.
    pub visible_slots: usize,
    /// Toggle [`ReelSide`] on every promotion (explicit mirror-symmetric
    /// layout) instead of staying on the configured side.
    pub flip_side_on_promote: bool,
}

impl Default for ReelGeometry {
    fn default() -> Self {
        Self {
            main_width: DEFAULT_MAIN_WIDTH,
            main_height: DEFAULT_MAIN_HEIGHT,
            slot_width: DEFAULT_SLOT_WIDTH,
            slot_height: DEFAULT_SLOT_HEIGHT,
            top_inset: DEFAULT_TOP_INSET,
            bottom_inset: DEFAULT_BOTTOM_INSET,
            // Engine default stays edge-to-edge; the daemon config opts into
            // the 2px window padding.
            gap: 0,
            visible_slots: DEFAULT_VISIBLE_SLOTS,
            flip_side_on_promote: false,
        }
    }
}

impl ReelGeometry {
    /// Clamp nonsensical values coming from config/deserialization.
    pub fn sanitized(mut self) -> Self {
        self.main_width = self.main_width.max(0);
        self.main_height = self.main_height.max(0);
        self.slot_width = self.slot_width.max(MIN_SLOT_WIDTH);
        self.slot_height = self.slot_height.max(1);
        self.top_inset = self.top_inset.max(0);
        self.bottom_inset = self.bottom_inset.max(0);
        self.gap = self.gap.clamp(0, self.slot_width.min(self.slot_height) / 2);
        self.visible_slots = self.visible_slots.max(1);
        self
    }

    /// The vertical band the reel is allowed to paint into for `viewport`.
    pub fn reel_band(&self, viewport: Rect) -> Rect {
        let geom = self.sanitized();
        Rect::new(
            viewport.x,
            viewport.y + geom.top_inset,
            viewport.width,
            self.vertical_span(viewport),
        )
    }

    /// Height available between the top widget strip and the bottom taskbar strip.
    pub fn vertical_span(&self, viewport: Rect) -> i32 {
        let geom = self.sanitized();
        (viewport.height - geom.top_inset - geom.bottom_inset).max(0)
    }

    /// Resolved focus width for a viewport (preferred width clamped to fit).
    ///
    /// The padding between the focus window and the reel is split evenly: the
    /// focus gives up `gap - gap / 2` (the rounded-up half) and the reel gives
    /// up `gap / 2` through [`ReelGeometry::slot_width_effective`].
    pub fn focus_width(&self, viewport: Rect) -> i32 {
        let geom = self.sanitized();
        let slot_w = self.slot_width_effective();
        let max_main = (viewport.width - slot_w - geom.gap).max(MIN_MAIN_WIDTH);
        if geom.main_width <= 0 {
            return max_main;
        }
        let preferred = geom.main_width - (geom.gap - geom.gap / 2);
        preferred.min(max_main).max(MIN_MAIN_WIDTH)
    }

    /// Reel slot width after its half of the horizontal padding is removed.
    pub fn slot_width_effective(&self) -> i32 {
        let geom = self.sanitized();
        (geom.slot_width - geom.gap / 2).max(MIN_SLOT_WIDTH)
    }

    /// Resolved focus height for a viewport.
    pub fn focus_height(&self, viewport: Rect) -> i32 {
        let geom = self.sanitized();
        let span = self.vertical_span(viewport);
        if geom.main_height <= 0 {
            return span;
        }
        geom.main_height.min(span).max(0)
    }

    /// Resolved slot height for a viewport.
    ///
    /// In fill mode (`main_height == 0`) the visible span is split evenly
    /// across `visible_slots`, so the reel tiles the column exactly (e.g. four
    /// 342px slots on a 1368px work area). Otherwise slots keep their
    /// configured height and are only squeezed when the viewport is too short.
    pub fn resolved_slot_height(&self, viewport: Rect) -> i32 {
        let geom = self.sanitized();
        let span = self.vertical_span(viewport);
        let fit = span / geom.visible_slots.max(1) as i32;
        if fit <= 0 {
            return geom.slot_height.max(1);
        }
        if geom.main_height <= 0 {
            return fit.max(1);
        }
        geom.slot_height.min(fit).max(1)
    }

    /// Left edge of the centered `main + reel` cluster.
    pub fn cluster_x(&self, viewport: Rect) -> i32 {
        let cluster_w = self.cluster_width(viewport);
        viewport.x + ((viewport.width - cluster_w).max(0)) / 2
    }

    /// Total cluster width (`focus + padding + reel`).
    pub fn cluster_width(&self, viewport: Rect) -> i32 {
        self.focus_width(viewport) + self.sanitized().gap + self.slot_width_effective()
    }

    pub(crate) fn side_x(&self, viewport: Rect, side: ReelSide) -> (i32, i32) {
        let cluster_x = self.cluster_x(viewport);
        let focus_w = self.focus_width(viewport);
        let slot_w = self.slot_width_effective();
        let gap = self.sanitized().gap;
        match side {
            ReelSide::Right => (cluster_x, cluster_x + focus_w + gap),
            ReelSide::Left => (cluster_x + slot_w + gap, cluster_x),
        }
    }
}

/// One visible reel slot and the window currently occupying it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReelSlotView {
    /// Window shown in this slot.
    pub window_id: WindowId,
    /// Ring ordinal of the item (`i` in `y_i = top + (i - reel_offset) * h`).
    /// Can be negative while entries scroll in from above.
    pub slot: i64,
    /// Destination rect for the DWM thumbnail.
    pub rect: Rect,
    /// Whether the slot lies entirely inside the reel band.
    pub fully_visible: bool,
}

/// Resolved layout for one frame.
#[derive(Debug, Clone, PartialEq)]
pub struct ReelLayout {
    /// The focused window and its main rect.
    pub focus: Option<(WindowId, Rect)>,
    /// Resolved main rect (independent of whether a focus window exists).
    pub main_rect: Rect,
    /// Visible reel slots in top-to-bottom order.
    pub slots: Vec<ReelSlotView>,
    /// Ring members not currently visible in the reel band.
    pub hidden: Vec<WindowId>,
    /// Layout side used for this frame.
    pub side: ReelSide,
    /// Continuous reel offset used for this frame.
    pub offset: f64,
    /// Full reel column footprint: slot width × the whole reel band.
    /// Used for click interception and for rendering a background strip.
    pub column_rect: Rect,
}

impl ReelLayout {
    /// The window occupying the given visual slot, if any.
    pub fn window_at_slot(&self, slot: i64) -> Option<WindowId> {
        self.slots
            .iter()
            .find(|view| view.slot == slot)
            .map(|view| view.window_id)
    }

    /// Screen-space region actually covered by rendered slots, clipped to the
    /// reel band. `None` when nothing is rendered.
    ///
    /// Used for click interception so the blank part of a partially-filled
    /// reel column passes through instead of swallowing clicks.
    pub fn rendered_region(&self) -> Option<Rect> {
        let band_top = self.column_rect.y;
        let band_bottom = self.column_rect.bottom();
        let mut top = i32::MAX;
        let mut bottom = i32::MIN;
        for slot in &self.slots {
            top = top.min(slot.rect.y.max(band_top));
            bottom = bottom.max(slot.rect.bottom().min(band_bottom));
        }
        (top < bottom).then(|| {
            Rect::new(
                self.column_rect.x,
                top,
                self.column_rect.width,
                bottom - top,
            )
        })
    }
}

/// Focus + Reel ring state.
///
/// Invariants:
/// - `focus` is never a member of `ring`.
/// - `ring` holds unique window IDs.
/// - `reel_offset` is finite; it may be any real number (the ring is cyclic).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FocusReelState {
    /// Reel ring in display order. `ring[0]` is the first slot under the
    /// focus window at offset 0.
    ring: VecDeque<WindowId>,
    /// The promoted main window.
    focus: Option<WindowId>,
    /// Continuous scroll offset in slot units.
    reel_offset: f64,
    /// Which side the reel column occupies.
    side: ReelSide,
    /// Geometry knobs.
    geometry: ReelGeometry,
    /// Active snap animation for the reel offset.
    #[serde(skip)]
    active_animation: Option<ScrollAnimation>,
    /// A wheel gesture moved the offset and the snap is armed; the engine
    /// waits [`REEL_SETTLE_DELAY_MS`] of frame silence before snapping.
    #[serde(skip)]
    pending_settle: bool,
    /// Milliseconds elapsed since the last wheel tick (while `pending_settle`).
    #[serde(skip)]
    ms_since_scroll: u64,
    /// Snap instantly instead of animating (reduced motion).
    #[serde(skip)]
    reduce_motion: bool,
    /// Snap animation duration in milliseconds.
    #[serde(skip)]
    duration_ms: u64,
    /// Snap animation easing.
    #[serde(skip)]
    easing: Easing,
}

impl Default for FocusReelState {
    fn default() -> Self {
        Self {
            ring: VecDeque::new(),
            focus: None,
            reel_offset: 0.0,
            side: ReelSide::default(),
            geometry: ReelGeometry::default(),
            active_animation: None,
            pending_settle: false,
            ms_since_scroll: 0,
            reduce_motion: false,
            duration_ms: DEFAULT_ANIMATION_DURATION_MS,
            easing: Easing::default(),
        }
    }
}

impl FocusReelState {
    /// New empty reel with default geometry.
    pub fn new() -> Self {
        Self::default()
    }

    /// New empty reel with explicit geometry.
    pub fn with_geometry(geometry: ReelGeometry) -> Self {
        Self {
            geometry: geometry.sanitized(),
            ..Self::default()
        }
    }

    /// Current geometry.
    pub fn geometry(&self) -> ReelGeometry {
        self.geometry
    }

    /// Replace geometry.
    pub fn set_geometry(&mut self, geometry: ReelGeometry) {
        self.geometry = geometry.sanitized();
    }

    /// Current side.
    pub fn side(&self) -> ReelSide {
        self.side
    }

    /// Set the reel side.
    pub fn set_side(&mut self, side: ReelSide) {
        self.side = side;
    }

    /// Toggle the reel side (explicit mirror layout).
    pub fn flip_side(&mut self) -> ReelSide {
        self.side = self.side.flipped();
        self.side
    }

    /// Focus window currently occupying the main rect.
    pub fn focus(&self) -> Option<WindowId> {
        self.focus
    }

    /// Number of ring members (does not count the focus window).
    pub fn reel_len(&self) -> usize {
        self.ring.len()
    }

    /// Total managed windows (focus + ring).
    pub fn len(&self) -> usize {
        self.ring.len() + usize::from(self.focus.is_some())
    }

    /// Whether there are no windows at all.
    pub fn is_empty(&self) -> bool {
        self.focus.is_none() && self.ring.is_empty()
    }

    /// Ring members in display order.
    pub fn ring(&self) -> impl Iterator<Item = WindowId> + '_ {
        self.ring.iter().copied()
    }

    /// Whether a window (focus or ring member) belongs to this reel.
    pub fn contains(&self, window_id: WindowId) -> bool {
        self.focus == Some(window_id) || self.ring.contains(&window_id)
    }

    /// Raw (possibly animating) reel offset.
    pub fn reel_offset(&self) -> f64 {
        self.reel_offset
    }

    /// Offset used for rendering this frame (animation-aware).
    pub fn effective_offset(&self) -> f64 {
        self.active_animation
            .as_ref()
            .map(|animation| animation.current_offset())
            .unwrap_or(self.reel_offset)
    }

    /// Whether a snap animation or a pending wheel settle is active.
    pub fn is_animating(&self) -> bool {
        self.active_animation.is_some() || self.pending_settle
    }

    /// Configure reduced motion (snap instantly).
    pub fn set_reduce_motion(&mut self, reduce: bool) {
        self.reduce_motion = reduce;
        if reduce {
            self.finish_animation();
        }
    }

    /// Configure the snap animation.
    pub fn set_animation(&mut self, duration_ms: u64, easing: Easing) {
        self.duration_ms = duration_ms;
        self.easing = easing;
    }

    /// Append a window to the ring without touching focus.
    ///
    /// No-op for duplicates and for the current focus.
    pub fn push_back(&mut self, window_id: WindowId) {
        if self.contains(window_id) {
            return;
        }
        if self.focus.is_none() {
            self.focus = Some(window_id);
            return;
        }
        self.ring.push_back(window_id);
    }

    /// Remove a window from the reel.
    ///
    /// If the removed window was the focus, the front ring item is promoted
    /// (the reel advances by one). Returns the window that ended up focused.
    pub fn remove(&mut self, window_id: WindowId) -> Option<WindowId> {
        if self.focus == Some(window_id) {
            self.focus = self.ring.pop_front();
            self.clamp_offset_for_membership();
            return self.focus;
        }
        if let Some(pos) = self.ring.iter().position(|&id| id == window_id) {
            self.ring.remove(pos);
            self.clamp_offset_for_membership();
        }
        self.focus
    }

    /// Promote the item at a reel ordinal to focus via cyclic permutation.
    ///
    /// `slot` is the ring ordinal `i` from `y_i = top + (i - reel_offset) * h`
    /// (what [`FocusReelState::hit_test`] returns). The result matches the
    /// merged-deque rotation `[F, R0, ...] -> [promoted, following..., F,
    /// preceding...]`.
    ///
    /// Returns the new focus window.
    pub fn promote_slot(&mut self, slot: i64) -> Option<WindowId> {
        let n = self.ring.len();
        if n == 0 {
            return self.focus;
        }
        let idx = slot.rem_euclid(n as i64) as usize;
        self.ring.rotate_left(idx);
        let new_focus = self.ring.pop_front();
        let promoted = new_focus.expect("ring is non-empty");
        if let Some(old_focus) = self.focus {
            // The old focus takes the promoted item's vacated ring position:
            // after `rotate_left(idx)` + `pop_front`, the trailing segment is
            // `old_ring[idx+1..] ++ old_ring[..idx]`; the promoted item used
            // to sit between the two segments, so insert there.
            let insert_at = n - 1 - idx;
            self.ring.insert(insert_at, old_focus);
        }
        self.focus = Some(promoted);
        // Present the reel from the top after a promotion.
        self.reel_offset = 0.0;
        self.active_animation = None;
        if self.geometry.flip_side_on_promote {
            self.side = self.side.flipped();
        }
        self.focus
    }

    /// Promote the next ring item (the one directly under the focus window).
    pub fn focus_next(&mut self) -> Option<WindowId> {
        self.promote_slot(0)
    }

    /// Promote the last visible/ring item (wrap backwards through the ring).
    pub fn focus_prev(&mut self) -> Option<WindowId> {
        let n = self.ring.len();
        if n == 0 {
            return self.focus;
        }
        self.promote_slot(n as i64 - 1)
    }

    /// Promote `window_id` if it is a ring member. No-op for the focus.
    pub fn focus_window(&mut self, window_id: WindowId) -> bool {
        if self.focus == Some(window_id) {
            return false;
        }
        let Some(pos) = self.ring.iter().position(|&id| id == window_id) else {
            return false;
        };
        self.promote_slot(pos as i64);
        true
    }

    /// Rotate the whole ring by `delta` positions (positive advances items
    /// toward the top of the reel). The focus window is unaffected, so this is
    /// the Serval equivalent of "move the shelf" for the strip's
    /// `move_window_up/down/left/right` commands.
    /// Returns whether anything moved.
    pub fn rotate_ring(&mut self, delta: i64) -> bool {
        let n = self.ring.len();
        if n < 2 || delta == 0 {
            return false;
        }
        let step = delta.rem_euclid(n as i64) as usize;
        self.ring.rotate_left(step);
        true
    }

    /// Move a ring member `delta` positions through the ring (wrapping).
    /// Has no effect on the focus window.
    pub fn move_in_ring(&mut self, window_id: WindowId, delta: i64) -> bool {
        if delta == 0 {
            return false;
        }
        let n = self.ring.len();
        if n < 2 {
            return false;
        }
        let Some(pos) = self.ring.iter().position(|&id| id == window_id) else {
            return false;
        };
        self.ring.remove(pos);
        let target = (pos as i64 + delta).rem_euclid(n as i64) as usize;
        self.ring.insert(target, window_id);
        true
    }

    /// Scroll the reel by `delta` slots (positive scrolls toward later items).
    ///
    /// The offset stays continuous; call [`FocusReelState::settle`] when the
    /// wheel gesture ends to snap to the nearest slot.
    /// Whether the reel has more items than the configured visible slots.
    ///
    /// A reel that fits entirely must not scroll: wrapping would only shuffle
    /// the same items into empty space.
    pub fn can_scroll(&self) -> bool {
        self.ring.len() > self.geometry.visible_slots
    }

    /// Reset the offset when the reel no longer has enough items to scroll.
    fn clamp_offset_for_membership(&mut self) {
        if !self.can_scroll() {
            self.reel_offset = 0.0;
            self.active_animation = None;
            self.pending_settle = false;
            self.ms_since_scroll = 0;
        }
    }

    pub fn scroll_by(&mut self, delta: f64) {
        if !delta.is_finite() || delta == 0.0 {
            return;
        }
        // A reel with `visible_slots` or fewer ring members fits entirely;
        // scrolling it would only shuffle items into empty space.
        if !self.can_scroll() {
            return;
        }
        // Accumulate onto the pending target while a scroll animation is in
        // flight so rapid wheel ticks add up instead of fighting each other.
        let base = self
            .active_animation
            .as_ref()
            .map(|animation| animation.target())
            .unwrap_or(self.reel_offset);
        self.pending_settle = true;
        self.ms_since_scroll = 0;
        self.animate_offset_to(base + delta);
    }

    /// Scroll so `window_id` occupies the given visual slot.
    pub fn scroll_to_window(&mut self, window_id: WindowId, slot: usize) -> bool {
        let Some(pos) = self.ring.iter().position(|&id| id == window_id) else {
            return false;
        };
        let target = pos as f64 - slot as f64;
        self.animate_offset_to(target);
        true
    }

    /// Snap to the nearest integer slot, animating unless reduced motion.
    pub fn settle(&mut self) {
        self.pending_settle = false;
        self.ms_since_scroll = 0;
        // Round the pending target, not the settled base, so an explicit
        // settle mid-scroll snaps to where the wheel was heading.
        let base = self
            .active_animation
            .as_ref()
            .map(|animation| animation.target())
            .unwrap_or(self.reel_offset);
        self.animate_offset_to(base.round());
    }

    /// Advance a running scroll animation or the wheel settle timer.
    /// Returns true while the reel still needs animation frames.
    pub fn tick(&mut self, delta_ms: u64) -> bool {
        if let Some(animation) = self.active_animation.as_mut() {
            if animation.tick(delta_ms) {
                return true;
            }
            self.finish_animation();
        }
        if !self.pending_settle {
            return false;
        }
        self.ms_since_scroll = self.ms_since_scroll.saturating_add(delta_ms);
        if self.ms_since_scroll < REEL_SETTLE_DELAY_MS {
            return true;
        }
        self.settle();
        self.active_animation.is_some()
    }

    /// Cancel any snap animation, leaving the offset where it is.
    pub fn stop_animation(&mut self) {
        self.active_animation = None;
        self.pending_settle = false;
        self.ms_since_scroll = 0;
    }

    /// Current integer resting slot.
    pub fn settled_offset(&self) -> i64 {
        self.reel_offset.round() as i64
    }

    fn animate_offset_to(&mut self, target: f64) {
        // Start from the currently rendered position so retargeting mid-scroll
        // is continuous instead of jumping back to the animation's start.
        let start = self.effective_offset();
        if self.reduce_motion || self.duration_ms == 0 || (target - start).abs() < 0.001 {
            self.reel_offset = target;
            self.active_animation = None;
            return;
        }
        self.active_animation = Some(ScrollAnimation::new(
            start,
            target,
            self.duration_ms,
            self.easing,
        ));
    }

    fn finish_animation(&mut self) {
        if let Some(animation) = self.active_animation.take() {
            self.reel_offset = animation.target();
        }
    }

    /// Compute the layout for a viewport.
    pub fn layout(&self, viewport: Rect) -> ReelLayout {
        let geometry = self.geometry.sanitized();
        let (focus_x, reel_x) = geometry.side_x(viewport, self.side);
        let main_rect = Rect::new(
            focus_x,
            viewport.y + geometry.top_inset,
            geometry.focus_width(viewport),
            geometry.focus_height(viewport),
        );

        let slot_w = geometry.slot_width_effective();
        let slot_h = geometry.resolved_slot_height(viewport);
        // Each slot gives up `gap` of content height for the padding between
        // it and the next slot; the stride stays `slot_h` so the first slot
        // remains flush with the top edge.
        let content_h = (slot_h - geometry.gap).max(1);
        let band = geometry.reel_band(viewport);
        let offset = self.effective_offset();
        let n = self.ring.len();

        let mut slots: Vec<ReelSlotView> = Vec::with_capacity(geometry.visible_slots + 2);
        let mut shown: HashSet<usize> = HashSet::new();
        if n > 0 {
            // `i` is the ring ordinal from the user-facing formula
            // `y_i = top_inset + (i - reel_offset) * slot_height`. Scan one
            // slot beyond each edge so partially-visible entries render (and
            // clip) instead of popping in.
            let base = offset.floor() as i64;
            let first = base - 1;
            let last = base + geometry.visible_slots.max(1) as i64 + 1;
            for ordinal in first..=last {
                let ring_idx = ordinal.rem_euclid(n as i64) as usize;
                let y = viewport.y
                    + geometry.top_inset
                    + ((ordinal as f64 - offset) * slot_h as f64).round() as i32;
                let rect = Rect::new(reel_x, y, slot_w, content_h);
                // Cull entries fully outside the band before deduping, so a
                // culled duplicate can't hide the on-screen copy.
                if y + content_h <= band.y || y >= band.y + band.height {
                    continue;
                }
                // With fewer ring members than slots the wheel would repeat
                // items; show each item once.
                if !shown.insert(ring_idx) {
                    continue;
                }
                let full_top = y >= band.y;
                let full_bottom = y + content_h <= band.y + band.height;
                slots.push(ReelSlotView {
                    window_id: self.ring[ring_idx],
                    slot: ordinal,
                    rect,
                    fully_visible: full_top && full_bottom,
                });
            }
        }

        let visible_ids: HashSet<WindowId> = slots.iter().map(|slot| slot.window_id).collect();
        let hidden: Vec<WindowId> = self
            .ring
            .iter()
            .copied()
            .filter(|id| !visible_ids.contains(id))
            .collect();

        ReelLayout {
            focus: self.focus.map(|id| (id, main_rect)),
            main_rect,
            slots,
            hidden,
            side: self.side,
            offset,
            column_rect: Rect::new(reel_x, band.y, slot_w, band.height),
        }
    }

    /// Hit-test a screen point against the rendered reel slots.
    ///
    /// Returns the ring ordinal and window under the point. Fractional
    /// offsets are respected, so clicks during a scroll resolve to the item
    /// actually rendered at that pixel row. Only the area covered by a
    /// rendered slot counts: clicking the blank part of a partially-filled
    /// reel column (fewer ring members than the column can show) is not a hit
    /// and must not wrap around the ring.
    pub fn hit_test(&self, viewport: Rect, x: i32, y: i32) -> Option<(i64, WindowId)> {
        if self.ring.is_empty() {
            return None;
        }
        let layout = self.layout(viewport);
        let band = layout.column_rect;
        layout.slots.iter().find_map(|slot| {
            let clipped_top = slot.rect.y.max(band.y);
            let clipped_bottom = slot.rect.bottom().min(band.bottom());
            (x >= slot.rect.x
                && x < slot.rect.x + slot.rect.width
                && y >= clipped_top
                && y < clipped_bottom)
                .then_some((slot.slot, slot.window_id))
        })
    }

    /// Synchronize ring membership against the authoritative ordered window
    /// list for the workspace.
    ///
    /// - Removed windows are pruned; if the focus disappeared the next ring
    ///   member is promoted.
    /// - New windows are appended in list order.
    /// - `focus_hint` (normally the workspace's focused window) seeds focus
    ///   only when the reel currently has none; explicit promotion goes
    ///   through [`FocusReelState::focus_window`] so ordering is preserved.
    pub fn sync_membership(&mut self, ordered: &[WindowId], focus_hint: Option<WindowId>) {
        let allowed: HashSet<WindowId> = ordered.iter().copied().collect();
        self.ring.retain(|id| allowed.contains(id));
        if self.focus.is_some_and(|id| !allowed.contains(&id)) {
            self.focus = self.ring.pop_front();
        }
        let mut present: HashSet<WindowId> = self.ring.iter().copied().collect();
        if let Some(focus) = self.focus {
            present.insert(focus);
        }
        for &id in ordered {
            if present.insert(id) {
                if self.focus.is_none() {
                    self.focus = Some(id);
                } else {
                    self.ring.push_back(id);
                }
            }
        }
        if self.focus.is_none() {
            if let Some(hint) = focus_hint.filter(|id| allowed.contains(id)) {
                self.focus = Some(hint);
                self.ring.retain(|&id| id != hint);
            }
        }
        // Drop duplicates defensively (ring is authoritative, dedupe in place).
        let mut seen: HashSet<WindowId> = HashSet::new();
        if let Some(focus) = self.focus {
            seen.insert(focus);
        }
        self.ring.retain(|id| seen.insert(*id));
        self.clamp_offset_for_membership();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn viewport() -> Rect {
        Rect::new(0, 0, 2560, 1440)
    }

    fn reel_with(ids: &[WindowId]) -> FocusReelState {
        let mut reel = FocusReelState::new();
        for &id in ids {
            reel.push_back(id);
        }
        reel
    }

    /// Tick through the default 200ms scroll tween without waiting out the
    /// idle settle timer.
    fn run_scroll_tween(reel: &mut FocusReelState) {
        let frames = DEFAULT_ANIMATION_DURATION_MS / 16 + 2;
        for _ in 0..frames {
            reel.tick(16);
        }
    }

    #[test]
    fn reel_with_at_most_visible_slots_does_not_scroll() {
        // Focus + 4 ring members = 4 small windows: fits the 4 visible slots.
        let mut reel = reel_with(&[1, 2, 3, 4, 5]);
        assert!(!reel.can_scroll());
        reel.scroll_by(1.0);
        assert_eq!(reel.effective_offset(), 0.0, "wheel is ignored");
        reel.scroll_by(-3.0);
        assert_eq!(reel.effective_offset(), 0.0);
        assert!(!reel.is_animating());
    }

    #[test]
    fn reel_with_more_than_visible_slots_scrolls() {
        // Focus + 5 ring members = 5 small windows: scrolling is useful again.
        let mut reel = reel_with(&[1, 2, 3, 4, 5, 6]);
        assert!(reel.can_scroll());
        reel.scroll_by(1.0);
        assert!(reel.is_animating(), "wheel tick animates the offset");
        while reel.is_animating() {
            reel.tick(16);
        }
        assert_eq!(reel.reel_offset(), 1.0);
    }

    #[test]
    fn removing_down_to_the_visible_slot_count_resets_the_offset() {
        let mut reel = reel_with(&[1, 2, 3, 4, 5, 6]);
        reel.set_reduce_motion(true);
        reel.scroll_by(2.0);
        assert_eq!(reel.effective_offset(), 2.0);
        reel.remove(6); // 4 ring members left: nothing to scroll
        assert!(!reel.can_scroll());
        assert_eq!(reel.reel_offset(), 0.0);
        assert!(!reel.is_animating());
    }

    #[test]
    fn sync_membership_resets_offset_when_the_reel_fits() {
        let mut reel = reel_with(&[1, 2, 3, 4, 5, 6]);
        reel.scroll_by(1.0);
        reel.sync_membership(&[1, 2, 3, 4], Some(1));
        assert!(!reel.can_scroll());
        assert_eq!(reel.reel_offset(), 0.0);
    }

    #[test]
    fn push_back_seeds_focus_then_ring() {
        let reel = reel_with(&[1, 2, 3]);
        assert_eq!(reel.focus(), Some(1));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![2, 3]);
        assert_eq!(reel.len(), 3);
    }

    #[test]
    fn promote_slot_matches_the_cyclic_permutation() {
        // [F, R0, R1, R2, R3] -> [R2, R3, F, R0, R1]
        let mut reel = reel_with(&[10, 20, 21, 22, 23]);
        let promoted = reel.promote_slot(2);
        assert_eq!(promoted, Some(22));
        assert_eq!(reel.focus(), Some(22));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![23, 10, 20, 21]);
        assert_eq!(reel.reel_offset(), 0.0);
    }

    #[test]
    fn promote_slot_zero_is_a_one_step_advance() {
        let mut reel = reel_with(&[10, 20, 21, 22]);
        assert_eq!(reel.promote_slot(0), Some(20));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![21, 22, 10]);
    }

    #[test]
    fn promote_respects_a_scrolled_offset() {
        // Enough ring members for the reel to actually scroll (5 > visible 4).
        let mut reel = reel_with(&[10, 20, 21, 22, 23, 24]);
        reel.scroll_by(1.0);
        run_scroll_tween(&mut reel);
        // The top visible row is ordinal 1 (ring[1] = 21).
        assert_eq!(reel.hit_test(viewport(), 2300, 216), Some((1, 21)));
        assert_eq!(reel.promote_slot(1), Some(21));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![22, 23, 24, 10, 20]);
    }

    #[test]
    fn repeated_promote_cycles_without_duplicates() {
        let mut reel = reel_with(&[1, 2, 3, 4]);
        for _ in 0..12 {
            reel.promote_slot(0);
            let all: Vec<WindowId> = std::iter::once(reel.focus().unwrap())
                .chain(reel.ring())
                .collect();
            let mut sorted = all.clone();
            sorted.sort_unstable();
            assert_eq!(sorted, vec![1, 2, 3, 4], "no duplicate / lost windows");
        }
    }

    #[test]
    fn promote_with_single_ring_item_swaps_focus_and_reel() {
        let mut reel = reel_with(&[1, 2]);
        assert_eq!(reel.promote_slot(0), Some(2));
        assert_eq!(reel.focus(), Some(2));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![1]);
    }

    #[test]
    fn remove_focus_promotes_front_of_ring() {
        let mut reel = reel_with(&[1, 2, 3]);
        assert_eq!(reel.remove(1), Some(2));
        assert_eq!(reel.focus(), Some(2));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![3]);
        assert_eq!(reel.remove(3), Some(2));
        assert_eq!(reel.reel_len(), 0);
        assert_eq!(reel.focus(), Some(2));
    }

    #[test]
    fn remove_last_window_clears_focus() {
        let mut reel = reel_with(&[1]);
        assert_eq!(reel.remove(1), None);
        assert!(reel.is_empty());
    }

    #[test]
    fn scroll_offset_is_continuous_and_settles_to_nearest() {
        let mut reel = reel_with(&[1, 2, 3, 4, 5, 6]);
        reel.scroll_by(0.4);
        assert!(
            reel.is_animating(),
            "wheel tick animates instead of jumping"
        );
        run_scroll_tween(&mut reel);
        assert!((reel.reel_offset() - 0.4).abs() < 1e-9);
        reel.scroll_by(0.2);
        run_scroll_tween(&mut reel);
        assert!((reel.reel_offset() - 0.6).abs() < 1e-9);
        reel.settle();
        assert!(reel.is_animating());
        let mut ticks = 0;
        while reel.tick(16) {
            ticks += 1;
            assert!(ticks < 100, "animation must terminate");
        }
        assert_eq!(reel.settled_offset(), 1);
    }

    #[test]
    fn wheel_tick_eases_instead_of_jumping() {
        let mut reel = reel_with(&[1, 2, 3, 4, 5, 6]);
        reel.scroll_by(1.0);
        assert_eq!(reel.effective_offset(), 0.0, "starts where it was");
        reel.tick(DEFAULT_ANIMATION_DURATION_MS / 2);
        let mid = reel.effective_offset();
        assert!(
            mid > 0.0 && mid < 1.0,
            "halfway through the tween the offset is in between: {mid}"
        );
    }

    #[test]
    fn wheel_settle_fires_after_the_idle_delay() {
        let mut reel = reel_with(&[1, 2, 3, 4, 5, 6]);
        reel.scroll_by(0.4);
        assert!(reel.is_animating(), "pending settle counts as animating");
        assert!(reel.tick(REEL_SETTLE_DELAY_MS - 1), "still waiting");
        assert!(reel.tick(1), "settle animation starts");
        let mut ticks = 0;
        while reel.tick(16) {
            ticks += 1;
            assert!(ticks < 100);
        }
        assert_eq!(reel.settled_offset(), 0);
        assert!(!reel.is_animating());
    }

    #[test]
    fn reduced_motion_snaps_instantly() {
        let mut reel = reel_with(&[1, 2, 3, 4, 5, 6]);
        reel.set_reduce_motion(true);
        reel.scroll_by(0.6);
        // Continuous while the wheel is moving…
        assert!((reel.reel_offset() - 0.6).abs() < 1e-9);
        // …then instant snap on release.
        reel.settle();
        assert_eq!(reel.reel_offset(), 1.0);
        assert!(!reel.is_animating());
    }

    #[test]
    fn layout_places_reference_geometry_on_the_right() {
        let mut reel = reel_with(&[10, 20, 21, 22, 23, 24]);
        reel.promote_slot(0); // focus 20, ring [21,22,23,24,10]
        let layout = reel.layout(viewport());
        let (focus, main) = layout.focus.unwrap();
        assert_eq!(focus, 20);
        assert_eq!(main, Rect::new(0, 216, 2048, 1152));
        assert_eq!(layout.side, ReelSide::Right);
        assert_eq!(layout.slots.len(), 4);
        for (i, slot) in layout.slots.iter().enumerate() {
            assert_eq!(slot.rect.x, 2048);
            assert_eq!(slot.rect.y, 216 + i as i32 * 288);
            assert_eq!(slot.rect.width, 512);
            assert_eq!(slot.rect.height, 288);
            assert!(slot.fully_visible);
        }
        assert_eq!(layout.slots[0].window_id, 21);
        assert_eq!(layout.slots[3].window_id, 24);
        assert_eq!(layout.hidden, vec![10]);
    }

    #[test]
    fn layout_mirrors_to_the_left_side() {
        let mut reel = reel_with(&[10, 20, 21, 22, 23]);
        reel.set_side(ReelSide::Left);
        reel.promote_slot(0);
        let layout = reel.layout(viewport());
        let (_, main) = layout.focus.unwrap();
        assert_eq!(main, Rect::new(512, 216, 2048, 1152));
        for slot in &layout.slots {
            assert_eq!(slot.rect.x, 0);
        }
        assert_eq!(layout.side, ReelSide::Left);
    }

    #[test]
    fn flip_on_promote_alternates_sides() {
        let geometry = ReelGeometry {
            flip_side_on_promote: true,
            ..ReelGeometry::default()
        };
        let mut reel = FocusReelState::with_geometry(geometry);
        for id in [1, 2, 3] {
            reel.push_back(id);
        }
        assert_eq!(reel.side(), ReelSide::Right);
        reel.promote_slot(0);
        assert_eq!(reel.side(), ReelSide::Left);
        reel.promote_slot(0);
        assert_eq!(reel.side(), ReelSide::Right);
    }

    #[test]
    fn fractional_offset_moves_slots_continuously() {
        let mut reel = reel_with(&[1, 2, 3, 4, 5, 6]);
        reel.set_reduce_motion(true);
        reel.scroll_by(0.5);
        let layout = reel.layout(viewport());
        // Ordinal 0 (ring[0] = 2) slides out of the top: 216 -> 72.
        assert_eq!(layout.slots[0].window_id, 2);
        assert_eq!(layout.slots[0].slot, 0);
        assert_eq!(layout.slots[0].rect.y, 216 - 144);
        assert!(!layout.slots[0].fully_visible);
        // Ordinal 1 (ring[1] = 3) slides in from below.
        assert_eq!(layout.slots[1].window_id, 3);
        assert_eq!(layout.slots[1].rect.y, 216 + 144);
        // Partially visible bottom entry is kept for clipped rendering.
        assert!(layout.slots.len() > 4);
    }

    #[test]
    fn small_reel_does_not_repeat_slots() {
        let reel = reel_with(&[1, 2]);
        let layout = reel.layout(viewport());
        assert_eq!(layout.slots.len(), 1, "focus 1 + ring [2] shows 2 once");
        assert_eq!(layout.slots[0].window_id, 2);
        assert_eq!(layout.hidden, Vec::<WindowId>::new());
    }

    #[test]
    fn hidden_items_are_reported_for_large_rings() {
        let reel = reel_with(&[1, 2, 3, 4, 5, 6, 7]);
        let layout = reel.layout(viewport());
        assert_eq!(layout.slots.len(), 4);
        assert_eq!(layout.hidden, vec![6, 7]);
    }

    #[test]
    fn hit_test_maps_pixels_to_ring_members() {
        let mut reel = reel_with(&[10, 20, 21, 22, 23]);
        reel.promote_slot(0); // focus 20, ring [21,22,23,10]
                              // Top of the second slot.
        assert_eq!(reel.hit_test(viewport(), 2300, 216 + 288), Some((1, 22)));
        // Above the band (widget strip) is not part of the reel.
        assert_eq!(reel.hit_test(viewport(), 2300, 100), None);
        // Main window area is not a reel hit.
        assert_eq!(reel.hit_test(viewport(), 1000, 400), None);
    }

    #[test]
    fn hit_test_respects_fractional_scroll() {
        // 5 small windows so the reel is scrollable; a 0.5 offset shifts the
        // slots by half a stride.
        let mut reel = reel_with(&[1, 2, 3, 4, 5, 6]);
        reel.set_reduce_motion(true);
        reel.scroll_by(0.5);
        // At offset 0.5 the pixel row at the band top is the boundary between
        // ring[0] and ring[1]; the floor rule resolves it to ring[0] = 2.
        assert_eq!(reel.hit_test(viewport(), 2300, 216), Some((0, 2)));
    }

    #[test]
    fn hit_test_ignores_blank_reel_space() {
        // Focus 1 + one reel item: only y=216..504 has a rendered slot.
        let reel = reel_with(&[1, 2]);
        assert_eq!(reel.hit_test(viewport(), 2300, 300), Some((0, 2)));
        assert_eq!(
            reel.hit_test(viewport(), 2300, 900),
            None,
            "blank space under the column must not wrap around the ring"
        );
    }

    #[test]
    fn rendered_region_shrinks_to_the_rendered_slots() {
        let reel = reel_with(&[1, 2]);
        let layout = reel.layout(viewport());
        assert_eq!(
            layout.rendered_region(),
            Some(Rect::new(2048, 216, 512, 288)),
            "one reel item covers one slot, not the whole column"
        );

        let focus_only = reel_with(&[1]);
        let layout = focus_only.layout(viewport());
        assert_eq!(layout.rendered_region(), None);
    }

    #[test]
    fn compose_layout_centers_cluster_on_wide_viewports() {
        let geometry = ReelGeometry::default();
        let wide = Rect::new(0, 0, 3440, 1440);
        let mut reel = FocusReelState::with_geometry(geometry);
        for id in [1, 2, 3] {
            reel.push_back(id);
        }
        let layout = reel.layout(wide);
        let (_, main) = layout.focus.unwrap();
        assert_eq!(main.width, 2048);
        assert_eq!(main.x, (3440 - 2560) / 2);
        assert_eq!(layout.slots[0].rect.x, main.x + 2048);
    }

    #[test]
    fn small_viewport_clamps_focus_and_slots() {
        let mut reel = FocusReelState::new();
        for id in [1, 2, 3] {
            reel.push_back(id);
        }
        let small = Rect::new(0, 0, 1366, 768);
        let layout = reel.layout(small);
        let (_, main) = layout.focus.unwrap();
        assert_eq!(main.width, 1366 - 512);
        // 768 - 216 - 72 = 480; 480 / 4 = 120 -> slot height squeezed to 120.
        assert_eq!(layout.slots[0].rect.height, 120);
        assert_eq!(layout.slots[1].rect.y, 216 + 120);
    }

    #[test]
    fn gap_pads_between_windows_evenly() {
        let geometry = ReelGeometry {
            top_inset: 0,
            bottom_inset: 0,
            main_height: 0,
            gap: 2,
            ..ReelGeometry::default()
        };
        let mut reel = FocusReelState::with_geometry(geometry);
        for id in [1, 2, 3, 4, 5, 6] {
            reel.push_back(id);
        }
        let viewport = Rect::new(0, 0, 2560, 1368);
        let layout = reel.layout(viewport);
        let (_, main) = layout.focus.unwrap();
        // Horizontal padding is split evenly: main 2048-1, reel 512-1.
        assert_eq!(main.width, 2047);
        assert_eq!(main.x, 0);
        assert_eq!(layout.slots[0].rect.width, 511);
        assert_eq!(layout.slots[0].rect.x, 2049);
        assert_eq!(layout.slots[0].rect.x - main.right(), 2);
        // Vertical padding: the fill-mode stride is span/4 = 342, and each
        // slot gives up the 2px gap from its content height.
        assert_eq!(layout.slots[0].rect.height, 340);
        assert_eq!(layout.slots[0].rect.y, 0, "first slot stays flush");
        assert_eq!(layout.slots[1].rect.y - layout.slots[0].rect.bottom(), 2);
        assert_eq!(layout.slots[2].rect.y - layout.slots[1].rect.bottom(), 2);
    }

    #[test]
    fn flush_top_geometry_starts_both_sides_at_zero() {
        let geometry = ReelGeometry {
            top_inset: 0,
            bottom_inset: 0,
            main_height: 0,
            ..ReelGeometry::default()
        };
        let mut reel = FocusReelState::with_geometry(geometry);
        for id in [1, 2, 3, 4, 5, 6] {
            reel.push_back(id);
        }
        let viewport = Rect::new(0, 0, 2560, 1368);
        let layout = reel.layout(viewport);
        let (_, main) = layout.focus.unwrap();
        assert_eq!(main.y, 0, "focus window starts at the top");
        assert_eq!(main.height, 1368, "focus window reaches the bottom");
        assert_eq!(layout.slots[0].rect.y, 0, "reel starts at the top");
        // Fill mode splits the whole span across the four visible slots:
        // 1368 / 4 = 342, tiling the column with no gap and no peek.
        assert_eq!(layout.slots[0].rect.height, 342);
        assert_eq!(layout.slots.len(), 4);
        assert!(layout.slots.iter().all(|slot| slot.fully_visible));
        assert_eq!(layout.slots[3].rect.bottom(), viewport.bottom());
    }

    #[test]
    fn widget_inset_is_reserved_at_the_top() {
        let geometry = ReelGeometry::default();
        let band = geometry.reel_band(viewport());
        assert_eq!(band.y, 216);
        assert_eq!(band.height, 1440 - 216 - 72);
    }

    #[test]
    fn focus_window_promotes_ring_member() {
        let mut reel = reel_with(&[10, 20, 21, 22]);
        assert!(reel.focus_window(21));
        assert_eq!(reel.focus(), Some(21));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![22, 10, 20]);
        assert!(!reel.focus_window(21), "already focused");
        assert!(!reel.focus_window(999), "unknown window");
    }

    #[test]
    fn focus_next_and_prev_walk_the_ring() {
        let mut reel = reel_with(&[1, 2, 3, 4]);
        assert_eq!(reel.focus_next(), Some(2));
        assert_eq!(reel.focus_next(), Some(3));
        assert_eq!(reel.focus_prev(), Some(2));
    }

    #[test]
    fn move_in_ring_reorders_without_touching_focus() {
        let mut reel = reel_with(&[1, 2, 3, 4]);
        assert!(reel.move_in_ring(4, -1));
        assert_eq!(reel.focus(), Some(1));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![2, 4, 3]);
        assert!(reel.move_in_ring(2, 1));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![4, 2, 3]);
    }

    #[test]
    fn rotate_ring_wraps_and_preserves_membership() {
        let mut reel = reel_with(&[1, 2, 3, 4]);
        assert!(reel.rotate_ring(1));
        assert_eq!(reel.focus(), Some(1));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![3, 4, 2]);
        assert!(reel.rotate_ring(-1));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![2, 3, 4]);
        assert!(!reel.rotate_ring(0));
        let all: Vec<WindowId> = std::iter::once(reel.focus().unwrap())
            .chain(reel.ring())
            .collect();
        assert_eq!(all.len(), 4);
    }

    #[test]
    fn sync_membership_prunes_appends_and_reseeds_focus() {
        let mut reel = reel_with(&[1, 2, 3]);
        reel.sync_membership(&[1, 3, 4], Some(1));
        assert_eq!(reel.focus(), Some(1));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![3, 4]);

        reel.remove(1);
        reel.sync_membership(&[3, 4], None);
        assert_eq!(reel.focus(), Some(3));

        reel.sync_membership(&[], None);
        assert!(reel.is_empty());
    }

    #[test]
    fn sync_membership_preserves_order_across_workspace_reload() {
        let mut reel = reel_with(&[1, 2, 3]);
        // Workspace reloaded with the same windows in column order.
        reel.sync_membership(&[1, 2, 3, 4], Some(1));
        assert_eq!(reel.ring().collect::<Vec<_>>(), vec![2, 3, 4]);
    }

    #[test]
    fn scroll_to_window_positions_the_item_in_the_requested_slot() {
        let mut reel = reel_with(&[1, 2, 3, 4, 5, 6, 7]);
        reel.set_reduce_motion(true);
        assert!(reel.scroll_to_window(5, 1));
        // ring order [2,3,4,5,6,7]; target offset puts 5 at visual slot 1.
        assert_eq!(reel.settled_offset(), 2);
    }

    #[test]
    fn serde_roundtrip_preserves_ring_and_geometry() {
        let geometry = ReelGeometry {
            slot_width: 640,
            flip_side_on_promote: true,
            ..ReelGeometry::default()
        };
        let mut reel = FocusReelState::with_geometry(geometry);
        for id in [1, 2, 3] {
            reel.push_back(id);
        }
        reel.promote_slot(0);
        reel.scroll_by(2.5);
        let json = serde_json::to_string(&reel).unwrap();
        let restored: FocusReelState = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.focus(), reel.focus());
        assert_eq!(
            restored.ring().collect::<Vec<_>>(),
            reel.ring().collect::<Vec<_>>()
        );
        assert_eq!(restored.reel_offset(), reel.reel_offset());
        assert_eq!(restored.side(), reel.side());
        assert_eq!(restored.geometry().slot_width, 640);
        assert!(restored.geometry().flip_side_on_promote);
    }

    // ========================================================================
    // Workspace integration
    // ========================================================================

    mod workspace_integration {
        use super::*;
        use crate::{Visibility, Workspace};

        fn seeded_workspace() -> Workspace {
            let mut workspace = Workspace::new();
            for id in [100, 200, 300, 400, 500, 600] {
                workspace.insert_window(id, None).unwrap();
            }
            workspace.enable_focus_reel(ReelGeometry::default());
            workspace
        }

        #[test]
        fn placements_keep_focus_live_and_reel_members_offscreen() {
            let workspace = seeded_workspace();
            let placements = workspace.compute_placements(viewport());
            let visible: Vec<_> = placements
                .iter()
                .filter(|p| p.visibility == Visibility::Visible)
                .collect();
            assert_eq!(visible.len(), 1, "only the focus window is live");
            assert_eq!(visible[0].window_id, 600);
            assert_eq!(visible[0].rect, Rect::new(0, 216, 2048, 1152));
            let offscreen: Vec<_> = placements
                .iter()
                .filter(|p| p.visibility != Visibility::Visible)
                .collect();
            assert_eq!(offscreen.len(), 5);
            assert!(offscreen.iter().all(|p| p.rect.x < 0));
        }

        #[test]
        fn reel_layout_exposes_slot_rects_for_presentation() {
            let workspace = seeded_workspace();
            let layout = workspace.reel_layout(viewport()).expect("reel active");
            assert_eq!(layout.focus.unwrap().0, 600);
            assert_eq!(layout.slots.len(), 4);
            assert_eq!(layout.slots[0].rect, Rect::new(2048, 216, 512, 288));
            assert_eq!(layout.slots[0].window_id, 100);
            assert_eq!(layout.hidden.len(), 1);
        }

        #[test]
        fn promote_keeps_column_focus_in_sync() {
            let mut workspace = seeded_workspace();
            let promoted = workspace.reel_promote(1).expect("promoted");
            assert_eq!(promoted, 200);
            assert_eq!(workspace.focused_window(), Some(200));
            assert_eq!(workspace.focused_visible_window(), Some(200));
            let (column, window) = workspace.find_window_location(200).unwrap();
            assert_eq!(workspace.focused_column_index(), column);
            assert_eq!(workspace.focused_window_index_in_column(), window);
        }

        #[test]
        fn focus_navigation_routes_through_the_reel() {
            let mut workspace = seeded_workspace();
            workspace.focus_next();
            assert_eq!(workspace.focused_window(), Some(100));
            workspace.focus_prev();
            assert_eq!(workspace.focused_window(), Some(600));
            workspace.focus_right();
            assert_eq!(workspace.focused_window(), Some(100));
        }

        #[test]
        fn move_window_commands_rotate_the_reel_instead_of_columns() {
            let mut workspace = seeded_workspace();
            let before = workspace.focus_reel().unwrap().ring().collect::<Vec<_>>();
            workspace.move_window_right();
            let after = workspace.focus_reel().unwrap().ring().collect::<Vec<_>>();
            assert_ne!(before, after);
            assert_eq!(workspace.focused_window(), Some(600), "focus unchanged");
            workspace.move_window_left();
            assert_eq!(
                workspace.focus_reel().unwrap().ring().collect::<Vec<_>>(),
                before,
                "left/right rotate back"
            );
        }

        #[test]
        fn insert_and_remove_keep_ring_membership_in_sync() {
            let mut workspace = seeded_workspace();
            workspace.insert_window(700, None).unwrap();
            let reel = workspace.focus_reel().unwrap();
            assert!(reel.contains(700));
            assert_eq!(reel.focus(), Some(700));

            workspace.remove_window(200).unwrap();
            assert!(!workspace.focus_reel().unwrap().contains(200));
            assert_eq!(workspace.focus_reel().unwrap().len(), 6);
        }

        #[test]
        fn removing_focus_promotes_the_next_reel_item() {
            let mut workspace = seeded_workspace();
            workspace.remove_window(600).unwrap();
            assert_eq!(workspace.focused_window(), Some(100));
            assert!(!workspace.focus_reel().unwrap().contains(600));
        }

        #[test]
        fn append_window_no_focus_does_not_steal_reel_focus() {
            let mut workspace = seeded_workspace();
            assert_eq!(workspace.focused_window(), Some(600));
            workspace.append_window_no_focus(700, None).unwrap();
            assert_eq!(workspace.focused_window(), Some(600));
            assert!(workspace.focus_reel().unwrap().contains(700));
        }

        #[test]
        fn minimized_windows_leave_the_ring_and_return_on_restore() {
            let mut workspace = seeded_workspace();
            assert!(workspace.mark_minimized(300));
            let reel = workspace.focus_reel().unwrap();
            assert!(!reel.contains(300));
            assert!(workspace.mark_restored(300));
            assert!(workspace.focus_reel().unwrap().contains(300));
        }

        #[test]
        fn reel_scroll_animation_drives_workspace_animation_state() {
            let mut workspace = seeded_workspace();
            workspace.reel_scroll_by(0.5);
            workspace.reel_settle();
            assert!(workspace.is_animating());
            let mut ticks = 0;
            while workspace.tick_animation(16) {
                ticks += 1;
                assert!(ticks < 100);
            }
            assert!(!workspace.is_animating());
            assert_eq!(workspace.reel_offset(), Some(1.0));
        }

        #[test]
        fn reel_serde_survives_workspace_roundtrip() {
            let mut workspace = seeded_workspace();
            workspace.reel_promote(2);
            workspace.reel_scroll_by(1.0);
            let mut guard = 0;
            while workspace.tick_animation(16) {
                guard += 1;
                assert!(guard < 200, "scroll animation must terminate");
            }
            let json = serde_json::to_string(&workspace).unwrap();
            let restored: Workspace = serde_json::from_str(&json).unwrap();
            let reel = restored.focus_reel().expect("reel survives serde");
            assert_eq!(reel.focus(), workspace.focus_reel().unwrap().focus());
            assert_eq!(reel.reel_offset(), 1.0);
        }

        #[test]
        fn disable_restores_column_geometry() {
            let mut workspace = seeded_workspace();
            workspace.disable_focus_reel();
            assert!(!workspace.is_focus_reel());
            let placements = workspace.compute_placements(viewport());
            assert!(placements
                .iter()
                .any(|p| p.visibility == Visibility::Visible && p.rect.width < 900));
        }
    }
}
