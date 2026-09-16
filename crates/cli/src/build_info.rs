//! Compile-time build identity stamped by `build.rs`.

/// Marketing version from `Cargo.toml`, e.g. `0.2.9`.
pub(crate) const VERSION: &str = env!("CARGO_PKG_VERSION");

/// UTC time of the build that produced this binary, e.g. `2026-06-16T14:30:05Z`.
/// (Read by tests and future diagnostics.)
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) const BUILD_TIMESTAMP: &str = env!("LEOPARDWM_BUILD_TIMESTAMP");

/// `VERSION` plus the build timestamp, printed by `--version` and
/// `lwm collect-logs`.
pub(crate) const VERSION_LONG: &str = concat!(
    env!("CARGO_PKG_VERSION"),
    " (built ",
    env!("LEOPARDWM_BUILD_TIMESTAMP"),
    ")"
);
