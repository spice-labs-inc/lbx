//! The config file (`$LBX_CONFIG`, default `~/.config/llm_in_a_box/config`):
//! `key=value` lines, `#` comments, last wins, values validated against
//! `[A-Za-z0-9._:/@+-]`, file trust rules (regular, not a link, owned by the
//! invoking user, not group/world writable).

use std::collections::BTreeMap;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

pub const IMAGE_SYSBOX: &str = "llm-in-a-box:sysbox";
pub const IMAGE_DOCKER: &str = "llm-in-a-box:docker";
pub const IMAGE_VM: &str = "llm-in-a-box:vm";
pub const IMAGE_LEGACY: &str = "llm-in-a-box:latest";
pub const IMAGE_SYSBOX_SLIM: &str = "llm-in-a-box:sysbox-slim";
pub const IMAGE_DOCKER_SLIM: &str = "llm-in-a-box:docker-slim";
pub const IMAGE_VM_SLIM: &str = "llm-in-a-box:vm-slim";

/// The host variables forwarded to an interactive box when `env.forward` is
/// not configured. Names only — a name that is unset on the host is skipped.
///
/// Deliberately one name: `GH_TOKEN`, the historical default. Model-provider
/// keys are opt-in (`env.forward=GH_TOKEN,ANTHROPIC_API_KEY,...` or `--env`),
/// because silently carrying every credential into a box started for an
/// unrelated task is a wider default than this project's name-based posture.
pub const DEFAULT_ENV_FORWARD: &str = "GH_TOKEN";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigState {
    Usable,
    Unusable,
    Missing,
}

/// Everything the launcher resolves from env + config + defaults.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub state: ConfigState,
    /// The diagnostic for the unusable case (names the path).
    pub error: String,
    pub warnings: Vec<String>,
    pub path: PathBuf,
    pub image_sysbox: String,
    pub image_docker: String,
    pub image_vm: String,
    /// The slim refs: same three images with the provisioning steps left to
    /// lbx-setup (`llm-in-a-box:<runtime>-slim`).
    pub image_sysbox_slim: String,
    pub image_docker_slim: String,
    pub image_vm_slim: String,
    /// `full`, `slim` or `auto` (auto = slim when a slim image is present).
    pub mode: String,
    /// Host variables forwarded into an interactive box (names only).
    pub env_forward: Vec<String>,
    pub state_dir: PathBuf,
    pub vm_mem: String,
    pub vm_cpus: String,
    pub vm_accel: String,
    pub vm_store_size: String,
    pub vm_store_disable: String,
    pub vm_missing: String,
    pub runtime_default: String,
}

const KEYS: [&str; 16] = [
    "image.sysbox",
    "image.docker",
    "image.vm",
    "image.sysbox.slim",
    "image.docker.slim",
    "image.vm.slim",
    "mode",
    "env.forward",
    "state.dir",
    "vm.mem",
    "vm.cpus",
    "vm.accel",
    "vm.store.size",
    "vm.store.disable",
    "vm.missing",
    "runtime.default",
];

pub fn value_ok(v: &str) -> bool {
    if v.is_empty() || v.starts_with('-') {
        return false;
    }
    v.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '/' | '@' | '+' | '-'))
}

/// A variable name: what a shell accepts, and nothing else.
pub fn var_name_ok(v: &str) -> bool {
    let mut chars = v.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// A comma-separated list of variable names (the `env.forward` value).
pub fn env_list_ok(v: &str) -> bool {
    !v.is_empty() && v.split(',').all(|n| var_name_ok(n.trim()))
}

/// The provisioning modes a config file may name.
pub fn mode_ok(v: &str) -> bool {
    matches!(v, "full" | "slim" | "auto")
}

/// Parse the file's text. Returns the accepted values and the warnings, in
/// the bash's wording.
pub fn parse_text(text: &str) -> (BTreeMap<String, String>, Vec<String>) {
    let mut vals = BTreeMap::new();
    let mut warnings = Vec::new();
    for (idx, raw) in text.lines().enumerate() {
        let line_no = idx + 1;
        if raw.is_empty() || raw.starts_with('#') {
            continue;
        }
        let Some((k, v)) = raw.split_once('=') else {
            warnings.push(format!(
                "WARNING: config line {line_no}: malformed (no '='); using defaults for that key."
            ));
            continue;
        };
        let key = k.trim();
        let val = v.trim();
        if key.is_empty() {
            warnings.push(format!(
                "WARNING: config line {line_no}: malformed (empty key); using defaults for that key."
            ));
            continue;
        }
        if key == "image.relay" {
            warnings.push(format!(
                "WARNING: config line {line_no}: '{key}' is not configurable (the relay image is internal)."
            ));
            continue;
        }
        if !KEYS.contains(&key) {
            warnings.push(format!(
                "WARNING: config line {line_no}: unknown key '{key}'; ignored."
            ));
            continue;
        }
        // `env.forward` is a comma-separated list, so it cannot use the
        // single-value validator; `mode` is an enum.
        if key == "env.forward" {
            if !env_list_ok(val) {
                warnings.push(format!(
                    "WARNING: config line {line_no}: '{key}': invalid value; using default."
                ));
                continue;
            }
            vals.insert(key.to_string(), val.to_string());
            continue;
        }
        if key == "mode" && !mode_ok(val) {
            warnings.push(format!(
                "WARNING: config line {line_no}: '{key}' must be full, slim or auto; using default."
            ));
            continue;
        }
        if !value_ok(val) {
            warnings.push(format!(
                "WARNING: config line {line_no}: '{key}': invalid value; using default."
            ));
            continue;
        }
        vals.insert(key.to_string(), val.to_string());
    }
    (vals, warnings)
}

fn env_or(key: &str, default: &str) -> (String, bool) {
    match crate::util::lbx_env(key) {
        Some(v) => (v, true),
        None => (default.to_string(), false),
    }
}

/// Classify and read the config file, then resolve every configurable with
/// precedence env var > config file > default.
pub fn load() -> Resolved {
    let home = crate::util::home_dir();
    let path = match crate::util::lbx_env("CONFIG") {
        Some(p) => PathBuf::from(p),
        None => home.join(".config/llm_in_a_box/config"),
    };
    let (state_dir, state_dir_set) =
        env_or("STATE_DIR", &home.join(".llm-in-a-box").to_string_lossy());
    let (vm_mem, vm_mem_set) = env_or("VM_MEM", "16384");
    let (vm_cpus, vm_cpus_set) = env_or("VM_CPUS", "8");
    let (vm_accel, vm_accel_set) = env_or("VM_ACCEL", "");
    let (vm_store_size, vm_store_size_set) = env_or("VM_STORE_IMG_SIZE", "");
    let (vm_store_disable, vm_store_disable_set) = env_or("VM_STORE_DISABLE", "");
    let (vm_missing, vm_missing_set) = env_or("VM_MISSING", "");
    let (runtime_default, runtime_default_set) = env_or("RUNTIME_DEFAULT", "");
    let (mode, mode_set) = env_or("MODE", "full");
    let (env_forward_raw, env_forward_set) = env_or("ENV_FORWARD", DEFAULT_ENV_FORWARD);
    let env_forward: Vec<String> = env_forward_raw
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let mut r = Resolved {
        state: ConfigState::Usable,
        error: String::new(),
        warnings: Vec::new(),
        path: path.clone(),
        image_sysbox: IMAGE_SYSBOX.to_string(),
        image_docker: IMAGE_DOCKER.to_string(),
        image_vm: IMAGE_VM.to_string(),
        image_sysbox_slim: IMAGE_SYSBOX_SLIM.to_string(),
        image_docker_slim: IMAGE_DOCKER_SLIM.to_string(),
        image_vm_slim: IMAGE_VM_SLIM.to_string(),
        mode,
        env_forward,
        state_dir: PathBuf::from(state_dir),
        vm_mem,
        vm_cpus,
        vm_accel,
        vm_store_size,
        vm_store_disable,
        vm_missing,
        runtime_default,
    };

    let vals = match classify(&path) {
        Classified::Missing => {
            r.state = ConfigState::Missing;
            return r;
        }
        Classified::Unusable { reason, fix } => {
            r.state = ConfigState::Unusable;
            r.error = format!(
                "ERROR: cannot read config '{}': {reason}.\n       Fix: {fix}",
                path.display()
            );
            return r;
        }
        Classified::Text(text) => {
            let (vals, warnings) = parse_text(&text);
            r.warnings = warnings;
            vals
        }
    };
    if let Some(v) = vals.get("image.sysbox") {
        r.image_sysbox = v.clone();
    }
    if let Some(v) = vals.get("image.docker") {
        r.image_docker = v.clone();
    }
    if let Some(v) = vals.get("image.vm") {
        r.image_vm = v.clone();
    }
    if let Some(v) = vals.get("image.sysbox.slim") {
        r.image_sysbox_slim = v.clone();
    }
    if let Some(v) = vals.get("image.docker.slim") {
        r.image_docker_slim = v.clone();
    }
    if let Some(v) = vals.get("image.vm.slim") {
        r.image_vm_slim = v.clone();
    }
    if !mode_set && let Some(v) = vals.get("mode") {
        r.mode = v.clone();
    }
    if !env_forward_set && let Some(v) = vals.get("env.forward") {
        r.env_forward = v
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
    }
    let seed = |set: bool, key: &str, target: &mut String| {
        if !set && let Some(v) = vals.get(key) {
            *target = v.clone();
        }
    };
    if !state_dir_set && let Some(v) = vals.get("state.dir") {
        r.state_dir = PathBuf::from(v);
    }
    seed(vm_mem_set, "vm.mem", &mut r.vm_mem);
    seed(vm_cpus_set, "vm.cpus", &mut r.vm_cpus);
    seed(vm_accel_set, "vm.accel", &mut r.vm_accel);
    seed(vm_store_size_set, "vm.store.size", &mut r.vm_store_size);
    seed(
        vm_store_disable_set,
        "vm.store.disable",
        &mut r.vm_store_disable,
    );
    seed(vm_missing_set, "vm.missing", &mut r.vm_missing);
    seed(
        runtime_default_set,
        "runtime.default",
        &mut r.runtime_default,
    );
    r
}

enum Classified {
    Missing,
    /// Refused, with the cause and the remedy. "cannot read config" alone names
    /// the symptom; a mode-bit or ownership refusal is invisible in `cat`,
    /// which is exactly what makes it a confusing error.
    Unusable {
        reason: String,
        fix: String,
    },
    Text(String),
}

fn classify(path: &Path) -> Classified {
    let p = path.display();
    let meta = match std::fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) => {
            return if e.kind() == std::io::ErrorKind::NotFound {
                Classified::Missing
            } else {
                Classified::Unusable {
                    reason: format!("it cannot be inspected ({e})"),
                    fix: format!(
                        "ls -ld '{p}'  # check the file's own mode and its parent directory"
                    ),
                }
            };
        }
    };
    if meta.file_type().is_symlink() {
        return Classified::Unusable {
            reason: "it is a symbolic link, which another process can repoint".to_string(),
            fix: format!(
                "cp --remove-destination \"$(readlink -f '{p}')\" '{p}'  # replace the link with a real file"
            ),
        };
    }
    if !meta.is_file() {
        return Classified::Unusable {
            reason: "it is not a regular file".to_string(),
            fix: format!("rm -rf '{p}'  # then write the config again"),
        };
    }
    let uid = crate::util::host_uid();
    if meta.uid() != uid {
        return Classified::Unusable {
            reason: format!("it is owned by uid {}, not by you (uid {uid})", meta.uid()),
            fix: format!("sudo chown \"$USER:\" '{p}'"),
        };
    }
    let mode = meta.mode() & 0o777;
    if mode & 0o022 != 0 {
        let who = match (mode & 0o020 != 0, mode & 0o002 != 0) {
            (true, true) => "group and others",
            (false, true) => "others",
            _ => "group",
        };
        return Classified::Unusable {
            reason: format!(
                "it is writable by {who} (mode {mode:03o}), so another local user could change \
                 the host variables or the policy it names"
            ),
            fix: format!("chmod 600 '{p}'"),
        };
    }
    match std::fs::read(path) {
        Ok(bytes) => Classified::Text(String::from_utf8_lossy(&bytes).into_owned()),
        Err(e) => Classified::Unusable {
            reason: format!("it exists but cannot be read ({e})"),
            fix: format!("chmod u+r '{p}'"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn last_wins_and_warnings() {
        let (vals, warns) = parse_text(
            "image.docker=a:1\nimage.docker=b:2\nbogus\nimage.relay=x\nfoo=bar\nimage.vm=$(id)\n",
        );
        assert_eq!(vals.get("image.docker").map(String::as_str), Some("b:2"));
        assert_eq!(warns.len(), 4);
        assert!(warns[0].contains("line 3: malformed (no '=')"));
        assert!(warns[1].contains("not configurable"));
        assert!(warns[2].contains("unknown key 'foo'"));
        assert!(warns[3].contains("'image.vm': invalid value"));
    }

    /// The file trust rules: a group-writable or world-writable file, a
    /// symlink and a directory are unusable (named in the error); a missing
    /// file is simply missing and every default stands.
    #[test]
    fn classification_and_defaults() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let p = tmp.path().join("config");
        assert!(matches!(classify(&p), Classified::Missing));
        std::fs::write(&p, "image.docker=x:1\n").unwrap_or_else(|e| panic!("{e}"));
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o664))
            .unwrap_or_else(|e| panic!("{e}"));
        assert!(matches!(classify(&p), Classified::Unusable { .. }));
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o644))
            .unwrap_or_else(|e| panic!("{e}"));
        assert!(matches!(classify(&p), Classified::Text(t) if t == "image.docker=x:1\n"));
        let link = tmp.path().join("link");
        std::os::unix::fs::symlink(&p, &link).unwrap_or_else(|e| panic!("{e}"));
        assert!(matches!(classify(&link), Classified::Unusable { .. }));
        assert!(matches!(classify(tmp.path()), Classified::Unusable { .. }));
    }

    /// A refusal must say WHY: a wrong mode or owner is invisible to `cat`, so
    /// "cannot read config" on its own sends people looking at the wrong thing.
    #[test]
    fn refusals_name_the_cause_and_the_fix() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let p = tmp.path().join("config");
        std::fs::write(&p, "env.forward=GH_TOKEN\n").unwrap_or_else(|e| panic!("{e}"));
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o664))
            .unwrap_or_else(|e| panic!("{e}"));
        let Classified::Unusable { reason, fix } = classify(&p) else {
            panic!("0o664 must be refused");
        };
        assert!(reason.contains("writable by group"), "{reason}");
        assert!(reason.contains("664"), "{reason}");
        assert!(fix.starts_with("chmod 600"), "{fix}");
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o646))
            .unwrap_or_else(|e| panic!("{e}"));
        let Classified::Unusable { reason, .. } = classify(&p) else {
            panic!("0o646 must be refused");
        };
        assert!(reason.contains("writable by others"), "{reason}");
    }

    #[test]
    fn values() {
        assert!(value_ok("ghcr.io/x/y:1.2@sha256:abc"));
        assert!(!value_ok("--privileged"));
        assert!(!value_ok("a b"));
        assert!(!value_ok(""));
    }
}
