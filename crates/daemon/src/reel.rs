//! Focus + Reel presentation and input.
//!
//! The core layout engine decides *where* the focus window and the reel slots
//! are ([`leopardwm_core_layout::FocusReelState`]); this module turns that into
//! the platform presentation:
//!
//! - every visible reel item is a long-lived DWM thumbnail composited on the
//!   shared thumbnail host, so the live source HWND keeps its full-size client
//!   area (no `WM_SIZE`, no app re-layout) while being parked off-screen;
//! - the focused window is live at the main rect;
//! - the reel band is registered with the gesture hook so wheel ticks and
//!   clicks over thumbnails route back into the daemon.
//!
//! Per-frame updates only touch DWM thumbnail destination rects — the same
//! `DwmUpdateThumbnailProperties` path the ghost-animation engine already uses.

use crate::config::LayoutModeConfig;
use crate::state::AppState;
use leopardwm_core_layout::{Easing, Rect, WindowId};
use leopardwm_platform_win32::MonitorId;
use std::collections::HashMap;
use tracing::warn;

/// Windows `WHEEL_DELTA`: one detent of a classic mouse wheel.
const WHEEL_DELTA: f64 = 120.0;

/// One visible reel slot in a presentation plan.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct ReelSlotPlan {
    /// Ring member shown in this slot.
    pub(crate) window_id: u64,
    /// Full screen-space destination rect for the thumbnail.
    pub(crate) rect: Rect,
    /// Reel band used to clip partially scrolled slots.
    pub(crate) clip: Rect,
    /// Whether the slot lies entirely inside the reel band.
    pub(crate) fully_visible: bool,
}

/// Platform-agnostic presentation plan for the current frame.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct ReelPresentationPlan {
    /// The live focus window and its main rect.
    pub(crate) focus: Option<(WindowId, Rect)>,
    /// Visible slots, in top-to-bottom order.
    pub(crate) slots: Vec<ReelSlotPlan>,
    /// Ring members kept registered but hidden (scrolled out of view).
    pub(crate) hidden: Vec<u64>,
    /// Screen-space reel band of the focused monitor, for click interception.
    pub(crate) click_region: Option<Rect>,
}

/// A short thumbnail-rect tween played after a Serval promotion.
///
/// Every previously visible destination rect animates to its new one while
/// the live windows jump to their final layout: the promoted item scales up
/// from its slot to the main rect, the demoted main window scales back down
/// into the reel, and the remaining slots slide. This reuses the same DWM
/// thumbnail host the ghost-animation engine composites on, so no per-frame
/// `SetWindowPos` is issued for the animated windows.
#[derive(Debug)]
pub(crate) struct ReelTransition {
    /// Milliseconds elapsed since the promotion.
    elapsed_ms: u64,
    /// Total tween duration.
    duration_ms: u64,
    /// Easing curve (read by the DWM presentation path only).
    #[cfg_attr(test, allow(dead_code))]
    easing: Easing,
    /// Destination rects from the previous frame, keyed by window
    /// (read by the DWM presentation path only).
    #[cfg_attr(test, allow(dead_code))]
    from_rects: HashMap<WindowId, Rect>,
    /// Window being promoted to the main position. Its live HWND must not be
    /// moved until the tween finishes: the overlay thumbnail is the only
    /// representation of it during the animation, so moving the live window
    /// first would be a visible jump.
    focus_window: Option<WindowId>,
}

impl ReelTransition {
    /// Eased progress in `0.0..=1.0`.
    #[cfg_attr(test, allow(dead_code))]
    fn progress(&self) -> f64 {
        if self.duration_ms == 0 {
            return 1.0;
        }
        let linear = (self.elapsed_ms as f64 / self.duration_ms as f64).clamp(0.0, 1.0);
        self.easing.apply(linear)
    }

    /// Advance by `delta_ms`; returns true while still running.
    pub(crate) fn tick(&mut self, delta_ms: u64) -> bool {
        self.elapsed_ms = self.elapsed_ms.saturating_add(delta_ms);
        self.elapsed_ms < self.duration_ms
    }
}

/// Linear interpolation between two screen rects.
fn lerp_rect(from: Rect, to: Rect, t: f64) -> Rect {
    let t = t.clamp(0.0, 1.0);
    let blend = |a: i32, b: i32| (a as f64 + (b as f64 - a as f64) * t).round() as i32;
    Rect::new(
        blend(from.x, to.x),
        blend(from.y, to.y),
        blend(from.width, to.width),
        blend(from.height, to.height),
    )
}

/// The destination rect a thumbnail should use for this frame: the tweened
/// rect when a transition is active and the window has a previous rect,
/// otherwise the settled target.
#[cfg_attr(test, allow(dead_code))]
fn tweened_dest(transition: &ReelTransition, window_id: WindowId, target: Rect) -> Rect {
    match transition.from_rects.get(&window_id) {
        Some(&from) if from != target => lerp_rect(from, target, transition.progress()),
        _ => target,
    }
}

/// Snapshot every currently presented destination rect (focus + visible
/// slots) so a promotion can tween from it.
fn presentation_rects(plan: &ReelPresentationPlan) -> HashMap<WindowId, Rect> {
    let mut rects = HashMap::new();
    if let Some((window_id, rect)) = plan.focus {
        rects.insert(window_id, rect);
    }
    for slot in &plan.slots {
        rects.insert(slot.window_id, slot.rect);
    }
    rects
}

impl AppState {
    /// Whether the configured layout model is Serval (Focus + Reel).
    pub(crate) fn reel_mode_active(&self) -> bool {
        self.config.layout.mode == LayoutModeConfig::Serval
    }

    /// Monitor whose full rect contains the given screen point.
    pub(crate) fn monitor_at_point(&self, x: i32, y: i32) -> Option<MonitorId> {
        self.monitors
            .iter()
            .find(|(_, monitor)| {
                x >= monitor.rect.x
                    && x < monitor.rect.x + monitor.rect.width
                    && y >= monitor.rect.y
                    && y < monitor.rect.y + monitor.rect.height
            })
            .map(|(&id, _)| id)
    }

    /// Route a raw wheel tick to the reel under the cursor.
    ///
    /// Returns `true` when the wheel was over the reel column and the offset
    /// moved. The reel engine arms its own settle timer, so the caller only
    /// needs to drive the animation frame loop afterwards.
    pub(crate) fn handle_reel_wheel(&mut self, delta: i32, x: i32, y: i32) -> bool {
        if !self.reel_mode_active() {
            return false;
        }
        let Some(monitor_id) = self.monitor_at_point(x, y) else {
            return false;
        };
        let viewport = self.layout_viewport(monitor_id);
        let workspace_index = self.active_workspace_idx(monitor_id);
        let Some(workspace) = self
            .workspaces
            .get_mut(&monitor_id)
            .and_then(|list| list.get_mut(workspace_index))
        else {
            return false;
        };
        if workspace.is_fullscreen() {
            return false;
        }
        // A reel with `visible_slots` or fewer items fits entirely; the wheel
        // has nothing to scroll.
        if !workspace.reel_can_scroll() {
            return false;
        }
        if workspace.reel_hit_test(viewport, x, y).is_none() {
            return false;
        }
        // Windows reports positive deltas for wheel-up; standard scrolling
        // shows earlier content on wheel-up, so invert into slot units
        // (positive = advance toward later reel items).
        workspace.reel_scroll_by(-(delta as f64) / WHEEL_DELTA);
        self.focused_monitor = monitor_id;
        true
    }

    /// Promote the reel item under a click.
    ///
    /// Returns `true` when a slot was hit and promoted. The caller is
    /// responsible for driving the layout/animation frame loop.
    pub(crate) fn handle_reel_click(&mut self, x: i32, y: i32) -> bool {
        if !self.reel_mode_active() {
            return false;
        }
        let Some(monitor_id) = self.monitor_at_point(x, y) else {
            return false;
        };
        let viewport = self.layout_viewport(monitor_id);
        let workspace_index = self.active_workspace_idx(monitor_id);
        // Snapshot the presentation before the ring changes so the promotion
        // can tween every thumbnail from its previous rect.
        let from_rects = presentation_rects(&plan_reel_presentation(self));
        let Some(workspace) = self
            .workspaces
            .get_mut(&monitor_id)
            .and_then(|list| list.get_mut(workspace_index))
        else {
            return false;
        };
        if workspace.is_fullscreen() {
            return false;
        }
        let Some((slot, window_id)) = workspace.reel_hit_test(viewport, x, y) else {
            return false;
        };
        let promoted = workspace.reel_promote(slot);
        self.begin_reel_transition(from_rects, promoted.or(Some(window_id)));
        self.focused_monitor = monitor_id;
        if let Err(error) = self.apply_layout() {
            warn!(
                "Focus + Reel promotion of window {} failed to apply: {}",
                window_id, error
            );
        }
        self.sync_foreground_window();
        true
    }

    /// Start the short thumbnail tween for a promotion, if motion is allowed.
    pub(crate) fn begin_reel_transition(
        &mut self,
        from_rects: HashMap<WindowId, Rect>,
        focus_window: Option<WindowId>,
    ) {
        let duration_ms = self.config.animation.layout_duration_ms;
        if self.reduce_motion || duration_ms == 0 || from_rects.is_empty() {
            self.reel_transition = None;
            return;
        }
        self.reel_transition = Some(ReelTransition {
            elapsed_ms: 0,
            duration_ms,
            easing: self.config.animation.easing,
            from_rects,
            focus_window,
        });
    }

    /// Drop the promoted window from a placement batch while its promotion
    /// tween is running, so the live HWND stays parked until the landing pass.
    pub(crate) fn suppress_reel_transition_focus(
        &self,
        placements: &mut Vec<leopardwm_core_layout::WindowPlacement>,
    ) {
        let Some(focus_window) = self
            .reel_transition
            .as_ref()
            .and_then(|transition| transition.focus_window)
        else {
            return;
        };
        placements.retain(|placement| placement.window_id != focus_window);
    }

    /// Reconcile DWM thumbnails and the input region with the current reel
    /// layout. Cheap: one `DwmUpdateThumbnailProperties` per visible slot.
    pub(crate) fn sync_reel_presentation(&mut self) {
        let active = self.reel_mode_active();

        #[cfg(not(test))]
        {
            self.apply_reel_presentation(active);
        }
        #[cfg(test)]
        {
            let _ = active;
            if self.reel_mode_active() {
                self.last_reel_presentation = Some(plan_reel_presentation(self));
            } else {
                self.last_reel_presentation = None;
            }
        }
    }

    #[cfg(not(test))]
    fn apply_reel_presentation(&mut self, active: bool) {
        leopardwm_platform_win32::set_reel_input_enabled(active && !self.paused);
        if !active {
            // Nothing owns the parked sources anymore; unregister everything.
            self.reel_thumbnails.clear();
            leopardwm_platform_win32::set_reel_region(None);
            // Undo the Serval main-window decoration removal.
            self.reel_last_squared_focus = None;
            leopardwm_platform_win32::restore_squared_corners_all();
            return;
        }

        let plan = plan_reel_presentation(self);
        // Serval main window is flush to the work-area edges, so strip the
        // windowed-mode rounded corners and the 1px DWM outline. Only when the
        // focus changes: the demoted window stays square while parked in the
        // reel (invisible) and is restored when it leaves management.
        let focus_id = plan.focus.map(|(window_id, _)| window_id);
        if self.reel_last_squared_focus != focus_id {
            if let Some(window_id) = focus_id {
                let _ = leopardwm_platform_win32::square_window_corners(window_id);
            }
            self.reel_last_squared_focus = focus_id;
        }
        // Promote tween: the promoted window is already the live focus and has
        // no slot, but while the tween runs it needs an overlay thumbnail so
        // it can scale from its old slot rect to the main rect.
        let focus_overlay = self.reel_transition.as_ref().and_then(|transition| {
            let (focus_id, main_rect) = plan.focus?;
            let from = *transition.from_rects.get(&focus_id)?;
            (from != main_rect && transition.elapsed_ms < transition.duration_ms)
                .then_some((focus_id, main_rect))
        });

        let mut wanted: std::collections::HashSet<u64> =
            plan.slots.iter().map(|slot| slot.window_id).collect();
        wanted.extend(plan.hidden.iter().copied());
        if let Some((focus_id, _)) = focus_overlay {
            wanted.insert(focus_id);
        }
        // Dropping a handle unregisters it (focus windows become live again,
        // removed windows leave the ring).
        self.reel_thumbnails.retain(|wid, _| wanted.contains(wid));

        for slot in &plan.slots {
            use std::collections::hash_map::Entry;
            if let Entry::Vacant(entry) = self.reel_thumbnails.entry(slot.window_id) {
                match leopardwm_platform_win32::thumbnail::register(slot.window_id) {
                    Ok(handle) => {
                        entry.insert(handle);
                    }
                    Err(error) => {
                        warn!(
                            "Focus + Reel thumbnail registration for window {} failed: {}",
                            slot.window_id, error
                        );
                        continue;
                    }
                }
            }
            let dest = self
                .reel_transition
                .as_ref()
                .map_or(slot.rect, |transition| {
                    tweened_dest(transition, slot.window_id, slot.rect)
                });
            if let Some(handle) = self.reel_thumbnails.get(&slot.window_id) {
                if slot.fully_visible {
                    let _ = leopardwm_platform_win32::thumbnail::update_screen_rect(
                        handle.as_isize(),
                        dest,
                        255,
                        true,
                    );
                } else {
                    // Partially scrolled: clip via rcSource so it slides under
                    // the widget/taskbar strips without stretching.
                    let _ = leopardwm_platform_win32::thumbnail::update_screen_rect_clipped(
                        handle.as_isize(),
                        dest,
                        slot.clip,
                    );
                }
            }
        }
        if let Some((focus_id, main_rect)) = focus_overlay {
            use std::collections::hash_map::Entry;
            if let Entry::Vacant(entry) = self.reel_thumbnails.entry(focus_id) {
                match leopardwm_platform_win32::thumbnail::register(focus_id) {
                    Ok(handle) => {
                        entry.insert(handle);
                    }
                    Err(error) => {
                        warn!(
                            "Serval focus overlay registration for window {} failed: {}",
                            focus_id, error
                        );
                    }
                }
            }
            if let Some(handle) = self.reel_thumbnails.get(&focus_id) {
                let dest = self
                    .reel_transition
                    .as_ref()
                    .map_or(main_rect, |transition| {
                        tweened_dest(transition, focus_id, main_rect)
                    });
                let _ = leopardwm_platform_win32::thumbnail::update_screen_rect(
                    handle.as_isize(),
                    dest,
                    255,
                    true,
                );
            }
        }
        for window_id in &plan.hidden {
            if let Some(handle) = self.reel_thumbnails.get(window_id) {
                let _ = leopardwm_platform_win32::thumbnail::update_screen_rect(
                    handle.as_isize(),
                    Rect::new(0, 0, 0, 0),
                    255,
                    false,
                );
            }
        }

        let region = plan
            .click_region
            .map(|rect| (rect.x, rect.y, rect.width, rect.height));
        leopardwm_platform_win32::set_reel_region(region);
    }
}

/// Build the presentation plan for the current layout. Pure — unit-testable
/// without touching DWM.
pub(crate) fn plan_reel_presentation(state: &AppState) -> ReelPresentationPlan {
    let mut plan = ReelPresentationPlan::default();

    for &monitor_id in state.monitors.keys() {
        let workspace_index = state.active_workspace_idx(monitor_id);
        let Some(workspace) = state
            .workspaces
            .get(&monitor_id)
            .and_then(|list| list.get(workspace_index))
        else {
            continue;
        };
        let viewport = state.layout_viewport(monitor_id);
        // A fullscreen window owns the whole monitor: hide the reel.
        if workspace.is_fullscreen() {
            continue;
        }
        let Some(layout) = workspace.reel_layout(viewport) else {
            continue;
        };
        if let Some((focus_id, main_rect)) = layout.focus {
            plan.focus = Some((focus_id, main_rect));
        }
        for slot in &layout.slots {
            plan.slots.push(ReelSlotPlan {
                window_id: slot.window_id,
                rect: slot.rect,
                clip: layout.column_rect,
                fully_visible: slot.fully_visible,
            });
        }
        plan.hidden.extend(layout.hidden.iter().copied());
        // Only the focused monitor's reel receives raw input; a wheel or click
        // on another monitor's reel is handled when that monitor gains focus.
        // Interception is limited to the rendered slots so the blank part of a
        // partially-filled column passes clicks through.
        if monitor_id == state.focused_monitor {
            plan.click_region = layout.rendered_region();
        }
    }

    plan
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::state::AppState;
    use leopardwm_core_layout::Workspace;
    use leopardwm_platform_win32::MonitorInfo;

    fn test_monitors() -> Vec<MonitorInfo> {
        vec![MonitorInfo {
            id: 1,
            rect: Rect::new(0, 0, 2560, 1440),
            work_area: Rect::new(0, 0, 2560, 1440),
            is_primary: true,
            device_name: "DISPLAY1".to_string(),
            scale_factor: 1.0,
        }]
    }

    fn reel_state() -> AppState {
        let mut config = Config::default();
        config.layout.mode = LayoutModeConfig::Serval;
        let mut state = AppState::new_with_config(config, test_monitors());
        let workspace: &mut Workspace = state
            .workspaces
            .get_mut(&1)
            .and_then(|list| list.first_mut())
            .expect("workspace");
        for id in [100, 200, 300, 400, 500, 600] {
            workspace.insert_window(id, None).unwrap();
        }
        // Seeding promotes each new window, which alternates the reel side
        // under the default flip-on-promote; normalize for geometry asserts.
        workspace.reel_set_side(leopardwm_core_layout::ReelSide::Right);
        state
    }

    #[test]
    fn plan_lists_visible_slots_and_click_region() {
        let state = reel_state();
        let plan = plan_reel_presentation(&state);
        assert_eq!(plan.focus, Some((600, Rect::new(0, 0, 2048, 1440))));
        // 1440 / 4 = 360: the four visible slots tile the reel column exactly.
        assert_eq!(plan.slots.len(), 4);
        // Each inserted window took focus, so the most recent demotions sit
        // at the top of the reel: focus 600, ring [500, 400, 300, 200, 100].
        assert_eq!(plan.slots[0].window_id, 500);
        assert_eq!(plan.slots[0].rect, Rect::new(2048, 0, 512, 360));
        assert_eq!(plan.hidden, vec![100]);
        let region = plan.click_region.expect("focused monitor region");
        assert_eq!(region, Rect::new(2048, 0, 512, 1440));
    }

    #[test]
    fn wheel_over_the_reel_animates_the_offset() {
        let mut state = reel_state();
        // Wheel down (negative OS delta) advances toward later items.
        assert!(state.handle_reel_wheel(-120, 2300, 400));
        // The offset eases toward the target instead of jumping.
        let mut guard = 0;
        while state.is_animating() && guard < 500 {
            state.tick_animations(16);
            guard += 1;
        }
        let offset = state
            .workspaces
            .get(&1)
            .and_then(|list| list.first())
            .and_then(|ws| ws.reel_offset());
        assert!((offset.unwrap() - 1.0).abs() < 1e-9);

        // Wheel up returns toward the first item.
        assert!(state.handle_reel_wheel(120, 2300, 400));
        let mut guard = 0;
        while state.is_animating() && guard < 500 {
            state.tick_animations(16);
            guard += 1;
        }
        let offset = state
            .workspaces
            .get(&1)
            .and_then(|list| list.first())
            .and_then(|ws| ws.reel_offset());
        assert!(offset.unwrap().abs() < 1e-9);
    }

    #[test]
    fn wheel_over_the_focus_window_is_ignored() {
        let mut state = reel_state();
        assert!(!state.handle_reel_wheel(-120, 1000, 400));
    }

    #[test]
    fn wheel_outside_focus_reel_mode_is_ignored() {
        let mut config = Config::default();
        config.layout.mode = LayoutModeConfig::Scroll;
        let mut state = AppState::new_with_config(config, test_monitors());
        let workspace = state.workspaces.get_mut(&1).unwrap().first_mut().unwrap();
        for id in [100, 200, 300, 400, 500, 600] {
            workspace.insert_window(id, None).unwrap();
        }
        assert!(!state.handle_reel_wheel(-120, 2300, 400));
    }

    #[test]
    fn click_on_a_slot_promotes_that_window() {
        let mut state = reel_state();
        // Second slot starts at 360 (fill mode: 1440 / 4).
        assert!(state.handle_reel_click(2300, 360 + 10));
        let focused = state
            .workspaces
            .get(&1)
            .and_then(|list| list.first())
            .and_then(|ws| ws.focused_window());
        assert_eq!(focused, Some(400));
    }

    #[test]
    fn click_on_the_focus_window_is_ignored() {
        let mut state = reel_state();
        assert!(!state.handle_reel_click(1000, 400));
    }

    #[test]
    fn wheel_does_not_scroll_a_reel_that_fits() {
        let mut config = Config::default();
        config.layout.mode = LayoutModeConfig::Serval;
        let mut state = AppState::new_with_config(config, test_monitors());
        let workspace = state.workspaces.get_mut(&1).unwrap().first_mut().unwrap();
        workspace.insert_window(100, None).unwrap();
        workspace.insert_window(200, None).unwrap();
        workspace.reel_set_side(leopardwm_core_layout::ReelSide::Right);
        // Focus 200 + one small window: the reel fits, so the wheel is ignored.
        assert!(!state.handle_reel_wheel(120, 2300, 100));
        assert_eq!(
            state.workspaces[&1]
                .first()
                .and_then(|workspace| workspace.reel_offset()),
            Some(0.0),
            "offset stays at the top"
        );
    }

    #[test]
    fn click_below_the_last_slot_is_ignored() {
        let mut config = Config::default();
        config.layout.mode = LayoutModeConfig::Serval;
        let mut state = AppState::new_with_config(config, test_monitors());
        let workspace = state.workspaces.get_mut(&1).unwrap().first_mut().unwrap();
        workspace.insert_window(100, None).unwrap();
        workspace.insert_window(200, None).unwrap();
        workspace.reel_set_side(leopardwm_core_layout::ReelSide::Right);
        // Focus 200 + one reel item (100) => a single slot at the top.
        let plan = plan_reel_presentation(&state);
        assert_eq!(plan.click_region, Some(Rect::new(2048, 0, 512, 360)));
        assert!(
            !state.handle_reel_click(2300, 600),
            "blank space under the reel column must not wrap around the ring"
        );
        assert!(state.handle_reel_click(2300, 300));
    }

    #[test]
    fn promoting_a_right_reel_item_mirrors_the_layout() {
        let mut state = reel_state();
        let before = plan_reel_presentation(&state);
        assert_eq!(before.slots[0].rect.x, 2048, "reel starts on the right");
        assert_eq!(before.focus.unwrap().1.x, 0, "main starts on the left");

        // Promote the second slot of the right-hand reel.
        assert!(state.handle_reel_click(2300, 360 + 10));

        let after = plan_reel_presentation(&state);
        let (promoted, main) = after.focus.expect("focus window");
        assert_eq!(promoted, 400, "clicked slot became the focus");
        assert_eq!(main.x, 512, "promoted window grew into the right-hand main");
        assert_eq!(main.width, 2048);
        assert_eq!(after.slots[0].rect.x, 0, "reel mirrored to the left");
        let side = state.workspaces[&1]
            .first()
            .and_then(|ws| ws.focus_reel())
            .map(|reel| reel.side());
        assert_eq!(side, Some(leopardwm_core_layout::ReelSide::Left));

        // The next promotion flips back to the original orientation.
        assert!(state.handle_reel_click(100, 288 + 10));
        let back = plan_reel_presentation(&state);
        assert_eq!(back.slots[0].rect.x, 2048);
        assert_eq!(back.focus.unwrap().1.x, 0);
    }

    #[test]
    fn promotion_tween_suppresses_the_live_focus_move() {
        use leopardwm_core_layout::{Visibility, WindowPlacement};
        let mut state = reel_state();
        assert!(state.handle_reel_click(2300, 360 + 10));
        assert_eq!(
            state
                .reel_transition
                .as_ref()
                .and_then(|transition| transition.focus_window),
            Some(400),
            "the promoted window is the one whose live move is deferred"
        );

        let mut placements = vec![
            WindowPlacement {
                window_id: 400,
                rect: Rect::new(512, 0, 2048, 1440),
                visibility: Visibility::Visible,
                column_index: 0,
            },
            WindowPlacement {
                window_id: 600,
                rect: Rect::new(-2560, 0, 2048, 1440),
                visibility: Visibility::OffScreenLeft,
                column_index: 0,
            },
        ];
        state.suppress_reel_transition_focus(&mut placements);
        assert!(
            placements
                .iter()
                .all(|placement| placement.window_id != 400),
            "the live focus placement is held back during the tween"
        );
        assert_eq!(placements.len(), 1);
    }

    #[test]
    fn monitor_at_point_resolves_the_focused_display() {
        let state = reel_state();
        assert_eq!(state.monitor_at_point(100, 100), Some(1));
        assert_eq!(state.monitor_at_point(-10, 100), None);
    }

    #[test]
    fn default_config_enables_serval() {
        let state = AppState::new_with_config(Config::default(), test_monitors());
        assert!(state.reel_mode_active(), "Serval is the default layout");
        assert!(state.workspaces[&1][0].is_focus_reel());
    }

    #[test]
    fn promote_changes_layout_signature_and_summary() {
        let mut state = reel_state();
        let before_signature = state.focused_layout_signature();
        let before = state.focused_layout_columns();
        assert_eq!(before.len(), 1, "Serval reports one synthesized column");
        assert_eq!(before[0].window_ids[0], 600);

        assert!(state.handle_reel_click(2300, 360 + 10));

        assert_ne!(
            state.focused_layout_signature(),
            before_signature,
            "promotion must emit a fresh LayoutChanged"
        );
        let after = state.focused_layout_columns();
        assert_eq!(
            after[0].window_ids[0], 400,
            "promoted window reported first"
        );
        assert_ne!(before[0].window_ids, after[0].window_ids);
    }

    #[test]
    fn lerp_rect_interpolates_endpoints_and_midpoint() {
        let from = Rect::new(2048, 216, 512, 288);
        let to = Rect::new(0, 216, 2048, 1152);
        assert_eq!(lerp_rect(from, to, 0.0), from);
        assert_eq!(lerp_rect(from, to, 1.0), to);
        assert_eq!(lerp_rect(from, to, 0.5), Rect::new(1024, 216, 1280, 720));
    }

    #[test]
    fn click_starts_a_promotion_tween() {
        let mut state = reel_state();
        assert!(state.handle_reel_click(2300, 360 + 10));
        assert!(
            state.reel_transition.is_some(),
            "promotion arms the thumbnail tween"
        );
    }

    #[test]
    fn promotion_tween_clears_after_its_duration() {
        let mut state = reel_state();
        assert!(state.handle_reel_click(2300, 360 + 10));
        let mut ticks = 0;
        while state.reel_transition.is_some() {
            state.tick_animations(50);
            ticks += 1;
            assert!(ticks < 100, "tween must terminate");
        }
        assert!(!state.is_animating());
    }

    #[test]
    fn reduce_motion_skips_the_promotion_tween() {
        let mut state = reel_state();
        state.reduce_motion = true;
        assert!(state.handle_reel_click(2300, 360 + 10));
        assert!(state.reel_transition.is_none());
    }
}
