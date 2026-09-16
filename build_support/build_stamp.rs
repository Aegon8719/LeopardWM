// Shared build-script helper: emit build-stamp environment variables.
//
// Included by each binary crate's `build.rs` via `include!` so the timestamp
// formatting lives in exactly one place. It sets:
//
// - `LEOPARDWM_BUILD_TIMESTAMP` — UTC ISO-8601, e.g. `2026-06-16T14:30:05Z`
// - `LEOPARDWM_BUILD_EPOCH` — Unix seconds
// - `LEOPARDWM_BUILD_NUMBER` — days since 2020-01-01, which fits the 16-bit
//   field Windows VERSIONINFO requires for the fourth version component
//
// The same values are written to the Windows file properties (FileVersion,
// ProductVersion, Comments) by the calling build script.

use std::time::{SystemTime, UNIX_EPOCH};

/// Days between 1970-01-01 and 2020-01-01.
const EPOCH_2020_DAYS: u64 = 18_262;

/// Build stamp captured once per build-script run.
pub struct BuildStamp {
    /// UTC ISO-8601 timestamp, e.g. `2026-06-16T14:30:05Z`.
    pub timestamp: String,
    /// Unix seconds at build time.
    pub epoch: u64,
    /// Days since 2020-01-01 (fits a 16-bit version component).
    pub number: u64,
}

/// Convert Unix seconds to civil UTC `(year, month, day, hour, minute, second)`.
///
/// Howard Hinnant's `civil_from_days` algorithm, shifted from days to seconds.
fn civil_from_unix(secs: u64) -> (u64, u32, u32, u32, u32, u32) {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = if month <= 2 { yoe + era * 400 + 1 } else { yoe + era * 400 };
    (
        year as u64,
        month,
        day,
        (rem / 3_600) as u32,
        (rem % 3_600 / 60) as u32,
        (rem % 60) as u32,
    )
}

/// Capture the current build time, emit `cargo:rustc-env` lines, and return
/// the values for the caller's VERSIONINFO resource.
///
/// `LEOPARDWM_BUILD_STAMP_EPOCH` (Unix seconds) overrides "now" when set, so
/// `tools/build_timestamped.ps1` can make the embedded stamp and the output
/// folder name exactly match.
pub fn emit_build_stamp() -> BuildStamp {
    let epoch = std::env::var("LEOPARDWM_BUILD_STAMP_EPOCH")
        .ok()
        .and_then(|raw| raw.trim().parse::<u64>().ok())
        .or_else(|| {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .ok()
                .map(|duration| duration.as_secs())
        })
        .unwrap_or(0);
    let (year, month, day, hour, minute, second) = civil_from_unix(epoch);
    let timestamp = format!(
        "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z"
    );
    let number = epoch / 86_400 - EPOCH_2020_DAYS;
    println!("cargo:rustc-env=LEOPARDWM_BUILD_TIMESTAMP={timestamp}");
    println!("cargo:rustc-env=LEOPARDWM_BUILD_EPOCH={epoch}");
    println!("cargo:rustc-env=LEOPARDWM_BUILD_NUMBER={number}");
    BuildStamp {
        timestamp,
        epoch,
        number,
    }
}
