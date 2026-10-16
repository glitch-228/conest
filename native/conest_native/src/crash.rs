//! Native crash reports. A Rust panic (which aborts when it reaches an
//! `extern "C"` export) and, on Windows, an exception nothing handled are
//! written to a file the app reads on its next start
//! (lib/src/crash_catcher.dart), so a native crash is never silent.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;

static REPORT_PATH: OnceLock<PathBuf> = OnceLock::new();

/// The most of one report kept: a backtrace can be long.
const MAX_REPORT_CHARS: usize = 8000;

/// Starts writing reports to `path`. Later calls keep the first path.
pub fn init(path: PathBuf) -> bool {
    if REPORT_PATH.set(path).is_err() {
        return true;
    }
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let thread = std::thread::current();
        let name = thread.name().unwrap_or("unnamed");
        write_report(&format!(
            "Rust panic on thread '{name}': {info}\n{}",
            std::backtrace::Backtrace::force_capture()
        ));
        previous(info);
    }));
    #[cfg(target_os = "windows")]
    windows::install();
    true
}

fn write_report(text: &str) {
    let Some(path) = REPORT_PATH.get() else {
        return;
    };
    let text = if text.chars().count() > MAX_REPORT_CHARS {
        let cut: String = text.chars().take(MAX_REPORT_CHARS).collect();
        format!("{cut}…")
    } else {
        text.to_owned()
    };
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{text}\n");
        let _ = file.flush();
    }
}

#[cfg(target_os = "windows")]
mod windows {
    use windows_sys::Win32::System::Diagnostics::Debug::{
        EXCEPTION_POINTERS, SetUnhandledExceptionFilter,
    };

    /// Lets the search go on (Windows Error Reporting, then the end).
    const EXCEPTION_CONTINUE_SEARCH: i32 = 0;

    pub fn install() {
        // SAFETY: registers a process-wide filter; the function stays valid
        // for the life of the process.
        unsafe {
            SetUnhandledExceptionFilter(Some(filter));
        }
    }

    unsafe extern "system" fn filter(info: *const EXCEPTION_POINTERS) -> i32 {
        // SAFETY: Windows passes valid exception pointers, or null.
        let (code, address) = unsafe {
            match info.as_ref().and_then(|info| info.ExceptionRecord.as_ref()) {
                Some(record) => (record.ExceptionCode, record.ExceptionAddress as usize),
                None => (0, 0),
            }
        };
        super::write_report(&format!(
            "Windows exception 0x{:08X} at 0x{address:X}",
            code as u32
        ));
        EXCEPTION_CONTINUE_SEARCH
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panic_is_written_down_before_it_unwinds() {
        let path =
            std::env::temp_dir().join(format!("conest-crash-test-{}.txt", std::process::id()));
        let _ = std::fs::remove_file(&path);
        assert!(init(path.clone()));
        let result = std::panic::catch_unwind(|| panic!("boom for the report"));
        assert!(result.is_err());
        let written = std::fs::read_to_string(&path).unwrap();
        assert!(written.contains("boom for the report"), "{written}");
        assert!(written.contains("Rust panic on thread"), "{written}");
        let _ = std::fs::remove_file(&path);
    }
}
