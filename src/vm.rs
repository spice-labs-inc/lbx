//! The vm runtime: preflight, the project-dir README, the docker store
//! image, the seed file, the qemu argument vector and launch, ssh wait and
//! attach. Ported for argument construction; verified only against the
//! suites' fake qemu (no KVM group on the spike host).

use crate::config::Resolved;
use crate::session::{vm_live_pid_for, vm_sessions_dir};
use crate::util::{err, out, path_str, realpath_m, which};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

/// The error was already printed to stderr.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Printed;

pub struct Base {
    pub base: PathBuf,
    pub vmlinuz: PathBuf,
    pub initrd: PathBuf,
}

pub fn latest_base_dir(cfg: &Resolved) -> Option<PathBuf> {
    let bases = cfg.state_dir.join("bases");
    let l = std::fs::read_link(bases.join("latest")).ok()?;
    let d = bases.join(l);
    (d.join("base.qcow2").is_file() && d.join("vmlinuz").is_file()).then_some(d)
}

/// The session's recorded origin, else the launch directory.
pub fn project_dir(cfg: &Resolved, session: &str) -> PathBuf {
    if !session.is_empty()
        && let Ok(o) = std::fs::read_to_string(vm_sessions_dir(cfg).join(session).join("origin"))
        && !o.trim_end_matches('\n').is_empty()
    {
        return PathBuf::from(o.trim_end_matches('\n'));
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// session record > latest > legacy flat layout. `Err` = error printed.
pub fn resolve_base(cfg: &Resolved, session: &str) -> Result<Base, Printed> {
    let bases = cfg.state_dir.join("bases");
    let rec = std::fs::read_to_string(vm_sessions_dir(cfg).join(session).join("base"))
        .map(|s| s.trim_end_matches('\n').to_string())
        .unwrap_or_default();
    if !rec.is_empty() {
        let d = bases.join(&rec);
        if d.join("base.qcow2").is_file() {
            return Ok(Base {
                base: d.join("base.qcow2"),
                vmlinuz: d.join("vmlinuz"),
                initrd: d.join("initrd.img"),
            });
        }
        let legacy = project_dir(cfg, session)
            .join("vms_and_docker_from_llm_box/bases")
            .join(&rec);
        if legacy.join("base.qcow2").is_file() {
            err(&format!(
                "ERROR: session '{session}' records base image '{rec}', which is not in the"
            ));
            err("       state directory, but a base from the earlier layout exists at:");
            err(&format!("         {}", path_str(&legacy)));
            err("       Move it into place, then relaunch:");
            err(&format!(
                "         mkdir -p '{}' && mv '{}' '{}'",
                path_str(&bases),
                path_str(&legacy),
                path_str(&bases.join(&rec))
            ));
            return Err(Printed);
        }
        err(&format!(
            "ERROR: session '{session}' records base image '{rec}', but it no longer exists."
        ));
        err("       (The base was garbage-collected or removed — never rebase a live");
        err("        overlay onto a different base; the session cannot be relaunched.)");
        return Err(Printed);
    }
    if let Some(d) = latest_base_dir(cfg) {
        return Ok(Base {
            base: d.join("base.qcow2"),
            vmlinuz: d.join("vmlinuz"),
            initrd: d.join("initrd.img"),
        });
    }
    Ok(Base {
        base: cfg.state_dir.join("base.qcow2"),
        vmlinuz: cfg.state_dir.join("vmlinuz"),
        initrd: cfg.state_dir.join("initrd.img"),
    })
}

fn vm_have(cfg: &Resolved, name: &str) -> bool {
    if cfg.vm_missing.split(' ').any(|m| m == name) {
        return false;
    }
    match name {
        "mkfs.ext4" => {
            which("mkfs.ext4").is_some()
                || Path::new("/usr/sbin/mkfs.ext4").exists()
                || Path::new("/sbin/mkfs.ext4").exists()
        }
        "/dev/kvm" => Path::new("/dev/kvm").exists(),
        "kvm-group" => std::process::Command::new("id")
            .arg("-nG")
            .output()
            .map(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .split_whitespace()
                    .any(|g| g == "kvm")
            })
            .unwrap_or(false),
        _ => which(name).is_some(),
    }
}

pub fn kvm_required(cfg: &Resolved) -> bool {
    cfg.vm_accel != "tcg"
}

/// Plant the first-reader README in the project's artifact directory.
pub fn ensure_state_message(cfg: &Resolved, session: &str, script_dir: &Path) {
    let mut src = script_dir.join("docker/state-dir-message.md");
    if !src.is_file() {
        src = PathBuf::from("/data/docker/state-dir-message.md");
    }
    let dir = project_dir(cfg, session).join("vms_and_docker_from_llm_box");
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let readme = dir.join("README.md");
    if readme.exists() {
        return;
    }
    // Written, not copied: the file takes the umask like the bash `cp` did,
    // instead of inheriting the shipped file's mode.
    let text = std::fs::read_to_string(&src)
        .unwrap_or_else(|_| crate::assets::STATE_DIR_MESSAGE.to_string());
    let _ = std::fs::write(&readme, text);
}

/// The content id (`.Id`) of an image: `None` when docker cannot report one.
/// `image inspect --format {{.Id}}` is the image's own identity, unlike the
/// ref, which is only a tag for anything built locally.
fn image_content_id(image: &str) -> Option<String> {
    crate::docker::Docker::line(&["image", "inspect", "--format", "{{.Id}}", image])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// A ref that carries a content digest (`repo@sha256:…`) rather than a tag.
fn is_digest_ref(r: &str) -> bool {
    r.split_once('@')
        .is_some_and(|(_, d)| d.starts_with("sha256:"))
}

/// The first repo digest docker reports for an image (`repo@sha256:…`) — the
/// form `build` writes into `from-image` when the image has one.
fn image_repo_digest(image: &str) -> Option<String> {
    let out = crate::docker::Docker::line(&[
        "image",
        "inspect",
        "--format",
        "{{.RepoDigests}}",
        image,
    ])?;
    out.trim()
        .trim_start_matches('[')
        .trim_end_matches(']')
        .split_whitespace()
        .next()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// The preflight. Exits 1 with guidance on failure; returns the base.
pub fn preflight(cfg: &Resolved, session: &str, script_dir: &Path) -> Base {
    let Ok(b) = resolve_base(cfg, session) else {
        std::process::exit(1);
    };
    if let Some(dir) = b.base.parent()
        && let Ok(text) = std::fs::read_to_string(dir.join("from-image"))
    {
        let from = text.lines().next().unwrap_or("").to_string();
        let recorded_id = text
            .lines()
            .find_map(|l| l.strip_prefix("image-id "))
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let current_id = image_content_id(&cfg.image_vm);
        // Content identity decides when both sides are known (2026-10-24).
        // The build records the ref (the repo DIGEST when docker reports one)
        // and, since this change, the image id. Two things made the ref
        // comparison alone wrong:
        //   * a rebuild under the same TAG was invisible, so a base disk could
        //     be silently older than the configuration said, and
        //   * Docker 29 reports a repo digest even for a locally BUILT image,
        //     so the 2026-09-14 assumption ("RepoDigests is empty for local
        //     builds") no longer holds and comparing that digest to the
        //     configured TAG warned "built from a different image" about a
        //     base built from exactly that image (measured: docker 29.9.2).
        // So: ids known -> compare ids (identical content under a renamed ref
        // is not a difference); otherwise fall back to the ref, resolving the
        // configured image's digest when the record holds one.
        match (recorded_id, current_id.as_deref()) {
            (Some(recorded), Some(current)) if recorded != current => {
                err(&format!(
                    "WARNING: session base was built from vm image '{recorded}', but the configured"
                ));
                err(&format!(
                    "         vm image ('{}') is now '{current}' — the base is not what the",
                    cfg.image_vm
                ));
                err("         configuration describes. Rebuild it:  ./build vm");
            }
            (Some(_), Some(_)) => {}
            _ => {
                if !from.is_empty() && from != cfg.image_vm {
                    let same = is_digest_ref(&from)
                        && !is_digest_ref(&cfg.image_vm)
                        && image_repo_digest(&cfg.image_vm).is_none_or(|d| d == from);
                    if !same {
                        err(&format!(
                            "WARNING: session base was built from a different image ('{from}') than the currently configured vm image ('{}').",
                            cfg.image_vm
                        ));
                    }
                }
            }
        }
    }
    ensure_state_message(cfg, session, script_dir);
    out("==> Checking vm runtime prerequisites");
    let mut fail = false;
    let mut missing: Vec<&str> = Vec::new();
    if vm_have(cfg, "qemu-system-x86_64") {
        out("[PASS] qemu-system-x86_64");
        let ver = std::process::Command::new("qemu-system-x86_64")
            .arg("--version")
            .output()
            .map(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .lines()
                    .next()
                    .unwrap_or("")
                    .to_string()
            })
            .unwrap_or_default();
        let major = ver
            .split("version ")
            .nth(1)
            .and_then(|s| s.split('.').next())
            .and_then(|m| m.parse::<u32>().ok());
        match major {
            Some(m) if m >= 5 => out(&format!(
                "[PASS] qemu-system-x86_64 version {m}.x (>= 5.0 for -device nvme)"
            )),
            _ => {
                out(&format!(
                    "[FAIL] qemu-system-x86_64 version ('{ver}') is below the 5.0 floor required by -device nvme — install a newer qemu: sudo apt-get install -y qemu-system-x86"
                ));
                fail = true;
                missing.push("old-qemu");
            }
        }
    } else {
        out("[FAIL] qemu-system-x86_64 — sudo apt-get install -y qemu-system-x86");
        fail = true;
        missing.push("qemu-system-x86_64");
    }
    if vm_have(cfg, "qemu-img") {
        out("[PASS] qemu-img");
    } else {
        out("[FAIL] qemu-img — sudo apt-get install -y qemu-utils");
        fail = true;
        missing.push("qemu-img");
    }
    if kvm_required(cfg) {
        if vm_have(cfg, "/dev/kvm") {
            out("[PASS] /dev/kvm");
        } else {
            out(
                "[FAIL] /dev/kvm — enable CPU virtualization + KVM module (nested virt if this is a VM/cloud instance)",
            );
            fail = true;
            missing.push("/dev/kvm");
        }
        if vm_have(cfg, "kvm-group") {
            out("[PASS] kvm group");
        } else {
            out("[FAIL] kvm group — sudo usermod -aG kvm $USER && newgrp kvm");
            fail = true;
            missing.push("kvm-group");
        }
    } else {
        let accel = if cfg.vm_accel.is_empty() {
            "tcg"
        } else {
            cfg.vm_accel.as_str()
        };
        out(&format!(
            "[INFO] /dev/kvm + kvm group checks skipped (LBX_VM_ACCEL={accel}: software emulation)"
        ));
    }
    if vm_have(cfg, "ssh") {
        out("[PASS] ssh client");
    } else {
        out("[FAIL] ssh client — sudo apt-get install -y openssh-client");
        fail = true;
        missing.push("ssh");
    }
    if b.base.is_file() {
        let qcow2 = !vm_have(cfg, "qemu-img")
            || std::process::Command::new("qemu-img")
                .args(["info"])
                .arg(&b.base)
                .output()
                .map(|o| {
                    String::from_utf8_lossy(&o.stdout)
                        .to_lowercase()
                        .lines()
                        .any(|l| l.trim_start().starts_with("file format:") && l.contains("qcow2"))
                })
                .unwrap_or(false);
        if qcow2 {
            out(&format!("[PASS] base disk ({})", path_str(&b.base)));
        } else {
            out(&format!(
                "[FAIL] base disk ({}) is not a valid qcow2 image — rebuild it: ./build vm",
                path_str(&b.base)
            ));
            fail = true;
            missing.push("bad-base-disk");
        }
    } else {
        out("[FAIL] base disk — build it first: ./build vm");
        fail = true;
        missing.push("base-disk");
    }
    if b.vmlinuz.is_file() {
        out("[PASS] kernel");
    } else {
        out("[FAIL] kernel — build it first: ./build vm");
        fail = true;
        missing.push("kernel");
    }
    if public_keys().is_empty() {
        out("[WARN] no ~/.ssh/*.pub found — the vm boots, but ssh attach needs one: ssh-keygen");
    } else {
        out("[PASS] ssh public key");
    }
    out("");
    if fail {
        out("FIX — resolve the missing items above, then re-run:");
        for m in missing {
            let line = match m {
                "qemu-system-x86_64" => {
                    "  qemu-system-x86_64: sudo apt-get install -y qemu-system-x86"
                }
                "old-qemu" => {
                    "  qemu-system-x86_64: upgrade to >= 5.0 (sudo apt-get install -y qemu-system-x86)"
                }
                "qemu-img" => "  qemu-img:            sudo apt-get install -y qemu-utils",
                "/dev/kvm" => "  /dev/kvm:            enable CPU virtualization + KVM module",
                "kvm-group" => "  kvm group:           sudo usermod -aG kvm $USER && newgrp kvm",
                "ssh" => "  ssh client:          sudo apt-get install -y openssh-client",
                "base-disk" | "kernel" => "  base disk + kernel:  ./build vm",
                "bad-base-disk" => "  base disk:           rebuild it: ./build vm",
                _ => continue,
            };
            out(line);
        }
        out("");
        out("  Alternatively, force a different runtime explicitly:");
        out("    lbx --runtime sysbox <session>");
        out("    lbx --runtime docker <session>");
        out("");
        std::process::exit(1);
    }
    b
}

fn public_keys() -> Vec<String> {
    let dir = crate::util::home_dir().join(".ssh");
    let mut keys = Vec::new();
    if let Ok(rd) = std::fs::read_dir(dir) {
        let mut paths: Vec<PathBuf> = rd.filter_map(Result::ok).map(|e| e.path()).collect();
        paths.sort();
        for p in paths {
            if p.extension().is_some_and(|e| e == "pub")
                && p.is_file()
                && let Ok(k) = std::fs::read_to_string(&p)
                && !k.is_empty()
            {
                keys.push(k.trim_end_matches('\n').to_string());
            }
        }
    }
    keys
}

/// `printf %q` for the seed file: single-quote when needed.
fn shell_quote(s: &str) -> String {
    if !s.is_empty()
        && s.chars().all(|c| {
            c.is_ascii_alphanumeric()
                || matches!(c, '.' | '_' | '/' | ':' | '-' | '=' | '+' | ',' | '@' | '%')
        })
    {
        return s.to_string();
    }
    if s.contains('\n') {
        return format!(
            "$'{}'",
            s.replace('\\', "\\\\")
                .replace('\'', "\\'")
                .replace('\n', "\\n")
        );
    }
    format!("'{}'", s.replace('\'', "'\\''"))
}

pub fn size_bytes(size: &str) -> Option<u64> {
    let (number, unit): (&str, u64) = match size.chars().last() {
        Some('k' | 'K') => (&size[..size.len() - 1], 1024),
        Some('m' | 'M') => (&size[..size.len() - 1], 1 << 20),
        Some('g' | 'G') => (&size[..size.len() - 1], 1 << 30),
        Some('t' | 'T') => (&size[..size.len() - 1], 1 << 40),
        _ => (size, 1),
    };
    if number.is_empty() || !number.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    number.parse::<u64>().ok()?.checked_mul(unit)
}

/// The docker store image: resolve, validate, create, lock. `Ok(None)` when
/// disabled; `Err` = error printed.
pub fn store_image_prepare(cfg: &Resolved, session: &str) -> Result<Option<PathBuf>, Printed> {
    if cfg.vm_store_disable == "1" {
        return Ok(None);
    }
    let img = project_dir(cfg, session)
        .join("vms_and_docker_from_llm_box")
        .join("docker-store.img");
    let img_dir = img.parent().map(Path::to_path_buf).unwrap_or_default();
    if std::fs::symlink_metadata(&img_dir).is_ok_and(|m| m.file_type().is_symlink()) {
        err(&format!(
            "ERROR: the state directory ({}) is a symlink; refusing to use it.",
            path_str(&img_dir)
        ));
        err(&format!("       Delete it (rm '{}').", path_str(&img_dir)));
        return Err(Printed);
    }
    let size_str = if cfg.vm_store_size.is_empty() {
        "500G"
    } else {
        cfg.vm_store_size.as_str()
    };
    let Some(bytes) = size_bytes(size_str) else {
        err(&format!(
            "ERROR: invalid LBX_VM_STORE_IMG_SIZE '{size_str}' (use e.g. 500G, 64M, 1024)."
        ));
        return Err(Printed);
    };
    if bytes == 0 {
        err(&format!(
            "ERROR: LBX_VM_STORE_IMG_SIZE '{size_str}' resolves to 0 bytes; refusing to create an empty store image."
        ));
        err("       Set a positive size (e.g. LBX_VM_STORE_IMG_SIZE=500G).");
        return Err(Printed);
    }
    let img_real = realpath_m(&img);
    let p = path_str(&img);
    if let Ok(m) = std::fs::symlink_metadata(&img) {
        if m.file_type().is_symlink() {
            err(&format!(
                "ERROR: the store image ({p}) is a symlink; refusing to use it."
            ));
            err(&format!("       Delete it (rm '{p}')."));
            return Err(Printed);
        }
        if m.is_dir() {
            err(&format!(
                "ERROR: the store image ({p}) is a directory; refusing to use it."
            ));
            err(&format!("       Delete it (rm -r '{p}')."));
            return Err(Printed);
        }
        if !m.is_file() {
            err(&format!(
                "ERROR: the store image ({p}) is not a regular file; refusing to use it."
            ));
            return Err(Printed);
        }
        if m.len() == 0 {
            err(&format!(
                "ERROR: the store image ({p}) is zero-length; refusing to use it."
            ));
            err(&format!("       Delete it (rm '{p}')."));
            return Err(Printed);
        }
        if m.len() != bytes {
            err(&format!(
                "ERROR: the store image ({p}) is {} bytes but LBX_VM_STORE_IMG_SIZE",
                m.len()
            ));
            err(&format!(
                "       configures {bytes} bytes; refusing to use a size-mismatched image."
            ));
            err(&format!(
                "       Delete it (rm '{p}') or override LBX_VM_STORE_IMG_SIZE."
            ));
            return Err(Printed);
        }
        let uid = crate::util::host_uid();
        if m.uid() != uid {
            err(&format!(
                "ERROR: the store image ({p}) is owned by uid {}, not {uid};",
                m.uid()
            ));
            err("       refusing to use a foreign-owned image.");
            return Err(Printed);
        }
        let _ = std::fs::set_permissions(&img, std::fs::Permissions::from_mode_0600());
    } else {
        if std::fs::create_dir_all(&img_dir).is_err() {
            err(&format!(
                "ERROR: cannot create the store image directory '{}'.",
                path_str(&img_dir)
            ));
            return Err(Printed);
        }
        if let Some(free_kb) = free_kb(&img_dir)
            && free_kb.saturating_mul(1024) < bytes
        {
            err(&format!(
                "WARNING: low free space for the docker store image: {free_kb} KiB free, {bytes} bytes needed. Free space or set LBX_VM_STORE_IMG_SIZE."
            ));
        }
        let created = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .open(&img)
            .and_then(|f| f.set_len(bytes));
        if created.is_err() {
            err(&format!("ERROR: cannot create the store image '{p}'."));
            return Err(Printed);
        }
        let _ = std::fs::set_permissions(&img, std::fs::Permissions::from_mode_0600());
    }
    let lock = format!("{}.lock", path_str(&img_real));
    if !flock_free(&lock) {
        err("ERROR: the docker store image is locked by another session (single writer):");
        err(&format!("       {}", path_str(&img_real)));
        err("       Stop the other llm-in-a-box session before launching this one.");
        return Err(Printed);
    }
    Ok(Some(img_real))
}

trait Mode0600 {
    fn from_mode_0600() -> std::fs::Permissions;
}
impl Mode0600 for std::fs::Permissions {
    fn from_mode_0600() -> std::fs::Permissions {
        use std::os::unix::fs::PermissionsExt;
        std::fs::Permissions::from_mode(0o600)
    }
}

fn free_kb(dir: &Path) -> Option<u64> {
    let o = std::process::Command::new("df")
        .arg("-Pk")
        .arg(dir)
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&o.stdout);
    text.lines().nth(1)?.split_whitespace().nth(3)?.parse().ok()
}

/// `flock -n <lock> true`: can the lock be taken right now?
fn flock_free(lock: &str) -> bool {
    std::process::Command::new("flock")
        .args(["-n", lock, "true"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

pub fn share_args(origin: &str, session_dir: &str) -> Vec<String> {
    vec![
        "-virtfs".into(),
        format!("local,path={origin},mount_tag=host0,security_model=none"),
        "-virtfs".into(),
        format!("local,path={session_dir},mount_tag=seed0,security_model=none,readonly=on"),
    ]
}

/// Everything the qemu argument vector is built from (pure data).
#[derive(Debug, Clone, Default)]
pub struct QemuPlan {
    pub accel: String,
    pub cpus: String,
    pub mem: String,
    pub vmlinuz: String,
    pub initrd: Option<String>,
    pub overlay: String,
    pub origin: String,
    pub session_dir: String,
    pub store_img: Option<String>,
    /// `hostfwd=...` list (ssh first) plus the netwall suffix.
    pub netdev_extra: String,
    /// `(id, host device path)` for serial pass-through.
    pub serial_devices: Vec<(usize, String)>,
}

/// `hostfwd=tcp::<host>-:<guest>` for ssh, --ports, --vm-web-port and
/// every --publish, in the bash's order.
pub fn hostfwd_string(
    ssh_port: u16,
    ports: (Option<u16>, Option<u16>),
    vm_web_port: &str,
    publish: &[String],
) -> String {
    let mut hf = format!("hostfwd=tcp::{ssh_port}-:22");
    if let Some(p) = ports.0 {
        hf.push_str(&format!(",hostfwd=tcp::{p}-:8080"));
    }
    if let Some(p) = ports.1 {
        hf.push_str(&format!(",hostfwd=tcp::{p}-:3000"));
    }
    if !vm_web_port.is_empty() {
        let host = vm_web_port.split(':').next().unwrap_or("");
        let vm = vm_web_port.rsplit(':').next().unwrap_or("");
        hf.push_str(&format!(",hostfwd=tcp::{host}-:{vm}"));
    }
    for p in publish {
        let host = p.split(':').next().unwrap_or("");
        let boxp = p.rsplit(':').next().unwrap_or("");
        hf.push_str(&format!(",hostfwd=tcp::{host}-:{boxp}"));
    }
    hf
}

/// The netwall suffix of the user netdev: all guest traffic restricted, one
/// door to the relay on the host.
pub fn netwall_suffix(relay_port: &str) -> String {
    format!(",restrict=on,guestfwd=tcp:10.0.2.100:3128-tcp:127.0.0.1:{relay_port}")
}

pub fn qemu_argv(p: &QemuPlan) -> Vec<String> {
    let mut argv: Vec<String> = Vec::new();
    if p.accel == "tcg" {
        argv.extend([
            "-accel".to_string(),
            "tcg,thread=multi".into(),
            "-cpu".into(),
            "max".into(),
        ]);
    } else {
        argv.extend(["-enable-kvm".to_string(), "-cpu".into(), "host".into()]);
    }
    argv.extend([
        "-smp".to_string(),
        p.cpus.clone(),
        "-m".into(),
        p.mem.clone(),
        "-machine".into(),
        "q35".into(),
        "-kernel".into(),
        p.vmlinuz.clone(),
    ]);
    if let Some(i) = &p.initrd {
        argv.push("-initrd".into());
        argv.push(i.clone());
    }
    argv.extend([
        "-append".to_string(),
        "root=/dev/vda rw console=ttyS0 net.ifnames=0 biosdevname=0".into(),
        "-drive".into(),
        format!("file={},if=virtio,format=qcow2", p.overlay),
    ]);
    argv.extend(share_args(&p.origin, &p.session_dir));
    if let Some(img) = &p.store_img {
        argv.extend([
            "-drive".to_string(),
            format!("file={img},if=none,id=store0,format=raw,cache=writeback,discard=unmap"),
            "-device".into(),
            // An NVMe serial is at most 20 bytes: the guest sees a longer one
            // truncated and its by-id link never matches the store script.
            "nvme,drive=store0,serial=lbx-docker-store".into(),
        ]);
    }
    argv.extend([
        "-netdev".to_string(),
        format!("user,id=n0,{}", p.netdev_extra),
        "-device".into(),
        "virtio-net-pci,netdev=n0".into(),
    ]);
    for (i, dev) in &p.serial_devices {
        argv.push("-chardev".into());
        argv.push(format!("serial,id=ser{i},path={dev}"));
        argv.push("-device".into());
        argv.push(format!("isa-serial,chardev=ser{i}"));
    }
    let sd = &p.session_dir;
    argv.extend([
        "-fw_cfg".to_string(),
        format!("name=opt/llm-in-a-box/seed,file={sd}/seed.fw_cfg"),
        "-monitor".into(),
        format!("unix:{sd}/monitor.sock,server,nowait"),
        "-serial".into(),
        format!("file:{sd}/console.log"),
        "-display".into(),
        "none".into(),
        "-no-reboot".into(),
        "-daemonize".into(),
        "-pidfile".into(),
        format!("{sd}/qemu.pid"),
    ]);
    argv
}

pub struct LaunchArgs<'a> {
    pub cfg: &'a Resolved,
    pub session: &'a str,
    pub host_user: &'a str,
    pub host_uid: u32,
    pub host_gid: u32,
    pub ports: bool,
    pub publish: &'a [String],
    pub vm_web_port: &'a str,
    pub devices: &'a [String],
    pub net_policy: &'a str,
}

fn find_free_port(mut candidates: impl Iterator<Item = u16>) -> Option<u16> {
    candidates.find(|&p| std::net::TcpListener::bind(("0.0.0.0", p)).is_ok())
}

/// What the guest reads from fw_cfg at boot (pure data).
#[derive(Debug, Clone, Default)]
pub struct Seed {
    pub host_user: String,
    pub host_uid: u32,
    pub host_gid: u32,
    pub hostname: String,
    pub gh_token: Option<String>,
    pub ssh_pubkeys: Vec<String>,
    pub netwall: bool,
}

/// The seed file text, `KEY=value` lines with shell quoting.
pub fn seed_text(seed: &Seed) -> String {
    let mut s = String::new();
    s.push_str(&format!("HOST_USER={}\n", seed.host_user));
    s.push_str(&format!("HOST_UID={}\n", seed.host_uid));
    s.push_str(&format!("HOST_GID={}\n", seed.host_gid));
    s.push_str(&format!("HOSTNAME={}\n", seed.hostname));
    if let Some(t) = &seed.gh_token {
        s.push_str(&format!("GH_TOKEN={}\n", shell_quote(t)));
    }
    if !seed.ssh_pubkeys.is_empty() {
        let joined = seed.ssh_pubkeys.join("\n");
        s.push_str(&format!("SSH_PUBKEY={}\n", shell_quote(&joined)));
    }
    if seed.netwall {
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            s.push_str(&format!(
                "{name}={}\n",
                shell_quote("http://10.0.2.100:3128")
            ));
        }
        for name in ["NO_PROXY", "no_proxy"] {
            s.push_str(&format!(
                "{name}={}\n",
                shell_quote("localhost,127.0.0.1,10.0.2.0/24")
            ));
        }
        s.push_str(&format!(
            "JAVA_TOOL_OPTIONS={}\n",
            shell_quote("-Dhttp.proxyHost=10.0.2.100 -Dhttp.proxyPort=3128 -Dhttps.proxyHost=10.0.2.100 -Dhttps.proxyPort=3128 -Dhttp.nonProxyHosts=localhost|127.0.0.1|10.0.2.*")
        ));
    }
    s
}

fn write_seed(l: &LaunchArgs, session_dir: &Path) -> Result<(), ()> {
    let s = seed_text(&Seed {
        host_user: l.host_user.to_string(),
        host_uid: l.host_uid,
        host_gid: l.host_gid,
        hostname: l.session.to_string(),
        gh_token: std::env::var("GH_TOKEN").ok().filter(|t| !t.is_empty()),
        ssh_pubkeys: public_keys(),
        netwall: !l.net_policy.is_empty(),
    });
    let seed = session_dir.join("seed.fw_cfg");
    std::fs::write(&seed, s).map_err(|_| ())?;
    let _ = std::fs::set_permissions(&seed, std::fs::Permissions::from_mode_0600());
    Ok(())
}

/// Boot the session. Exits 1 on any failure.
pub fn launch(l: &LaunchArgs) {
    let cfg = l.cfg;
    let session = l.session;
    let session_dir = vm_sessions_dir(cfg).join(session);
    let _ = std::fs::create_dir_all(&session_dir);
    let Ok(b) = resolve_base(cfg, session) else {
        std::process::exit(1);
    };
    let base_dir = b.base.parent().map(Path::to_path_buf).unwrap_or_default();
    if !base_dir.join("built-user").is_file() {
        err(&format!(
            "ERROR: session '{session}' would boot from an OLD base image (no box-user stamp;"
        ));
        err("       built by a previous version of the tooling for user 'claude').");
        err("       lbx only starts boxes built by the current tooling.");
        err("       Use the previous llm_in_a_box script for this box, or destroy and");
        err(&format!(
            "       recreate it:  lbx --runtime vm --destroy {session}"
        ));
        std::process::exit(1);
    }
    let bases = cfg.state_dir.join("bases");
    if !session_dir.join("base").is_file()
        && base_dir.parent() == Some(bases.as_path())
        && let Some(name) = base_dir.file_name()
    {
        let _ = std::fs::write(
            session_dir.join("base"),
            format!("{}\n", name.to_string_lossy()),
        );
    }
    let origin = match std::fs::read_to_string(session_dir.join("origin")) {
        Ok(o) if !o.trim_end_matches('\n').is_empty() => o.trim_end_matches('\n').to_string(),
        Ok(_) => path_str(&std::env::current_dir().unwrap_or_default()),
        Err(_) => {
            let o = path_str(&std::env::current_dir().unwrap_or_default());
            let _ = std::fs::write(session_dir.join("origin"), format!("{o}\n"));
            o
        }
    };
    let store_dir = Path::new(&origin).join("vms_and_docker_from_llm_box");
    if std::fs::symlink_metadata(&store_dir).is_ok_and(|m| m.file_type().is_symlink()) {
        err(&format!(
            "ERROR: the artifact directory ({}) is a symlink; refusing to use it.",
            path_str(&store_dir)
        ));
        err(&format!(
            "       Delete it (rm '{}').",
            path_str(&store_dir)
        ));
        std::process::exit(1);
    }
    if std::fs::create_dir_all(&store_dir).is_err() {
        err(&format!(
            "ERROR: cannot create the artifact directory for the vm session: {}",
            path_str(&store_dir)
        ));
        std::process::exit(1);
    }
    let store_img = match store_image_prepare(cfg, session) {
        Ok(s) => s,
        Err(Printed) => std::process::exit(1),
    };
    let _ = std::fs::write(
        session_dir.join("store-img"),
        format!(
            "{}\n",
            store_img.as_ref().map(|p| path_str(p)).unwrap_or_default()
        ),
    );
    let recorded = std::fs::read_to_string(session_dir.join("base"))
        .map(|s| s.trim_end_matches('\n').to_string())
        .unwrap_or_default();
    if let Some(latest) = latest_base_dir(cfg) {
        let latest = latest
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if !recorded.is_empty() && !latest.is_empty() && recorded != latest {
            err(&format!(
                "WARNING: session base '{recorded}' predates the latest build '{latest}'."
            ));
            err(
                "         It runs the pre-remediation store wiring; destroy and recreate the session:",
            );
            err("         lbx --runtime vm --destroy <session>");
        }
    }
    if vm_live_pid_for(cfg, session).is_some() {
        err(&format!(
            "ERROR: a qemu process for session '{session}' is already running."
        ));
        err(&format!("       Attach with: lbx --runtime vm {session}"));
        std::process::exit(1);
    }
    let overlay = session_dir.join("overlay.qcow2");
    if !overlay.is_file() {
        let legacy = Path::new(&origin)
            .join("vms_and_docker_from_llm_box/sessions")
            .join(session)
            .join("overlay.qcow2");
        if legacy.is_file() {
            err(&format!(
                "ERROR: session '{session}' has no overlay in the state directory, but an"
            ));
            err("       overlay from an earlier layout exists at:");
            err(&format!("         {}", path_str(&legacy)));
            err("       Booting now would start a fresh disk and strand that session's data.");
            err("       Move it into place first:");
            err(&format!(
                "         mkdir -p \"{}\" && mv \"{}\" \"{}\"",
                path_str(&session_dir),
                path_str(&legacy),
                path_str(&overlay)
            ));
            std::process::exit(1);
        }
        let ok = std::process::Command::new("qemu-img")
            .args(["create", "-f", "qcow2", "-F", "qcow2", "-b"])
            .arg(&b.base)
            .arg(&overlay)
            .stdout(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if !ok {
            std::process::exit(1);
        }
    }
    let Some(ssh_port) = find_free_port(2222..=2321) else {
        err("ERROR: no free host port for the vm ssh attach.");
        std::process::exit(1);
    };
    let _ = std::fs::write(session_dir.join("ssh_port"), format!("{ssh_port}\n"));
    let ports = if l.ports {
        (
            find_free_port([8080u16, 18080, 28080].into_iter()),
            find_free_port([3000u16, 13000, 23000].into_iter()),
        )
    } else {
        (None, None)
    };
    let hf = hostfwd_string(ssh_port, ports, l.vm_web_port, l.publish);
    let mut netwall = String::new();
    if !l.net_policy.is_empty() {
        let relay_name = crate::docker::relay_container_name(session);
        let relay_port: String;
        if !crate::docker::Docker::container_exists(&relay_name) {
            let Some(port) = find_free_port(4400..=4499) else {
                err("ERROR: no free host port for the netwall relay.");
                std::process::exit(1);
            };
            let _ = std::fs::write(session_dir.join("relay-port"), format!("{port}\n"));
            let netlogs = cfg.state_dir.join("netlogs").join(session);
            let _ = std::fs::create_dir_all(&netlogs);
            let argv: Vec<String> = vec![
                "run".into(),
                "-d".into(),
                "--name".into(),
                relay_name.clone(),
                "--user".into(),
                format!("{}:{}", l.host_uid, l.host_gid),
                "-e".into(),
                "LLMBOX_POLICY=/policy.json".into(),
                "-e".into(),
                "LLMBOX_DENY_LOG=/log/deny.log".into(),
                "-v".into(),
                format!("{}:/policy.json:ro", l.net_policy),
                "-v".into(),
                format!("{}:/log", path_str(&netlogs)),
                "-p".into(),
                format!("127.0.0.1:{port}:3128"),
                "--network".into(),
                "bridge".into(),
                "llm-in-a-box-relay:latest".into(),
            ];
            if !crate::docker::Docker::quiet_owned(&argv) {
                err("ERROR: could not start the netwall relay (./build relay).");
                std::process::exit(1);
            }
            out(&format!(
                "    (netwall: relay '{relay_name}' on 127.0.0.1:{port}; guest door 10.0.2.100:3128)"
            ));
            relay_port = port.to_string();
        } else {
            relay_port = std::fs::read_to_string(session_dir.join("relay-port"))
                .map(|s| s.trim_end_matches('\n').to_string())
                .unwrap_or_default();
            let _ = crate::docker::Docker::quiet(&["start", &relay_name]);
        }
        if relay_port.is_empty() {
            err(&format!(
                "ERROR: netwall relay port not recorded for session '{session}'."
            ));
            std::process::exit(1);
        }
        let _ = std::fs::write(
            session_dir.join("net-policy"),
            format!("{}\n", l.net_policy),
        );
        netwall = netwall_suffix(&relay_port);
    }
    let mut serial_devices: Vec<(usize, String)> = Vec::new();
    for dev in l.devices {
        if !Path::new(dev).exists() {
            err(&format!(
                "WARNING: Device '{dev}' does not exist on the host — skipping."
            ));
            continue;
        }
        serial_devices.push((serial_devices.len(), dev.clone()));
        out(&format!("    (passing through device {dev})"));
    }
    if write_seed(l, &session_dir).is_err() {
        err("ERROR: could not write the seed file.");
        std::process::exit(1);
    }
    let mut lock_prefix: Vec<String> = Vec::new();
    if let Some(img) = &store_img {
        let lock = format!("{}.lock", path_str(img));
        if !flock_free(&lock) {
            err("ERROR: the docker store image is in use by another running session:");
            err(&format!("       {}", path_str(img)));
            err("       (single writer — stop the other session first)");
            std::process::exit(1);
        }
        lock_prefix = vec!["-n".into(), lock];
    }
    let console = session_dir.join("console.log");
    let argv = qemu_argv(&QemuPlan {
        accel: cfg.vm_accel.clone(),
        cpus: cfg.vm_cpus.clone(),
        mem: cfg.vm_mem.clone(),
        vmlinuz: path_str(&b.vmlinuz),
        initrd: b.initrd.is_file().then(|| path_str(&b.initrd)),
        overlay: path_str(&overlay),
        origin: origin.clone(),
        session_dir: path_str(&session_dir),
        store_img: store_img.as_ref().map(|p| path_str(p)),
        netdev_extra: format!("{hf}{netwall}"),
        serial_devices,
    });
    out(&format!(
        "==> Booting vm '{session}' (ssh on 127.0.0.1:{ssh_port}, {} vcpu / {} MiB) ...",
        cfg.vm_cpus, cfg.vm_mem
    ));
    let status = if lock_prefix.is_empty() {
        std::process::Command::new("qemu-system-x86_64")
            .args(&argv)
            .status()
    } else {
        std::process::Command::new("flock")
            .args(&lock_prefix)
            .arg("qemu-system-x86_64")
            .args(&argv)
            .status()
    };
    if !status.is_ok_and(|s| s.success()) {
        err(&format!(
            "ERROR: qemu failed to start. Check: {}",
            path_str(&console)
        ));
        if vm_live_pid_for(cfg, session).is_some() {
            err("       A qemu process for this session is already running —");
            err(&format!("       attach with: lbx --runtime vm {session}"));
        }
        std::process::exit(1);
    }
}

/// Wait for sshd's banner on the recorded port. False = error printed.
pub fn wait_ssh(cfg: &Resolved, session: &str, host_user: &str) -> bool {
    use std::io::Read;
    let session_dir = vm_sessions_dir(cfg).join(session);
    let port = std::fs::read_to_string(session_dir.join("ssh_port"))
        .map(|s| s.trim_end_matches('\n').to_string())
        .unwrap_or_default();
    if port.is_empty() {
        err(&format!(
            "ERROR: no ssh port recorded for session '{session}'."
        ));
        std::process::exit(1);
    }
    out("==> Waiting for the vm to boot and accept ssh (first boot ~20-90s) ...");
    let addr = format!("127.0.0.1:{port}");
    for _ in 0..240 {
        if let Ok(mut s) = std::net::TcpStream::connect_timeout(
            &addr
                .parse()
                .unwrap_or(std::net::SocketAddr::from(([127, 0, 0, 1], 0))),
            std::time::Duration::from_secs(3),
        ) {
            let _ = s.set_read_timeout(Some(std::time::Duration::from_secs(3)));
            let mut buf = [0u8; 24];
            if let Ok(n) = s.read(&mut buf)
                && String::from_utf8_lossy(&buf[..n]).starts_with("SSH-2.0-")
            {
                return true;
            }
        }
        if let Ok(pid) = std::fs::read_to_string(session_dir.join("qemu.pid"))
            && let Ok(p) = pid.trim().parse::<i32>()
        {
            // SAFETY: signal 0 only probes.
            if unsafe { libc::kill(p, 0) } != 0 {
                break;
            }
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    err("ERROR: vm did not accept ssh connections within 240s.");
    err(&format!(
        "       The vm is still running (check with: ssh -p {port} {host_user}@127.0.0.1)."
    ));
    false
}

/// Attach over ssh (replaces this process).
pub fn attach(cfg: &Resolved, session: &str, host_user: &str) -> i32 {
    use std::os::unix::process::CommandExt;
    let port = std::fs::read_to_string(vm_sessions_dir(cfg).join(session).join("ssh_port"))
        .map(|s| s.trim_end_matches('\n').to_string())
        .unwrap_or_default();
    if port.is_empty() {
        err(&format!(
            "ERROR: no ssh port recorded for session '{session}'."
        ));
        return 1;
    }
    out("");
    out("  Welcome to llm in a box... where agents are constrained");
    out("");
    let e = std::process::Command::new("ssh")
        .args([
            "-t",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-p",
            &port,
            &format!("{host_user}@127.0.0.1"),
            "cd /data 2>/dev/null || true; exec bash",
        ])
        .exec();
    err(&format!("ERROR: could not exec ssh: {e}"));
    1
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn sizes() {
        assert_eq!(size_bytes("500G"), Some(500 << 30));
        assert_eq!(size_bytes("64M"), Some(64 << 20));
        assert_eq!(size_bytes("1024"), Some(1024));
        assert_eq!(size_bytes("0G"), Some(0));
        assert_eq!(size_bytes("x"), None);
        assert_eq!(size_bytes(""), None);
    }

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("plain"), "plain");
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("k1\nk2"), "$'k1\\nk2'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
    }

    #[test]
    fn hostfwd_order_is_ssh_ports_web_publish() {
        assert_eq!(
            hostfwd_string(2222, (None, None), "", &[]),
            "hostfwd=tcp::2222-:22"
        );
        assert_eq!(
            hostfwd_string(
                2223,
                (Some(8080), Some(13000)),
                "9443:443",
                &v(&["5000:5000", "6001:6000"])
            ),
            "hostfwd=tcp::2223-:22,hostfwd=tcp::8080-:8080,hostfwd=tcp::13000-:3000,hostfwd=tcp::9443-:443,hostfwd=tcp::5000-:5000,hostfwd=tcp::6001-:6000"
        );
        assert_eq!(
            netwall_suffix("4400"),
            ",restrict=on,guestfwd=tcp:10.0.2.100:3128-tcp:127.0.0.1:4400"
        );
    }

    fn plan() -> QemuPlan {
        QemuPlan {
            accel: String::new(),
            cpus: "8".into(),
            mem: "16384".into(),
            vmlinuz: "/st/bases/b1/vmlinuz".into(),
            initrd: Some("/st/bases/b1/initrd.img".into()),
            overlay: "/st/sessions/s/overlay.qcow2".into(),
            origin: "/work/p".into(),
            session_dir: "/st/sessions/s".into(),
            store_img: Some("/work/p/vms_and_docker_from_llm_box/docker-store.img".into()),
            netdev_extra: "hostfwd=tcp::2222-:22".into(),
            serial_devices: vec![(0, "/dev/ttyUSB0".into())],
        }
    }

    /// One deliberate difference from the bash line: the store serial is
    /// `lbx-docker-store` (16 bytes); the bash's 25-byte serial exceeds the
    /// NVMe limit, so the guest saw `llm-in-a-box-docker-` and never mounted
    /// the store (verified on a real boot, 2026-10-15).
    #[test]
    fn qemu_vector_matches_the_bash_launch_line() {
        assert_eq!(
            qemu_argv(&plan()),
            v(&[
                "-enable-kvm",
                "-cpu",
                "host",
                "-smp",
                "8",
                "-m",
                "16384",
                "-machine",
                "q35",
                "-kernel",
                "/st/bases/b1/vmlinuz",
                "-initrd",
                "/st/bases/b1/initrd.img",
                "-append",
                "root=/dev/vda rw console=ttyS0 net.ifnames=0 biosdevname=0",
                "-drive",
                "file=/st/sessions/s/overlay.qcow2,if=virtio,format=qcow2",
                "-virtfs",
                "local,path=/work/p,mount_tag=host0,security_model=none",
                "-virtfs",
                "local,path=/st/sessions/s,mount_tag=seed0,security_model=none,readonly=on",
                "-drive",
                "file=/work/p/vms_and_docker_from_llm_box/docker-store.img,if=none,id=store0,format=raw,cache=writeback,discard=unmap",
                "-device",
                "nvme,drive=store0,serial=lbx-docker-store",
                "-netdev",
                "user,id=n0,hostfwd=tcp::2222-:22",
                "-device",
                "virtio-net-pci,netdev=n0",
                "-chardev",
                "serial,id=ser0,path=/dev/ttyUSB0",
                "-device",
                "isa-serial,chardev=ser0",
                "-fw_cfg",
                "name=opt/llm-in-a-box/seed,file=/st/sessions/s/seed.fw_cfg",
                "-monitor",
                "unix:/st/sessions/s/monitor.sock,server,nowait",
                "-serial",
                "file:/st/sessions/s/console.log",
                "-display",
                "none",
                "-no-reboot",
                "-daemonize",
                "-pidfile",
                "/st/sessions/s/qemu.pid",
            ])
        );
    }

    #[test]
    fn qemu_vector_tcg_no_store_no_initrd() {
        let mut p = plan();
        p.accel = "tcg".into();
        p.initrd = None;
        p.store_img = None;
        p.serial_devices.clear();
        let got = qemu_argv(&p);
        assert_eq!(got[0..4], v(&["-accel", "tcg,thread=multi", "-cpu", "max"]));
        assert!(!got.contains(&"-initrd".to_string()));
        assert!(!got.iter().any(|a| a.starts_with("nvme,")));
        assert!(!got.contains(&"-chardev".to_string()));
    }

    #[test]
    fn seed_text_plain_and_netwall() {
        let s = Seed {
            host_user: "dev".into(),
            host_uid: 1000,
            host_gid: 1000,
            hostname: "s".into(),
            gh_token: None,
            ssh_pubkeys: vec![],
            netwall: false,
        };
        assert_eq!(
            seed_text(&s),
            "HOST_USER=dev\nHOST_UID=1000\nHOST_GID=1000\nHOSTNAME=s\n"
        );
        let s = Seed {
            gh_token: Some("ghp_a b".into()),
            ssh_pubkeys: vec!["ssh-ed25519 AAAA dev@h".into(), "ssh-rsa BBBB".into()],
            netwall: true,
            ..s
        };
        assert_eq!(
            seed_text(&s),
            "HOST_USER=dev\nHOST_UID=1000\nHOST_GID=1000\nHOSTNAME=s\nGH_TOKEN='ghp_a b'\nSSH_PUBKEY=$'ssh-ed25519 AAAA dev@h\\nssh-rsa BBBB'\nHTTP_PROXY=http://10.0.2.100:3128\nHTTPS_PROXY=http://10.0.2.100:3128\nhttp_proxy=http://10.0.2.100:3128\nhttps_proxy=http://10.0.2.100:3128\nNO_PROXY=localhost,127.0.0.1,10.0.2.0/24\nno_proxy=localhost,127.0.0.1,10.0.2.0/24\nJAVA_TOOL_OPTIONS='-Dhttp.proxyHost=10.0.2.100 -Dhttp.proxyPort=3128 -Dhttps.proxyHost=10.0.2.100 -Dhttps.proxyPort=3128 -Dhttp.nonProxyHosts=localhost|127.0.0.1|10.0.2.*'\n"
        );
    }

    fn cfg(state: &Path) -> Resolved {
        Resolved {
            state: crate::config::ConfigState::Missing,
            error: String::new(),
            warnings: Vec::new(),
            path: state.join("config"),
            image_sysbox: "llm-in-a-box:sysbox".into(),
            image_docker: "llm-in-a-box:docker".into(),
            image_vm: "llm-in-a-box:vm".into(),
            state_dir: state.to_path_buf(),
            vm_mem: "16384".into(),
            vm_cpus: "8".into(),
            vm_accel: String::new(),
            vm_store_size: String::new(),
            vm_store_disable: String::new(),
            vm_missing: String::new(),
            runtime_default: String::new(),
        }
    }

    /// A session whose recorded origin is `project` (so no chdir is needed).
    fn session_with_origin(state: &Path, name: &str, project: &Path) {
        let sdir = state.join("sessions").join(name);
        std::fs::create_dir_all(&sdir).unwrap_or_else(|e| panic!("{e}"));
        std::fs::write(sdir.join("origin"), format!("{}\n", path_str(project)))
            .unwrap_or_else(|e| panic!("{e}"));
    }

    /// The store image: created once at the configured size with mode 0600
    /// at <project>/vms_and_docker_from_llm_box/docker-store.img, ignoring the
    /// state directory (vm suite L3, L3f, L4).
    #[test]
    fn store_image_is_created_at_the_project_path_with_the_configured_size() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let state = tmp.path().join("state");
        let project = tmp.path().join("proj");
        std::fs::create_dir_all(&project).unwrap_or_else(|e| panic!("{e}"));
        session_with_origin(&state, "s", &project);
        let mut c = cfg(&state);
        c.vm_store_size = "64M".into();
        let img = store_image_prepare(&c, "s").unwrap_or_else(|e| panic!("{e:?}"));
        let want = project.join("vms_and_docker_from_llm_box/docker-store.img");
        assert_eq!(img.as_deref(), Some(want.as_path()));
        let m = std::fs::metadata(&want).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(m.len(), 64 << 20);
        assert_eq!(m.permissions().mode() & 0o777, 0o600);
        // A second prepare reuses it (same size) and does not grow it.
        let again = store_image_prepare(&c, "s").unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(again, img);
        assert!(!state.join("vms_and_docker_from_llm_box").exists());
    }

    /// Zero-length, size-mismatched, symlink, directory, invalid and
    /// zero-byte sizes are refused before anything is created (L3b, L3c,
    /// L3e, L5, L5d); disabling the store skips it (L4b).
    #[test]
    fn store_image_refusals() {
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let state = tmp.path().join("state");
        let project = tmp.path().join("proj");
        let art = project.join("vms_and_docker_from_llm_box");
        std::fs::create_dir_all(&art).unwrap_or_else(|e| panic!("{e}"));
        session_with_origin(&state, "s", &project);
        let mut c = cfg(&state);
        c.vm_store_size = "64M".into();
        let img = art.join("docker-store.img");
        std::fs::write(&img, "").unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(store_image_prepare(&c, "s"), Err(Printed), "zero-length");
        std::fs::write(&img, "x").unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(store_image_prepare(&c, "s"), Err(Printed), "size mismatch");
        std::fs::remove_file(&img).unwrap_or_else(|e| panic!("{e}"));
        std::os::unix::fs::symlink("/dev/null", &img).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(store_image_prepare(&c, "s"), Err(Printed), "symlink");
        std::fs::remove_file(&img).unwrap_or_else(|e| panic!("{e}"));
        std::fs::create_dir(&img).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(store_image_prepare(&c, "s"), Err(Printed), "directory");
        std::fs::remove_dir(&img).unwrap_or_else(|e| panic!("{e}"));
        c.vm_store_size = "lots".into();
        assert_eq!(store_image_prepare(&c, "s"), Err(Printed), "invalid size");
        c.vm_store_size = "0G".into();
        assert_eq!(store_image_prepare(&c, "s"), Err(Printed), "zero bytes");
        assert!(!img.exists(), "nothing created by a refusal");
        c.vm_store_size = "64M".into();
        c.vm_store_disable = "1".into();
        assert_eq!(store_image_prepare(&c, "s"), Ok(None), "disabled");
        assert!(!img.exists());
        // The artifact directory itself as a symlink is refused (L5d).
        std::fs::remove_dir(&art).unwrap_or_else(|e| panic!("{e}"));
        std::os::unix::fs::symlink(tmp.path(), &art).unwrap_or_else(|e| panic!("{e}"));
        c.vm_store_disable = String::new();
        assert_eq!(
            store_image_prepare(&c, "s"),
            Err(Printed),
            "artifact dir symlink"
        );
    }

    /// A second writer is refused while the lock is held (L6).
    #[test]
    fn store_image_lock_refuses_a_second_writer() {
        use std::os::unix::io::AsRawFd;
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let state = tmp.path().join("state");
        let project = tmp.path().join("proj");
        std::fs::create_dir_all(&project).unwrap_or_else(|e| panic!("{e}"));
        session_with_origin(&state, "s", &project);
        let mut c = cfg(&state);
        c.vm_store_size = "1M".into();
        let img = store_image_prepare(&c, "s")
            .unwrap_or_else(|e| panic!("{e:?}"))
            .unwrap_or_default();
        let lock = std::fs::File::create(format!("{}.lock", path_str(&img)))
            .unwrap_or_else(|e| panic!("{e}"));
        // SAFETY: flock on an open descriptor this test owns.
        assert_eq!(
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        assert_eq!(
            store_image_prepare(&c, "s"),
            Err(Printed),
            "locked by another writer"
        );
        drop(lock);
        assert!(store_image_prepare(&c, "s").is_ok());
    }

    /// Two project directories get two independent images (L6b).
    #[test]
    fn store_images_are_per_project() {
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let state = tmp.path().join("state");
        let mut c = cfg(&state);
        c.vm_store_size = "1M".into();
        for (s, p) in [("a", "pa"), ("b", "pb")] {
            let project = tmp.path().join(p);
            std::fs::create_dir_all(&project).unwrap_or_else(|e| panic!("{e}"));
            session_with_origin(&state, s, &project);
            let img = store_image_prepare(&c, s).unwrap_or_else(|e| panic!("{e:?}"));
            assert_eq!(
                img,
                Some(project.join("vms_and_docker_from_llm_box/docker-store.img"))
            );
        }
    }

    /// The first-reader README takes the umask (as `cp` did), never the
    /// shipped file's own mode.
    #[test]
    fn state_message_takes_the_umask_not_the_source_mode() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let state = tmp.path().join("state");
        let c = cfg(&state);
        let project = tmp.path().join("p");
        std::fs::create_dir_all(&project).unwrap_or_else(|e| panic!("{e}"));
        session_with_origin(&state, "s", &project);
        let script_dir = tmp.path().join("ship");
        std::fs::create_dir_all(script_dir.join("docker")).unwrap_or_else(|e| panic!("{e}"));
        let src = script_dir.join("docker/state-dir-message.md");
        std::fs::write(&src, "note\n").unwrap_or_else(|e| panic!("{e}"));
        std::fs::set_permissions(&src, std::fs::Permissions::from_mode(0o777))
            .unwrap_or_else(|e| panic!("{e}"));
        ensure_state_message(&c, "s", &script_dir);
        let readme = project.join("vms_and_docker_from_llm_box/README.md");
        let mode = std::fs::metadata(&readme)
            .unwrap_or_else(|e| panic!("{e}"))
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(
            std::fs::read_to_string(&readme).unwrap_or_default(),
            "note\n"
        );
        assert_eq!(mode & 0o111, 0, "mode {mode:o} inherited the source");
    }

    /// Base resolution: the session record wins, then bases/latest, then the
    /// legacy flat layout (L10 and the ADR 013 migration messages).
    #[test]
    fn base_resolution_order() {
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let state = tmp.path().join("state");
        let c = cfg(&state);
        let bases = state.join("bases");
        for b in ["ts1", "ts2"] {
            std::fs::create_dir_all(bases.join(b)).unwrap_or_else(|e| panic!("{e}"));
            std::fs::write(bases.join(b).join("base.qcow2"), "q").unwrap_or_else(|e| panic!("{e}"));
            std::fs::write(bases.join(b).join("vmlinuz"), "k").unwrap_or_else(|e| panic!("{e}"));
        }
        std::os::unix::fs::symlink("ts2", bases.join("latest")).unwrap_or_else(|e| panic!("{e}"));
        std::fs::write(state.join("base.qcow2"), "legacy").unwrap_or_else(|e| panic!("{e}"));
        std::fs::write(state.join("vmlinuz"), "legacy").unwrap_or_else(|e| panic!("{e}"));
        // No record: latest.
        let b = resolve_base(&c, "new").unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(b.base, bases.join("ts2/base.qcow2"));
        assert_eq!(b.vmlinuz, bases.join("ts2/vmlinuz"));
        assert_eq!(b.initrd, bases.join("ts2/initrd.img"));
        // A record wins over latest.
        std::fs::create_dir_all(state.join("sessions/old")).unwrap_or_else(|e| panic!("{e}"));
        std::fs::write(state.join("sessions/old/base"), "ts1\n").unwrap_or_else(|e| panic!("{e}"));
        let b = resolve_base(&c, "old").unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(b.base, bases.join("ts1/base.qcow2"));
        // A record of a base that no longer exists is an error.
        std::fs::write(state.join("sessions/old/base"), "gone\n").unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(resolve_base(&c, "old").err(), Some(Printed));
        // Without any versioned base the legacy flat layout is used.
        std::fs::remove_dir_all(&bases).unwrap_or_else(|e| panic!("{e}"));
        let b = resolve_base(&c, "new").unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(b.base, state.join("base.qcow2"));
        assert!(crate::session::vm_built(&c));
    }
}
