//! Image modes: `full` (every capability baked at build time) and `slim`
//! (the same provisioning steps, run inside the box by `lbx-setup`).
//!
//! Both images come from one Dockerfile and one set of steps in
//! `docker/provision.d/`, so the modes differ in *when* a capability is
//! installed, never in *how*. The mode is a property of the image, recorded in
//! the `llm-in-a-box.provision` label (`full` / `core`) at build time — not a
//! clock, not a filename convention.

use crate::config::Resolved;
use crate::docker::Docker;
use crate::util::out;

/// The image label that records a mode. Sibling of `llm-in-a-box.user`.
pub const LABEL: &str = "llm-in-a-box.provision";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provision {
    /// Everything installed at build time (the image that shipped before the
    /// split, and still the default).
    Full,
    /// Base image plus the provisioning steps; `lbx-setup` installs on demand.
    Core,
}

impl Provision {
    pub fn label(self) -> &'static str {
        match self {
            Provision::Full => "full",
            Provision::Core => "core",
        }
    }

    pub fn from_label(s: &str) -> Option<Self> {
        match s.trim() {
            "full" => Some(Provision::Full),
            "core" => Some(Provision::Core),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Provision::Full => "full",
            Provision::Core => "slim",
        }
    }
}

/// The configured image ref for a runtime and mode.
pub fn image_ref(cfg: &Resolved, runtime: &str, p: Provision) -> String {
    match (runtime, p) {
        ("sysbox", Provision::Core) => cfg.image_sysbox_slim.clone(),
        ("sysbox", Provision::Full) => cfg.image_sysbox.clone(),
        ("vm", Provision::Core) => cfg.image_vm_slim.clone(),
        ("vm", Provision::Full) => cfg.image_vm.clone(),
        (_, Provision::Core) => cfg.image_docker_slim.clone(),
        (_, Provision::Full) => cfg.image_docker.clone(),
    }
}

/// The mode an image was built in, read from its label. `None` when the image
/// is absent or predates the label (those are full images).
pub fn probe(image: &str) -> Option<Provision> {
    let v = Docker::image_label(image, LABEL);
    Provision::from_label(&v)
}

/// The pure decision, so the rule is testable without docker: an explicit flag
/// wins, then the config, then `auto` = slim exactly when a slim image exists.
/// Default is full — a user who never built a slim image is never affected.
pub fn choose(flag: Option<Provision>, configured: &str, slim_exists: bool) -> Provision {
    if let Some(p) = flag {
        return p;
    }
    match configured {
        "slim" => Provision::Core,
        "full" | "" => Provision::Full,
        "auto" => {
            if slim_exists {
                Provision::Core
            } else {
                Provision::Full
            }
        }
        _ => Provision::Full,
    }
}

/// Resolve the image for this launch and say which one was chosen. `Err` is a
/// complete, printed message (the caller exits 1).
pub fn resolve(
    cfg: &Resolved,
    runtime: &str,
    slim_flag: bool,
    full_flag: bool,
) -> Result<(String, Provision), String> {
    let flag = if slim_flag {
        Some(Provision::Core)
    } else if full_flag {
        Some(Provision::Full)
    } else {
        None
    };
    let slim_ref = image_ref(cfg, runtime, Provision::Core);
    let slim_exists = slim_flag || Docker::image_exists(&slim_ref);
    let p = choose(flag, &cfg.mode, slim_exists);
    let image = image_ref(cfg, runtime, p);

    // A missing SLIM image is an error here, because only an explicit request
    // (`--slim`, or mode=slim) can select slim without a slim image existing: it
    // is the one case where the caller asked for something specific and absent.
    //
    // A missing FULL image is left to the create path, which owns the legacy
    // behaviour: warn and fall back to `llm-in-a-box:latest`, else print the
    // resolved image with its build command. Erroring here would bypass both.
    if p == Provision::Core && !Docker::image_exists(&image) {
        let mut msg = format!("ERROR: the slim {runtime} image '{image}' is not present.\n");
        msg.push_str(&format!("       Build it:  ./build --slim {runtime}\n"));
        msg.push_str("       (or use --full for the preprovisioned image)");
        return Err(msg);
    }

    out(&format!(
        "==> using {image} ({}, {})",
        p.name(),
        match p {
            Provision::Full => "all capabilities installed",
            Provision::Core => "install what you need with lbx-setup",
        }
    ));
    Ok((image, p))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_flags_win() {
        assert_eq!(
            choose(Some(Provision::Core), "full", false),
            Provision::Core
        );
        assert_eq!(choose(Some(Provision::Full), "slim", true), Provision::Full);
    }

    #[test]
    fn default_is_full_so_nothing_changes() {
        assert_eq!(choose(None, "full", true), Provision::Full);
        assert_eq!(choose(None, "", true), Provision::Full);
        assert_eq!(choose(None, "nonsense", true), Provision::Full);
    }

    #[test]
    fn auto_needs_a_slim_image_and_never_uses_a_clock() {
        assert_eq!(choose(None, "auto", true), Provision::Core);
        assert_eq!(choose(None, "auto", false), Provision::Full);
    }

    #[test]
    fn labels_round_trip() {
        for p in [Provision::Full, Provision::Core] {
            assert_eq!(Provision::from_label(p.label()), Some(p));
        }
        assert_eq!(Provision::from_label(""), None);
        assert_eq!(Provision::from_label("slim"), None);
    }
}
