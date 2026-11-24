//! Support for `MILLENNIUM_EXTRA_INSERT_LIBRARIES`, used by the macOS launcher and bootstrap.
//!
//! `MILLENNIUM_EXTRA_INSERT_LIBRARIES` is a `:`-separated list of absolute dylib paths that Millennium appends to
//! `DYLD_INSERT_LIBRARIES` for Steam (on every launch or re-exec) and for its Steam Helper processes, after
//! Millennium's own libraries. It is meant for running another `DYLD_INSERT_LIBRARIES`-based Steam mod next to
//! Millennium.
//!
//! Why a dedicated variable instead of exporting `DYLD_INSERT_LIBRARIES`: a mod that removes
//! `DYLD_INSERT_LIBRARIES` from its own environment on load (to keep it out of child processes) leaves nothing for
//! the launcher to merge, and the `execve` interposer rebuilds the variable from the environment it is handed, so
//! the mod's library silently drops out when Steam re-executes itself. A variable without the `DYLD_` prefix is not
//! touched by dyld or by such mods, so it survives the whole exec chain.
//!
//! Entries that are not readable files are ignored, because dyld terminates the process when an inserted dylib
//! cannot be loaded. Entries must be loadable by the architecture of the process they are inserted into.

use std::cell::RefCell;
use std::ffi::{c_char, CStr, CString, OsStr, OsString};
use std::io::Write;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::panic::{self, AssertUnwindSafe};
use std::path::Path;
use std::{fs, io};

pub const EXTRA_INSERT_LIBRARIES_ENV: &str = "MILLENNIUM_EXTRA_INSERT_LIBRARIES";

/// Splits a `:`-separated list, dropping empty entries.
pub fn split_library_list(list: &[u8]) -> Vec<&[u8]> {
    list.split(|byte| *byte == b':')
        .filter(|entry| !entry.is_empty())
        .collect()
}

fn as_path(entry: &[u8]) -> &Path {
    Path::new(OsStr::from_bytes(entry))
}

/// Resolves symlinks the way the rest of the bootstrap does (`realpath`), so entries can be compared.
/// Falls back to the input when the path cannot be resolved.
fn normalize(entry: &[u8]) -> Vec<u8> {
    match fs::canonicalize(as_path(entry)) {
        Ok(resolved) => resolved.into_os_string().into_vec(),
        Err(_) => entry.to_vec(),
    }
}

fn is_readable_file(entry: &[u8]) -> bool {
    let path = as_path(entry);
    path.is_file() && fs::File::open(path).is_ok()
}

/// Returns the readable entries of `configured`, calling `on_unreadable` for each one that was skipped.
pub fn readable_libraries(configured: &[u8], mut on_unreadable: impl FnMut(&[u8])) -> Vec<Vec<u8>> {
    let mut libraries = Vec::new();
    for entry in split_library_list(configured) {
        if is_readable_file(entry) {
            libraries.push(entry.to_vec());
        } else {
            on_unreadable(entry);
        }
    }
    libraries
}

/// Appends `extras` to a `:`-separated `DYLD_INSERT_LIBRARIES` value. Libraries that are already present (compared
/// after resolving symlinks) are not added twice, and the existing entries are left exactly as they were.
pub fn append_libraries(dyld_insert_libraries: &[u8], extras: &[Vec<u8>]) -> Vec<u8> {
    let mut present: Vec<Vec<u8>> = split_library_list(dyld_insert_libraries)
        .into_iter()
        .map(normalize)
        .collect();
    let mut merged = dyld_insert_libraries.to_vec();

    for library in extras {
        let normalized = normalize(library);
        if present.contains(&normalized) {
            continue;
        }

        if !merged.is_empty() && merged.last() != Some(&b':') {
            merged.push(b':');
        }
        merged.extend_from_slice(&normalized);
        present.push(normalized);
    }

    merged
}

thread_local! {
    // Backs the pointer returned by `millennium_extra_inject_append`.
    static RESULT: RefCell<CString> = RefCell::new(CString::default());
}

/// Returns `dyld_insert_libraries` with the libraries from `MILLENNIUM_EXTRA_INSERT_LIBRARIES` appended.
/// With `warn_on_unreadable`, entries that are skipped are reported on stderr.
///
/// The result is never null and is owned by this library: it stays valid until the next call on the same
/// thread, so copy it if it has to be kept. If anything goes wrong the input is returned unchanged.
///
/// # Safety
///
/// `dyld_insert_libraries` must be null or point to a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn millennium_extra_inject_append(
    dyld_insert_libraries: *const c_char,
    warn_on_unreadable: bool,
) -> *const c_char {
    let base = if dyld_insert_libraries.is_null() {
        CString::default()
    } else {
        CStr::from_ptr(dyld_insert_libraries).to_owned()
    };

    let merged = panic::catch_unwind(AssertUnwindSafe(|| {
        let configured = std::env::var_os(EXTRA_INSERT_LIBRARIES_ENV)
            .map(OsString::into_vec)
            .unwrap_or_default();

        let extras = readable_libraries(&configured, |entry| {
            if warn_on_unreadable {
                report_unreadable(entry);
            }
        });

        append_libraries(base.to_bytes(), &extras)
    }));

    let result = merged
        .ok()
        .and_then(|value| CString::new(value).ok())
        .unwrap_or(base);

    RESULT.with(|slot| {
        *slot.borrow_mut() = result;
        slot.borrow().as_ptr()
    })
}

fn report_unreadable(entry: &[u8]) {
    let _ = writeln!(
        io::stderr(),
        "[Millennium] Ignoring unreadable library in {}: {}",
        EXTRA_INSERT_LIBRARIES_ENV,
        String::from_utf8_lossy(entry)
    );
}

/// Adds the libraries from `MILLENNIUM_EXTRA_INSERT_LIBRARIES` to this process's `DYLD_INSERT_LIBRARIES`.
///
/// For the launcher: it passes its environment on to Steam and merges its own library into whatever it finds in
/// `DYLD_INSERT_LIBRARIES`, so the extra libraries ride along. Entries that are skipped are reported on stderr.
#[no_mangle]
pub extern "C" fn millennium_extra_inject_prepare_environment() {
    let _ = panic::catch_unwind(|| {
        let configured = std::env::var_os(EXTRA_INSERT_LIBRARIES_ENV)
            .map(OsString::into_vec)
            .unwrap_or_default();
        let extras = readable_libraries(&configured, report_unreadable);
        if extras.is_empty() {
            return;
        }

        let current = std::env::var_os("DYLD_INSERT_LIBRARIES")
            .map(OsString::into_vec)
            .unwrap_or_default();
        let merged = append_libraries(&current, &extras);
        if merged != current {
            std::env::set_var("DYLD_INSERT_LIBRARIES", OsString::from_vec(merged));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;

    // A scratch directory holding a.dylib, b.dylib and link.dylib (a symlink to a.dylib).
    struct Scratch {
        root: PathBuf,
    }

    impl Scratch {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "millennium-extra-inject-{}-{}",
                std::process::id(),
                tag
            ));
            fs::create_dir_all(&dir).unwrap();

            // Resolve the directory so expectations match canonicalize() (/tmp is a symlink on macOS).
            let root = fs::canonicalize(&dir).unwrap();
            fs::write(root.join("a.dylib"), "a").unwrap();
            fs::write(root.join("b.dylib"), "b").unwrap();
            symlink(root.join("a.dylib"), root.join("link.dylib")).unwrap();
            Scratch { root }
        }

        fn path(&self, name: &str) -> String {
            self.root.join(name).to_str().unwrap().to_owned()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn merged(base: &str, configured: &str) -> String {
        let extras = readable_libraries(configured.as_bytes(), |_| {});
        String::from_utf8(append_libraries(base.as_bytes(), &extras)).unwrap()
    }

    #[test]
    fn appends_configured_libraries_after_the_existing_entries() {
        let libs = Scratch::new("append");
        let configured = format!("{}:{}", libs.path("a.dylib"), libs.path("b.dylib"));

        assert_eq!(
            merged("/opt/first.dylib", &configured),
            format!("/opt/first.dylib:{configured}")
        );
    }

    #[test]
    fn leaves_the_value_untouched_when_nothing_is_configured() {
        assert_eq!(
            merged("/opt/a.dylib:/opt/b.dylib", ""),
            "/opt/a.dylib:/opt/b.dylib"
        );
        assert_eq!(merged("", ""), "");
    }

    #[test]
    fn does_not_emit_a_leading_separator_for_an_empty_value() {
        let libs = Scratch::new("empty");
        let configured = format!("{}:{}", libs.path("a.dylib"), libs.path("b.dylib"));

        assert_eq!(merged("", &configured), configured);
    }

    #[test]
    fn skips_libraries_that_are_already_present_including_through_symlinks() {
        let libs = Scratch::new("present");
        let configured = format!("{}:{}", libs.path("a.dylib"), libs.path("b.dylib"));

        let base = format!("/opt/first.dylib:{}", libs.path("link.dylib"));
        assert_eq!(
            merged(&base, &configured),
            format!("{base}:{}", libs.path("b.dylib"))
        );
    }

    #[test]
    fn drops_unreadable_and_empty_entries_and_collapses_duplicates() {
        let libs = Scratch::new("filter");
        let configured = format!(
            ":{}:{}::{}:",
            libs.path("missing.dylib"),
            libs.path("a.dylib"),
            libs.path("link.dylib")
        );

        assert_eq!(
            merged("/opt/first.dylib", &configured),
            format!("/opt/first.dylib:{}", libs.path("a.dylib"))
        );
    }

    #[test]
    fn does_not_double_a_trailing_separator() {
        let libs = Scratch::new("trailing");

        assert_eq!(
            merged("/opt/first.dylib:", &libs.path("b.dylib")),
            format!("/opt/first.dylib:{}", libs.path("b.dylib"))
        );
    }

    #[test]
    fn reports_every_unreadable_entry() {
        let libs = Scratch::new("report");
        let configured = format!(
            "{}:{}:{}",
            libs.path("missing.dylib"),
            libs.path("a.dylib"),
            libs.root.display()
        );

        let mut skipped = Vec::new();
        let readable = readable_libraries(configured.as_bytes(), |entry| {
            skipped.push(String::from_utf8_lossy(entry).into_owned())
        });

        assert_eq!(readable, vec![libs.path("a.dylib").into_bytes()]);
        assert_eq!(
            skipped,
            vec![libs.path("missing.dylib"), libs.root.display().to_string()]
        );
    }

    // The only test that touches the process environment, so it cannot race with the others.
    #[test]
    fn ffi_reads_the_environment_variable() {
        let libs = Scratch::new("ffi");
        let call = |base: Option<&str>| {
            let base = base.map(|value| CString::new(value).unwrap());
            let raw = unsafe {
                millennium_extra_inject_append(
                    base.as_ref()
                        .map_or(std::ptr::null(), |value| value.as_ptr()),
                    false,
                )
            };
            assert!(!raw.is_null());

            unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned()
        };

        std::env::remove_var(EXTRA_INSERT_LIBRARIES_ENV);
        assert_eq!(call(Some("/opt/first.dylib")), "/opt/first.dylib");
        assert_eq!(call(None), "");

        let configured = format!("{}:{}", libs.path("a.dylib"), libs.path("b.dylib"));
        std::env::set_var(EXTRA_INSERT_LIBRARIES_ENV, &configured);
        assert_eq!(
            call(Some("/opt/first.dylib")),
            format!("/opt/first.dylib:{configured}")
        );
        assert_eq!(call(None), configured);

        // The launcher side: the extras are merged into whatever DYLD_INSERT_LIBRARIES already holds.
        std::env::set_var("DYLD_INSERT_LIBRARIES", "/opt/first.dylib");
        millennium_extra_inject_prepare_environment();
        assert_eq!(
            std::env::var("DYLD_INSERT_LIBRARIES").unwrap(),
            format!("/opt/first.dylib:{configured}")
        );

        millennium_extra_inject_prepare_environment();
        assert_eq!(
            std::env::var("DYLD_INSERT_LIBRARIES").unwrap(),
            format!("/opt/first.dylib:{configured}")
        );

        std::env::remove_var("DYLD_INSERT_LIBRARIES");
        millennium_extra_inject_prepare_environment();
        assert_eq!(std::env::var("DYLD_INSERT_LIBRARIES").unwrap(), configured);

        std::env::remove_var(EXTRA_INSERT_LIBRARIES_ENV);
        std::env::set_var("DYLD_INSERT_LIBRARIES", "/opt/untouched.dylib");
        millennium_extra_inject_prepare_environment();
        assert_eq!(
            std::env::var("DYLD_INSERT_LIBRARIES").unwrap(),
            "/opt/untouched.dylib"
        );
        std::env::remove_var("DYLD_INSERT_LIBRARIES");
    }
}
