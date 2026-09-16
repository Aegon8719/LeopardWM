//! Compile-time build identity stamped by `build.rs`.
//!
//! The watchdog only logs the long form; the split constants are kept for
//! parity with the daemon/CLI crates and future diagnostics.

/// Marketing version from `Cargo.toml`, e.g. `0.2.9`.
#[allow(dead_code)]
pub(crate) const VERSION: &str = env!("CARGO_PKG_VERSION");

/// UTC time of the build that produced this binary, e.g. `2026-06-16T14:30:05Z`.
#[allow(dead_code)]
pub(crate) const BUILD_TIMESTAMP: &str = env!("LEOPARDWM_BUILD_TIMESTAMP");

/// `VERSION` plus the build timestamp, logged at watchdog startup.
pub(crate) const VERSION_LONG: &str = concat!(
    env!("CARGO_PKG_VERSION"),
    " (built ",
    env!("LEOPARDWM_BUILD_TIMESTAMP"),
    ")"
);
