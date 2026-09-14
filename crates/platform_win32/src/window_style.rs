//! Window style tweaks: DWM border color and WS_MAXIMIZEBOX (snap layout) management.

use crate::types::Win32Error;
use crate::window_id_to_hwnd;
use leopardwm_core_layout::WindowId;
use std::collections::HashSet;
use std::ffi::c_void;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use windows::core::BOOL;
use windows::Win32::Foundation::{GetLastError, SetLastError, HWND, RECT, WIN32_ERROR};
use windows::Win32::Graphics::Dwm::{
    DwmGetWindowAttribute, DwmSetWindowAttribute, DWMWA_EXTENDED_FRAME_BOUNDS,
    DWMWA_NCRENDERING_ENABLED,
};
use windows::Win32::System::Threading::{GetCurrentProcessId, GetCurrentThreadId};
use windows::Win32::UI::WindowsAndMessaging::IsWindow;

// ============================================================================
// Border color
// ============================================================================

/// Set the DWM border color for a window (Windows 11+).
///
/// Returns Ok(true) if the border was set, Ok(false) if the API is unsupported.
pub fn set_window_border_color(hwnd: WindowId, color: u32) -> Result<bool, Win32Error> {
    let window_id = hwnd;
    let hwnd = window_id_to_hwnd(window_id)?;
    unsafe {
        if !IsWindow(Some(hwnd)).as_bool() {
            return Err(Win32Error::WindowNotFound(window_id));
        }

        // DWMWA_BORDER_COLOR = 34
        const DWMWA_BORDER_COLOR: u32 = 34;
        let colorref = color;
        let result = DwmSetWindowAttribute(
            hwnd,
            windows::Win32::Graphics::Dwm::DWMWINDOWATTRIBUTE(DWMWA_BORDER_COLOR as i32),
            &colorref as *const u32 as *const c_void,
            std::mem::size_of::<u32>() as u32,
        );
        match result {
            Ok(()) => Ok(true),
            Err(e) => {
                if !IsWindow(Some(hwnd)).as_bool() {
                    return Err(Win32Error::WindowNotFound(window_id));
                }

                if is_border_color_unsupported_hresult(e.code()) {
                    return Ok(false);
                }

                Err(Win32Error::SetPositionFailed(format!(
                    "DwmSetWindowAttribute(DWMWA_BORDER_COLOR) failed for {:?}: {}",
                    hwnd, e
                )))
            }
        }
    }
}

/// Reset the DWM border color for a window to the default.
///
/// Returns Ok(true) if the border was reset, Ok(false) if the API is unsupported.
pub fn reset_window_border_color(hwnd: WindowId) -> Result<bool, Win32Error> {
    // DWMWA_COLOR_DEFAULT = 0xFFFFFFFF
    set_window_border_color(hwnd, 0xFFFFFFFF)
}

fn is_border_color_unsupported_hresult(code: windows::core::HRESULT) -> bool {
    const E_INVALIDARG_HRESULT: i32 = 0x8007_0057u32 as i32;
    const E_NOTIMPL_HRESULT: i32 = 0x8000_4001u32 as i32;
    code.0 == E_INVALIDARG_HRESULT || code.0 == E_NOTIMPL_HRESULT
}

// ============================================================================
// Snap layout suppression (WS_MAXIMIZEBOX removal)
// ============================================================================

/// Global set of window IDs whose WS_MAXIMIZEBOX style has been removed.
/// Used for panic recovery when AppState may be poisoned/unavailable.
static SNAP_DISABLED_HWNDS: Mutex<Option<HashSet<WindowId>>> = Mutex::new(None);

fn lock_snap_disabled() -> std::sync::MutexGuard<'static, Option<HashSet<WindowId>>> {
    SNAP_DISABLED_HWNDS
        .lock()
        .unwrap_or_else(crate::recover_poisoned_mutex)
}

// ============================================================================
// Maximize-box geometry diagnostics
// ============================================================================

const MAXIMIZEBOX_GEOMETRY_TARGET: &str = "leopardwm::window_style";
const MAXIMIZEBOX_GEOMETRY_EVENT: &str = "maximizebox_geometry";

static MAXIMIZEBOX_GEOMETRY_CORRELATION: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct MaximizeboxGeometrySnapshot {
    style: Result<i32, i32>,
    ex_style: Result<i32, i32>,
    window_rect: Result<[i32; 4], i32>,
    client_rect: Result<[i32; 4], i32>,
    dwm_frame: Result<[i32; 4], i32>,
    nc_rendering: Result<bool, i32>,
}

fn capture_maximizebox_geometry(hwnd: HWND) -> MaximizeboxGeometrySnapshot {
    use windows::Win32::UI::WindowsAndMessaging::{
        GetClientRect, GetWindowLongW, GetWindowRect, GWL_EXSTYLE, GWL_STYLE,
    };

    unsafe {
        let previous_error = GetLastError();
        // GetWindowLongW returns 0 for both failure and a real zero value.
        // SetLastError(0) first; a later nonzero last error is the failed read.
        let style_bits = |index| {
            SetLastError(WIN32_ERROR(0));
            let value = GetWindowLongW(hwnd, index);
            if value == 0 {
                let err = GetLastError().0;
                if err == 0 {
                    Ok(0)
                } else {
                    Err(windows::core::HRESULT::from_win32(err).0)
                }
            } else {
                Ok(value)
            }
        };
        let rect = |query: windows::core::Result<()>, rect: RECT| match query {
            Ok(()) => Ok([rect.left, rect.top, rect.right, rect.bottom]),
            Err(error) => Err(error.code().0),
        };

        let style = style_bits(GWL_STYLE);
        let ex_style = style_bits(GWL_EXSTYLE);
        let mut window_rect = RECT::default();
        let window_rect = rect(GetWindowRect(hwnd, &mut window_rect), window_rect);
        let mut client_rect = RECT::default();
        let client_rect = rect(GetClientRect(hwnd, &mut client_rect), client_rect);
        let mut dwm_frame = RECT::default();
        let dwm_frame = rect(
            DwmGetWindowAttribute(
                hwnd,
                DWMWA_EXTENDED_FRAME_BOUNDS,
                &mut dwm_frame as *mut RECT as *mut c_void,
                std::mem::size_of::<RECT>() as u32,
            ),
            dwm_frame,
        );
        let mut nc_enabled = BOOL::default();
        let nc_rendering = match DwmGetWindowAttribute(
            hwnd,
            DWMWA_NCRENDERING_ENABLED,
            &mut nc_enabled as *mut BOOL as *mut c_void,
            std::mem::size_of::<BOOL>() as u32,
        ) {
            Ok(()) => Ok(nc_enabled.as_bool()),
            Err(error) => Err(error.code().0),
        };
        SetLastError(previous_error);
        MaximizeboxGeometrySnapshot {
            style,
            ex_style,
            window_rect,
            client_rect,
            dwm_frame,
            nc_rendering,
        }
    }
}

fn log_maximizebox_geometry(
    operation: &'static str,
    stage: &'static str,
    hwnd: HWND,
    correlation_id: u64,
    set_window_pos_hr: Option<i32>,
) {
    // Skip Win32 geometry queries unless this dedicated debug target is enabled.
    if !tracing::enabled!(target: MAXIMIZEBOX_GEOMETRY_TARGET, tracing::Level::DEBUG) {
        return;
    }

    let previous_error = unsafe { GetLastError() };
    let snapshot = capture_maximizebox_geometry(hwnd);
    let pid = unsafe { GetCurrentProcessId() };
    let tid = unsafe { GetCurrentThreadId() };
    tracing::debug!(
        target: MAXIMIZEBOX_GEOMETRY_TARGET,
        operation,
        stage,
        hwnd = hwnd.0 as usize as u64,
        pid,
        tid,
        correlation_id,
        style = ?snapshot.style,
        ex_style = ?snapshot.ex_style,
        window_rect = ?snapshot.window_rect,
        client_rect = ?snapshot.client_rect,
        dwm_frame = ?snapshot.dwm_frame,
        nc_rendering = ?snapshot.nc_rendering,
        set_window_pos_hr,
        event = MAXIMIZEBOX_GEOMETRY_EVENT,
    );
    unsafe { SetLastError(previous_error) };
}

/// Remove `WS_MAXIMIZEBOX` from a window to disable Windows 11 Snap Layouts.
///
/// Returns `Ok(true)` if the style was changed, `Ok(false)` if already absent.
/// Registers the window in the global tracking set for panic recovery.
///
/// Uses `GetWindowLongW`/`SetWindowLongW` (32-bit) intentionally: on 64-bit
/// Windows this disables the DWM snap layout flyout while preserving the
/// maximize button and its click-to-maximize behavior.
pub fn remove_maximizebox(window_id: WindowId) -> Result<bool, Win32Error> {
    use windows::Win32::UI::WindowsAndMessaging::{
        GetWindowLongW, SetWindowLongW, SetWindowPos, GWL_STYLE, SWP_FRAMECHANGED, SWP_NOACTIVATE,
        SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER,
    };

    let hwnd = window_id_to_hwnd(window_id)?;
    unsafe {
        if !IsWindow(Some(hwnd)).as_bool() {
            return Err(Win32Error::WindowNotFound(window_id));
        }

        let style = GetWindowLongW(hwnd, GWL_STYLE);
        const WS_MAXIMIZEBOX: i32 = 0x0001_0000;
        if (style & WS_MAXIMIZEBOX) == 0 {
            return Ok(false); // Already absent
        }

        let correlation_id = MAXIMIZEBOX_GEOMETRY_CORRELATION.fetch_add(1, Ordering::Relaxed);
        log_maximizebox_geometry("remove", "before_style", hwnd, correlation_id, None);

        let new_style = style & !WS_MAXIMIZEBOX;
        SetWindowLongW(hwnd, GWL_STYLE, new_style);

        log_maximizebox_geometry("remove", "after_style", hwnd, correlation_id, None);

        let frame_result = SetWindowPos(
            hwnd,
            None,
            0,
            0,
            0,
            0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
        );
        log_maximizebox_geometry(
            "remove",
            "after_frame",
            hwnd,
            correlation_id,
            Some(match &frame_result {
                Ok(()) => 0,
                Err(error) => error.code().0,
            }),
        );

        let mut guard = lock_snap_disabled();
        guard.get_or_insert_with(HashSet::new).insert(window_id);
    }
    Ok(true)
}

/// Restore `WS_MAXIMIZEBOX` on a window, re-enabling Windows 11 Snap Layouts.
///
/// Returns `Ok(true)` if the style was restored, `Ok(false)` if already present.
/// Removes the window from the global tracking set.
pub fn restore_maximizebox(window_id: WindowId) -> Result<bool, Win32Error> {
    use windows::Win32::UI::WindowsAndMessaging::{
        GetWindowLongW, SetWindowLongW, SetWindowPos, GWL_STYLE, SWP_FRAMECHANGED, SWP_NOACTIVATE,
        SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER,
    };

    // Always remove from tracking set, even if the Win32 call fails
    {
        let mut guard = lock_snap_disabled();
        if let Some(ref mut set) = *guard {
            set.remove(&window_id);
        }
    }

    let hwnd = window_id_to_hwnd(window_id)?;
    unsafe {
        if !IsWindow(Some(hwnd)).as_bool() {
            return Err(Win32Error::WindowNotFound(window_id));
        }

        let style = GetWindowLongW(hwnd, GWL_STYLE);
        const WS_MAXIMIZEBOX: i32 = 0x0001_0000;
        if (style & WS_MAXIMIZEBOX) != 0 {
            return Ok(false); // Already present
        }

        let correlation_id = MAXIMIZEBOX_GEOMETRY_CORRELATION.fetch_add(1, Ordering::Relaxed);
        log_maximizebox_geometry("restore", "before_style", hwnd, correlation_id, None);

        let new_style = style | WS_MAXIMIZEBOX;
        SetWindowLongW(hwnd, GWL_STYLE, new_style);

        log_maximizebox_geometry("restore", "after_style", hwnd, correlation_id, None);

        let frame_result = SetWindowPos(
            hwnd,
            None,
            0,
            0,
            0,
            0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
        );
        log_maximizebox_geometry(
            "restore",
            "after_frame",
            hwnd,
            correlation_id,
            Some(match &frame_result {
                Ok(()) => 0,
                Err(error) => error.code().0,
            }),
        );
    }
    Ok(true)
}

/// Best-effort bulk restore of `WS_MAXIMIZEBOX` for multiple windows.
/// Never panics — logs failures and continues.
pub fn restore_maximizebox_all(window_ids: &[WindowId]) {
    for &wid in window_ids {
        match restore_maximizebox(wid) {
            Ok(_) => {}
            Err(Win32Error::WindowNotFound(_)) => {
                // Window already destroyed — tracking set already cleaned up
            }
            Err(e) => {
                tracing::warn!("Failed to restore WS_MAXIMIZEBOX for window {}: {}", wid, e);
            }
        }
    }
}

/// Emergency restore of `WS_MAXIMIZEBOX` for all tracked windows.
/// Drains the global tracking set and restores styles best-effort.
/// Safe to call from panic hooks (no AppState needed).
pub fn restore_maximizebox_panic_recovery() {
    let window_ids: Vec<WindowId> = {
        let mut guard = lock_snap_disabled();
        guard
            .as_mut()
            .map(|set| set.drain().collect())
            .unwrap_or_default()
    };

    if window_ids.is_empty() {
        return;
    }

    eprintln!(
        "[leopardwm] Restoring WS_MAXIMIZEBOX for {} window(s) in panic recovery",
        window_ids.len()
    );

    for wid in &window_ids {
        // Direct Win32 call — don't use restore_maximizebox since tracking set is already drained
        use windows::Win32::UI::WindowsAndMessaging::{
            GetWindowLongW, SetWindowLongW, SetWindowPos, GWL_STYLE, SWP_FRAMECHANGED,
            SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER,
        };
        let Ok(hwnd) = window_id_to_hwnd(*wid) else {
            continue;
        };
        unsafe {
            if !IsWindow(Some(hwnd)).as_bool() {
                continue;
            }
            let style = GetWindowLongW(hwnd, GWL_STYLE);
            const WS_MAXIMIZEBOX_VAL: i32 = 0x0001_0000;
            if (style & WS_MAXIMIZEBOX_VAL) == 0 {
                let new_style = style | WS_MAXIMIZEBOX_VAL;
                SetWindowLongW(hwnd, GWL_STYLE, new_style);
                let _ = SetWindowPos(
                    hwnd,
                    None,
                    0,
                    0,
                    0,
                    0,
                    SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
                );
            }
        }
    }

    eprintln!(
        "[leopardwm] WS_MAXIMIZEBOX panic recovery complete ({} windows processed)",
        window_ids.len()
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_border_color_unsupported_hresult_mapping() {
        assert!(is_border_color_unsupported_hresult(windows::core::HRESULT(
            0x8007_0057u32 as i32
        )));
        assert!(is_border_color_unsupported_hresult(windows::core::HRESULT(
            0x8000_4001u32 as i32
        )));
        assert!(!is_border_color_unsupported_hresult(
            windows::core::HRESULT(0x8000_4005u32 as i32)
        ));
    }

    #[test]
    fn test_set_window_border_color_zero_fails() {
        let result = set_window_border_color(0, 0x4285F4);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), Win32Error::WindowNotFound(0)));
    }

    #[test]
    fn test_set_window_border_color_invalid_hwnd_fails() {
        let result = set_window_border_color(u64::MAX, 0x4285F4);
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            Win32Error::WindowNotFound(u64::MAX)
        ));
    }

    #[test]
    fn test_reset_window_border_color_zero_fails() {
        let result = reset_window_border_color(0);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), Win32Error::WindowNotFound(0)));
    }

    #[test]
    fn test_remove_maximizebox_zero_fails() {
        let result = remove_maximizebox(0);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), Win32Error::WindowNotFound(0)));
    }

    #[test]
    fn test_remove_maximizebox_invalid_hwnd_fails() {
        let result = remove_maximizebox(u64::MAX);
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            Win32Error::WindowNotFound(u64::MAX)
        ));
    }

    #[test]
    fn test_restore_maximizebox_zero_fails() {
        let result = restore_maximizebox(0);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), Win32Error::WindowNotFound(0)));
    }

    #[test]
    fn test_restore_maximizebox_invalid_hwnd_fails() {
        let result = restore_maximizebox(u64::MAX);
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            Win32Error::WindowNotFound(u64::MAX)
        ));
    }

    #[test]
    fn test_restore_maximizebox_all_empty_is_noop() {
        restore_maximizebox_all(&[]);
    }

    #[test]
    fn test_restore_maximizebox_panic_recovery_no_panic() {
        let _guard = lock_snap_tracking_fixture();
        // Should not panic even with empty tracking set
        restore_maximizebox_panic_recovery();
    }

    const WS_MAXIMIZEBOX_BIT: i32 = 0x0001_0000;

    static SNAP_TRACKING_FIXTURE_LOCK: Mutex<()> = Mutex::new(());

    fn lock_snap_tracking_fixture() -> std::sync::MutexGuard<'static, ()> {
        SNAP_TRACKING_FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    struct HiddenFramedFixture {
        hwnd: Option<HWND>,
    }

    impl HiddenFramedFixture {
        fn create() -> Self {
            use windows::core::w;
            use windows::Win32::UI::WindowsAndMessaging::{
                CreateWindowExW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_OVERLAPPEDWINDOW,
            };

            let hwnd = unsafe {
                CreateWindowExW(
                    WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                    w!("STATIC"),
                    None,
                    WS_OVERLAPPEDWINDOW,
                    48,
                    48,
                    416,
                    312,
                    None,
                    None,
                    None,
                    None,
                )
            }
            .expect("failed to create hidden framed STATIC fixture");
            Self { hwnd: Some(hwnd) }
        }

        fn hwnd(&self) -> HWND {
            self.hwnd.expect("fixture already destroyed")
        }

        fn window_id(&self) -> WindowId {
            self.hwnd().0 as usize as u64
        }
    }

    impl Drop for HiddenFramedFixture {
        fn drop(&mut self) {
            if let Some(hwnd) = self.hwnd.take() {
                let _ = restore_maximizebox(hwnd.0 as usize as u64);
                let _ = unsafe { windows::Win32::UI::WindowsAndMessaging::DestroyWindow(hwnd) };
            }
        }
    }

    #[derive(Default)]
    struct RecordedGeometryEvent {
        event: Option<String>,
        operation: Option<String>,
        stage: Option<String>,
        correlation_id: Option<u64>,
    }

    struct GeometryEventVisitor<'a>(&'a mut RecordedGeometryEvent);

    impl tracing::field::Visit for GeometryEventVisitor<'_> {
        fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
            match field.name() {
                "operation" if self.0.operation.is_none() => {
                    self.0.operation = Some(format!("{value:?}"));
                }
                "stage" if self.0.stage.is_none() => {
                    self.0.stage = Some(format!("{value:?}"));
                }
                _ => {}
            }
        }

        fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
            match field.name() {
                "event" => self.0.event = Some(value.to_string()),
                "operation" => self.0.operation = Some(value.to_string()),
                "stage" => self.0.stage = Some(value.to_string()),
                _ => {}
            }
        }

        fn record_u64(&mut self, field: &tracing::field::Field, value: u64) {
            if field.name() == "correlation_id" {
                self.0.correlation_id = Some(value);
            }
        }
    }

    struct GeometryEventSubscriber {
        events: std::sync::Arc<Mutex<Vec<RecordedGeometryEvent>>>,
    }

    impl tracing::Subscriber for GeometryEventSubscriber {
        fn enabled(&self, metadata: &tracing::Metadata<'_>) -> bool {
            metadata.target() == MAXIMIZEBOX_GEOMETRY_TARGET
        }

        fn max_level_hint(&self) -> Option<tracing::level_filters::LevelFilter> {
            Some(tracing::level_filters::LevelFilter::DEBUG)
        }

        fn new_span(&self, _span: &tracing::span::Attributes<'_>) -> tracing::span::Id {
            tracing::span::Id::from_u64(1)
        }

        fn record(&self, _span: &tracing::span::Id, _values: &tracing::span::Record<'_>) {}

        fn record_follows_from(&self, _span: &tracing::span::Id, _follows: &tracing::span::Id) {}

        fn event(&self, event: &tracing::Event<'_>) {
            let mut recorded = RecordedGeometryEvent::default();
            event.record(&mut GeometryEventVisitor(&mut recorded));
            self.events.lock().unwrap().push(recorded);
        }

        fn enter(&self, _span: &tracing::span::Id) {}

        fn exit(&self, _span: &tracing::span::Id) {}
    }

    #[test]
    fn test_remove_restore_maximizebox_diagnostics_and_semantics() {
        use windows::Win32::UI::WindowsAndMessaging::IsWindowVisible;

        let _guard = lock_snap_tracking_fixture();
        let fixture = HiddenFramedFixture::create();
        assert!(!unsafe { IsWindowVisible(fixture.hwnd()) }.as_bool());

        let before = capture_maximizebox_geometry(fixture.hwnd());
        let style = before.style.expect("live style should be readable");
        assert_ne!(style & WS_MAXIMIZEBOX_BIT, 0);
        let window_rect = before
            .window_rect
            .expect("live outer rect should be readable");
        assert!(window_rect[2] > window_rect[0]);
        assert!(window_rect[3] > window_rect[1]);
        let client_rect = before
            .client_rect
            .expect("live client rect should be readable");
        assert!(client_rect[2] > client_rect[0]);
        assert!(client_rect[3] > client_rect[1]);

        let events = std::sync::Arc::new(Mutex::new(Vec::new()));
        let subscriber = GeometryEventSubscriber {
            events: events.clone(),
        };
        let window_id = fixture.window_id();
        tracing::subscriber::with_default(subscriber, || {
            assert!(remove_maximizebox(window_id).unwrap());
            assert!(restore_maximizebox(window_id).unwrap());
        });

        let recorded = events.lock().unwrap();
        assert_eq!(recorded.len(), 6);
        assert!(recorded
            .iter()
            .all(|event| event.event.as_deref() == Some(MAXIMIZEBOX_GEOMETRY_EVENT)));
        assert_eq!(
            recorded
                .iter()
                .map(|event| event.stage.as_deref())
                .collect::<Vec<_>>(),
            [
                Some("before_style"),
                Some("after_style"),
                Some("after_frame"),
                Some("before_style"),
                Some("after_style"),
                Some("after_frame"),
            ]
        );
        assert!(recorded[..3]
            .iter()
            .all(|event| event.operation.as_deref() == Some("remove")));
        assert!(recorded[3..]
            .iter()
            .all(|event| event.operation.as_deref() == Some("restore")));
        let remove_id = recorded[0].correlation_id.expect("remove correlation id");
        let restore_id = recorded[3].correlation_id.expect("restore correlation id");
        assert!(recorded[..3]
            .iter()
            .all(|event| event.correlation_id == Some(remove_id)));
        assert!(recorded[3..]
            .iter()
            .all(|event| event.correlation_id == Some(restore_id)));
        drop(recorded);

        let after_restore = capture_maximizebox_geometry(fixture.hwnd());
        assert_eq!(
            after_restore.style.expect("restored style") & WS_MAXIMIZEBOX_BIT,
            WS_MAXIMIZEBOX_BIT
        );
        assert_eq!(after_restore.window_rect, Ok(window_rect));

        assert!(remove_maximizebox(window_id).unwrap());
        let after_remove = capture_maximizebox_geometry(fixture.hwnd());
        assert_eq!(
            after_remove.style.expect("removed style") & WS_MAXIMIZEBOX_BIT,
            0
        );
        assert_eq!(after_remove.window_rect, Ok(window_rect));
        assert!(!remove_maximizebox(window_id).unwrap());
        assert_eq!(
            capture_maximizebox_geometry(fixture.hwnd()).window_rect,
            Ok(window_rect)
        );

        assert!(restore_maximizebox(window_id).unwrap());
        assert!(!restore_maximizebox(window_id).unwrap());
        assert_eq!(
            capture_maximizebox_geometry(fixture.hwnd()).window_rect,
            Ok(window_rect)
        );
    }

    #[test]
    fn test_maximizebox_geometry_capture_zero_ex_style_is_ok() {
        use windows::core::w;
        use windows::Win32::UI::WindowsAndMessaging::{
            CreateWindowExW, DestroyWindow, IsWindowVisible, WINDOW_EX_STYLE, WS_POPUP,
        };

        struct HiddenPopup(HWND);
        impl Drop for HiddenPopup {
            fn drop(&mut self) {
                let _ = unsafe { DestroyWindow(self.0) };
            }
        }

        let hwnd = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("STATIC"),
                None,
                WS_POPUP,
                48,
                48,
                64,
                64,
                None,
                None,
                None,
                None,
            )
        }
        .expect("failed to create hidden popup STATIC fixture");
        let _fixture = HiddenPopup(hwnd);
        assert!(!unsafe { IsWindowVisible(hwnd) }.as_bool());
        assert_eq!(capture_maximizebox_geometry(hwnd).ex_style, Ok(0));
    }

    #[test]
    fn test_maximizebox_geometry_capture_invalid_hwnd_is_err() {
        use windows::Win32::Foundation::ERROR_INVALID_WINDOW_HANDLE;

        let dead = capture_maximizebox_geometry(HWND::default());
        let invalid_hwnd = windows::core::HRESULT::from_win32(ERROR_INVALID_WINDOW_HANDLE.0).0;
        assert_eq!(dead.style, Err(invalid_hwnd));
        assert_eq!(dead.ex_style, Err(invalid_hwnd));
        assert!(dead.window_rect.is_err());
        assert!(dead.client_rect.is_err());
        assert!(dead.dwm_frame.is_err());
        assert!(dead.nc_rendering.is_err());
    }
}
