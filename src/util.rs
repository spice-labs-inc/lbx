//! Small host helpers: output that never panics on a closed pipe, PATH
//! lookup, identity, random bytes, path containment.

use std::ffi::CStr;
use std::io::Write;
use std::path::{Component, Path, PathBuf};

/// Print to stdout, ignoring a closed pipe (a caller that stopped reading
/// must not turn into a panic or a write error).
pub fn out(line: &str) {
    let stdout = std::io::stdout();
    let mut h = stdout.lock();
    let _ = h.write_all(line.as_bytes());
    let _ = h.write_all(b"\n");
    let _ = h.flush();
}

/// Print to stderr, ignoring errors.
pub fn err(line: &str) {
    let stderr = std::io::stderr();
    let mut h = stderr.lock();
    let _ = h.write_all(line.as_bytes());
    let _ = h.write_all(b"\n");
    let _ = h.flush();
}

/// `command -v name`: the executable on PATH, if any.
pub fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    match std::fs::metadata(p) {
        Ok(m) => m.is_file() && m.permissions().mode() & 0o111 != 0,
        Err(_) => false,
    }
}

/// `id -u`: the command first (the suites stub it), then the syscall.
pub fn host_uid() -> u32 {
    id_cmd("-u").unwrap_or_else(|| {
        // SAFETY: getuid has no preconditions and cannot fail.
        unsafe { libc::getuid() }
    })
}

fn id_cmd(flag: &str) -> Option<u32> {
    let o = std::process::Command::new("id").arg(flag).output().ok()?;
    if !o.status.success() {
        return None;
    }
    String::from_utf8_lossy(&o.stdout).trim().parse().ok()
}

pub fn host_gid() -> u32 {
    id_cmd("-g").unwrap_or_else(|| {
        // SAFETY: getgid has no preconditions and cannot fail.
        unsafe { libc::getgid() }
    })
}

/// `whoami`: the name of the effective user, falling back to the uid.
pub fn whoami() -> String {
    // SAFETY: geteuid cannot fail; getpwuid returns either null or a
    // pointer to a static passwd record whose pw_name is a C string.
    unsafe {
        let uid = libc::geteuid();
        let pw = libc::getpwuid(uid);
        if pw.is_null() {
            return uid.to_string();
        }
        let name = (*pw).pw_name;
        if name.is_null() {
            return uid.to_string();
        }
        CStr::from_ptr(name).to_string_lossy().into_owned()
    }
}

pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// `realpath -m`: resolve what exists, normalize the rest lexically.
pub fn realpath_m(p: &Path) -> PathBuf {
    let abs = if p.is_absolute() {
        p.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("/"))
            .join(p)
    };
    // Walk down from the root, canonicalizing the longest existing prefix.
    let mut resolved = PathBuf::from("/");
    let mut rest: Vec<std::ffi::OsString> = Vec::new();
    let comps: Vec<Component> = abs.components().collect();
    let mut i = 0;
    let mut stop = false;
    for c in &comps {
        i += 1;
        match c {
            Component::RootDir => {}
            Component::CurDir => {}
            Component::ParentDir => {
                if stop {
                    rest.push("..".into());
                } else {
                    resolved.pop();
                }
            }
            Component::Normal(n) => {
                if stop {
                    rest.push(n.to_os_string());
                } else {
                    let next = resolved.join(n);
                    match std::fs::canonicalize(&next) {
                        Ok(c) => resolved = c,
                        Err(_) => {
                            stop = true;
                            rest.push(n.to_os_string());
                        }
                    }
                }
            }
            Component::Prefix(_) => {}
        }
    }
    let _ = i;
    for r in rest {
        if r == ".." {
            resolved.pop();
        } else {
            resolved.push(r);
        }
    }
    resolved
}

/// `realpath -e`: every component must exist.
pub fn realpath_e(p: &Path) -> Option<PathBuf> {
    std::fs::canonicalize(p).ok()
}

/// path_within <path> <dir>: the path is the directory or inside it.
pub fn path_within(path: &str, dir: &str) -> bool {
    path == dir || path.starts_with(&format!("{dir}/"))
}

pub fn path_str(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

/// 16 random bytes from /dev/urandom as 32 hex characters.
pub fn random_hex16() -> Option<String> {
    use std::io::Read;
    let mut f = std::fs::File::open("/dev/urandom").ok()?;
    let mut buf = [0u8; 16];
    f.read_exact(&mut buf).ok()?;
    Some(buf.iter().map(|b| format!("{b:02x}")).collect())
}

/// Sleep in small steps so a pending signal is seen promptly.
pub fn sleep_secs_checking(secs: f64, stop: &dyn Fn() -> bool) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs_f64(secs);
    while std::time::Instant::now() < deadline {
        if stop() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

/// The launcher's own environment: `LBX_<key>` is the name; `LLMBOX_<key>`,
/// the spelling the earlier launcher used, is still read so existing
/// setups keep working, and `LBX_<key>` wins when both are set. An empty
/// value counts as unset. Every read of a launcher variable goes through
/// here.
pub fn lbx_env(key: &str) -> Option<String> {
    for prefix in ["LBX_", "LLMBOX_"] {
        if let Ok(v) = std::env::var(format!("{prefix}{key}"))
            && !v.is_empty()
        {
            return Some(v);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    // Variable names unique to this test: the process environment is shared
    // between test threads.
    #[test]
    fn lbx_env_reads_both_spellings_and_prefers_lbx() {
        // SAFETY: single-threaded access to names no other test touches.
        unsafe {
            std::env::remove_var("LBX_UTILTEST_A");
            std::env::remove_var("LLMBOX_UTILTEST_A");
        }
        assert_eq!(lbx_env("UTILTEST_A"), None);
        unsafe { std::env::set_var("LLMBOX_UTILTEST_A", "old") };
        assert_eq!(lbx_env("UTILTEST_A").as_deref(), Some("old"));
        unsafe { std::env::set_var("LBX_UTILTEST_A", "new") };
        assert_eq!(lbx_env("UTILTEST_A").as_deref(), Some("new"));
        unsafe { std::env::set_var("LBX_UTILTEST_A", "") };
        assert_eq!(
            lbx_env("UTILTEST_A").as_deref(),
            Some("old"),
            "empty counts as unset"
        );
        unsafe {
            std::env::remove_var("LBX_UTILTEST_A");
            std::env::remove_var("LLMBOX_UTILTEST_A");
        }
        assert_eq!(lbx_env("UTILTEST_A"), None);
    }
}
