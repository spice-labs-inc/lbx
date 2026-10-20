//! The docker client: every call the launcher makes, and the argument
//! vectors it builds (pure functions, so a test can compare whole vectors).

use std::process::{Command, Stdio};

/// Run `docker <args>` with output captured; `None` when docker is not on
/// PATH or could not be started.
pub struct Docker;

pub struct Output {
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
}

impl Docker {
    pub fn available() -> bool {
        crate::util::which("docker").is_some()
    }

    pub fn run(args: &[&str]) -> Output {
        Self::run_owned(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    pub fn run_owned(args: &[String]) -> Output {
        match Command::new("docker")
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
        {
            Ok(o) => Output {
                ok: o.status.success(),
                stdout: String::from_utf8_lossy(&o.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
            },
            Err(e) => Output {
                ok: false,
                stdout: String::new(),
                stderr: e.to_string(),
            },
        }
    }

    /// Like `run` but the call's output is discarded (`>/dev/null 2>&1`).
    pub fn quiet(args: &[&str]) -> bool {
        Self::run(args).ok
    }

    pub fn quiet_owned(args: &[String]) -> bool {
        Self::run_owned(args).ok
    }

    /// First line of stdout, trailing newline trimmed, or `None` on failure.
    pub fn line(args: &[&str]) -> Option<String> {
        let o = Self::run(args);
        if !o.ok {
            return None;
        }
        Some(o.stdout.trim_end_matches('\n').to_string())
    }

    pub fn image_exists(image: &str) -> bool {
        Self::available() && Self::quiet(&["image", "inspect", image])
    }

    pub fn has_runtime(name: &str) -> bool {
        Self::available()
            && Self::line(&["info", "--format", "{{json .Runtimes}}"])
                .is_some_and(|s| s.contains(name))
    }

    pub fn container_exists(name: &str) -> bool {
        Self::quiet(&["container", "inspect", name])
    }

    pub fn container_fmt(name: &str, fmt: &str) -> Option<String> {
        Self::line(&["container", "inspect", "-f", fmt, name])
    }

    pub fn container_label(name: &str, label: &str) -> String {
        Self::container_fmt(name, &format!("{{{{index .Config.Labels \"{label}\"}}}}"))
            .unwrap_or_default()
    }

    /// The volumes a container mounts at /var/lib/docker (its inner-docker
    /// storage), by name. The launcher names that volume after the session,
    /// but a migrated box keeps the volume of the replacement it was built
    /// from, so the mount table is the reliable source, not the name.
    pub fn store_volumes(name: &str) -> Vec<String> {
        Self::container_fmt(
            name,
            "{{range .Mounts}}{{if eq .Destination \"/var/lib/docker\"}}{{println .Name}}{{end}}{{end}}",
        )
        .map(|s| {
            s.lines()
                .filter(|l| !l.is_empty())
                .map(|l| l.to_string())
                .collect()
        })
        .unwrap_or_default()
    }

    pub fn ps_names() -> Vec<String> {
        Self::line(&["ps", "-a", "--format", "{{.Names}}"])
            .map(|s| s.lines().map(|l| l.to_string()).collect())
            .unwrap_or_default()
    }

    /// `docker inspect -f '{{.State.Status}}' <name>`
    pub fn state(name: &str) -> Option<String> {
        Self::line(&["inspect", "-f", "{{.State.Status}}", name])
    }
}

/// The box-user era stamp: the image's configured user, `agent` when the
/// image does not say.
pub fn box_user(image: &str) -> String {
    let user = Docker::line(&["image", "inspect", "--format", "{{.Config.User}}", image])
        .map(|s| s.lines().next().unwrap_or("").to_string())
        .unwrap_or_default();
    if user.is_empty() {
        "agent".to_string()
    } else {
        user
    }
}

pub fn relay_container_name(s: &str) -> String {
    format!("llm-in-a-box-relay-{s}")
}
pub fn relay_network_name(s: &str) -> String {
    format!("llm-in-a-box-net-{s}")
}
pub fn relay_egress_network_name(s: &str) -> String {
    format!("llm-in-a-box-relaynet-{s}")
}

/// Everything the interactive `docker run -d` needs.
#[derive(Debug, Clone, Default)]
pub struct InteractiveRun {
    pub runtime: String,
    pub session: String,
    pub image: String,
    pub box_user: String,
    pub host_user: String,
    pub host_uid: u32,
    pub host_gid: u32,
    pub gh_token: Option<String>,
    pub vm_web_port: String,
    pub netwall: Option<Netwall>,
    pub devices: Vec<String>,
    pub ports: Vec<String>,
    pub data_dir: String,
}

#[derive(Debug, Clone, Default)]
pub struct Netwall {
    pub relay_name: String,
    pub net_name: String,
    pub policy: String,
}

pub fn interactive_run_argv(r: &InteractiveRun) -> Vec<String> {
    let mut v: Vec<String> = vec!["run".into(), "-d".into()];
    match r.runtime.as_str() {
        "sysbox" => v.push("--runtime=sysbox-runc".into()),
        "docker" => v.push("--privileged".into()),
        _ => {}
    }
    v.extend([
        "--name".to_string(),
        r.session.clone(),
        "--hostname".into(),
        r.session.clone(),
        "--label".into(),
        format!("llm-in-a-box.runtime={}", r.runtime),
        "--label".into(),
        format!("llm-in-a-box.user={}", r.box_user),
        "-e".into(),
        format!("HOST_USER={}", r.host_user),
        "-e".into(),
        format!("HOST_UID={}", r.host_uid),
        "-e".into(),
        format!("HOST_GID={}", r.host_gid),
    ]);
    if let Some(t) = &r.gh_token {
        v.push("-e".into());
        v.push(format!("GH_TOKEN={t}"));
    }
    if !r.vm_web_port.is_empty() {
        v.push("-e".into());
        v.push(format!("VM_WEB_PORT={}", r.vm_web_port));
    }
    if let Some(n) = &r.netwall {
        let p = format!("http://{}:3128", n.relay_name);
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            v.push("-e".into());
            v.push(format!("{name}={p}"));
        }
        v.push("-e".into());
        v.push("NO_PROXY=localhost,127.0.0.1".into());
        v.push("-e".into());
        v.push("no_proxy=localhost,127.0.0.1".into());
        v.push("-e".into());
        v.push(format!(
            "JAVA_TOOL_OPTIONS=-Dhttp.proxyHost={r} -Dhttp.proxyPort=3128 -Dhttps.proxyHost={r} -Dhttps.proxyPort=3128 -Dhttp.nonProxyHosts=localhost|127.0.0.1",
            r = n.relay_name
        ));
    }
    for d in &r.devices {
        v.push("--device".into());
        v.push(d.clone());
    }
    if r.runtime == "sysbox" {
        v.push("--device".into());
        v.push("/dev/net/tun".into());
        v.push("--cap-add".into());
        v.push("NET_ADMIN".into());
    }
    for p in &r.ports {
        v.push("-p".into());
        v.push(p.clone());
    }
    if let Some(n) = &r.netwall {
        v.push("--network".into());
        v.push(n.net_name.clone());
        v.push("--label".into());
        v.push(format!("llm-in-a-box.net-policy={}", n.policy));
    }
    v.push("-v".into());
    v.push(format!("{}:/data", r.data_dir));
    // The session's inner-docker storage: a volume, so the inner daemon has
    // a filesystem of its own instead of the container's overlay.
    v.push("-v".into());
    v.push(format!("{}-docker:/var/lib/docker", r.session));
    v.push(r.image.clone());
    v
}

/// The interactive relay `docker run -d`.
pub fn interactive_relay_argv(
    relay_name: &str,
    uid: u32,
    gid: u32,
    policy: &str,
    netlogs: &str,
    net_name: &str,
    relaynet_name: &str,
) -> Vec<String> {
    vec![
        "run".into(),
        "-d".into(),
        "--name".into(),
        relay_name.into(),
        "--user".into(),
        format!("{uid}:{gid}"),
        "-e".into(),
        "LLMBOX_POLICY=/policy.json".into(),
        "-e".into(),
        "LLMBOX_DENY_LOG=/log/deny.log".into(),
        "-v".into(),
        format!("{policy}:/policy.json:ro"),
        "-v".into(),
        format!("{netlogs}:/log"),
        "--network".into(),
        net_name.into(),
        "--network".into(),
        relaynet_name.into(),
        "llm-in-a-box-relay:latest".into(),
    ]
}

pub const RUN_CLIENT_PROXY_VARS: [&str; 10] = [
    "HTTP_PROXY",
    "http_proxy",
    "HTTPS_PROXY",
    "https_proxy",
    "NO_PROXY",
    "no_proxy",
    "FTP_PROXY",
    "ftp_proxy",
    "ALL_PROXY",
    "all_proxy",
];
pub const RUN_CAPS: [&str; 4] = ["CHOWN", "DAC_OVERRIDE", "SETGID", "SETUID"];
pub const RUN_RELAY_IMAGE: &str = "llm-in-a-box-relay:latest";

/// The unattended run's relay.
#[derive(Debug, Clone, Default)]
pub struct RunRelay {
    pub relay: String,
    pub run_id: String,
    pub uid: u32,
    pub gid: u32,
    pub policy_abs: String,
    pub netlogs: String,
    pub net: String,
    pub egress: String,
}

pub fn run_relay_argv(r: &RunRelay) -> Vec<String> {
    let RunRelay {
        relay,
        run_id,
        uid,
        gid,
        policy_abs,
        netlogs,
        net,
        egress,
    } = r;
    let mut v: Vec<String> = vec![
        "run".into(),
        "-d".into(),
        "--pull".into(),
        "never".into(),
        "--name".into(),
        relay.into(),
        "--label".into(),
        format!("llm-in-a-box.run-id={run_id}"),
        "--user".into(),
        format!("{uid}:{gid}"),
        "--cap-drop".into(),
        "ALL".into(),
        "--security-opt".into(),
        "no-new-privileges".into(),
        "--read-only".into(),
        "--tmpfs".into(),
        "/tmp".into(),
        "-e".into(),
        "LLMBOX_POLICY=/policy.json".into(),
        "-e".into(),
        "LLMBOX_DENY_LOG=/log/deny.log".into(),
    ];
    for var in RUN_CLIENT_PROXY_VARS {
        v.push("-e".into());
        v.push(format!("{var}="));
    }
    v.extend([
        "-v".to_string(),
        format!("{policy_abs}:/policy.json:ro"),
        "-v".into(),
        format!("{netlogs}:/log"),
        "--network".into(),
        net.into(),
        "--network".into(),
        egress.into(),
        RUN_RELAY_IMAGE.into(),
    ]);
    v
}

/// Everything the run box's `docker run -d` needs.
#[derive(Debug, Clone, Default)]
pub struct RunBox {
    pub name: String,
    pub run_id: String,
    pub box_user: String,
    pub apparmor_profile: String,
    pub host_user: String,
    pub host_uid: u32,
    pub host_gid: u32,
    /// `-e` pairs for the proxies (relay) or the ten empty variables.
    pub proxy_env: Vec<String>,
    /// `--network <net>` or `--network none`.
    pub net_args: Vec<String>,
    pub data_abs: String,
    pub socket_abs: String,
    pub image: String,
    pub lifetime: u64,
}

pub fn run_box_argv(b: &RunBox) -> Vec<String> {
    let mut v: Vec<String> = vec![
        "run".into(),
        "-d".into(),
        "--rm".into(),
        "--pull".into(),
        "never".into(),
        "--name".into(),
        b.name.clone(),
        "--label".into(),
        format!("llm-in-a-box.run-id={}", b.run_id),
        "--label".into(),
        "llm-in-a-box.runtime=docker".into(),
        "--label".into(),
        format!("llm-in-a-box.user={}", b.box_user),
        "--label".into(),
        "llm-in-a-box.mode=run".into(),
        "--cap-drop".into(),
        "ALL".into(),
    ];
    for cap in RUN_CAPS {
        v.push("--cap-add".into());
        v.push(cap.into());
    }
    v.push("--security-opt".into());
    v.push("no-new-privileges".into());
    if !b.apparmor_profile.is_empty() {
        v.push("--security-opt".into());
        v.push(format!("apparmor={}", b.apparmor_profile));
    }
    v.extend([
        "--dns".to_string(),
        "127.0.0.1".into(),
        "--sysctl".into(),
        "net.ipv6.conf.all.disable_ipv6=1".into(),
        "-e".into(),
        format!("HOST_USER={}", b.host_user),
        "-e".into(),
        format!("HOST_UID={}", b.host_uid),
        "-e".into(),
        format!("HOST_GID={}", b.host_gid),
        // The entrypoint also honors the older LLMBOX_NO_INNER_DOCKER spelling.
        "-e".into(),
        "LBX_NO_INNER_DOCKER=1".into(),
    ]);
    v.extend(b.proxy_env.iter().cloned());
    v.extend(b.net_args.iter().cloned());
    v.push("-v".into());
    v.push(format!("{}:/data", b.data_abs));
    if !b.socket_abs.is_empty() {
        v.push("--mount".into());
        v.push(format!(
            "type=bind,source={},target=/run/agent,readonly",
            b.socket_abs
        ));
    }
    v.push(b.image.clone());
    v.push("sleep".into());
    v.push(b.lifetime.to_string());
    v
}

/// The proxy environment for a run box behind the relay.
pub fn run_proxy_env(relay_ip: &str) -> Vec<String> {
    let proxy = format!("http://{relay_ip}:3128");
    let mut v = Vec::new();
    for name in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
        v.push("-e".to_string());
        v.push(format!("{name}={proxy}"));
    }
    for name in ["NO_PROXY", "no_proxy"] {
        v.push("-e".to_string());
        v.push(format!("{name}=localhost,127.0.0.1"));
    }
    for name in ["FTP_PROXY", "ftp_proxy", "ALL_PROXY", "all_proxy"] {
        v.push("-e".to_string());
        v.push(format!("{name}="));
    }
    v.push("-e".to_string());
    v.push(format!(
        "JAVA_TOOL_OPTIONS=-Dhttp.proxyHost={relay_ip} -Dhttp.proxyPort=3128 -Dhttps.proxyHost={relay_ip} -Dhttps.proxyPort=3128 -Dhttp.nonProxyHosts=localhost|127.0.0.1"
    ));
    v
}

/// The ten proxy variables set empty (no-network run box, relay).
pub fn empty_proxy_env() -> Vec<String> {
    let mut v = Vec::new();
    for var in RUN_CLIENT_PROXY_VARS {
        v.push("-e".to_string());
        v.push(format!("{var}="));
    }
    v
}

/// `docker exec -i -w /data [-e NAME]... <name> gosu <user> <cmd...>`
pub fn run_exec_argv(name: &str, envs: &[String], host_user: &str, cmd: &[String]) -> Vec<String> {
    let mut v: Vec<String> = vec!["exec".into(), "-i".into(), "-w".into(), "/data".into()];
    for e in envs {
        v.push("-e".into());
        v.push(e.clone());
    }
    v.push(name.into());
    v.push("gosu".into());
    v.push(host_user.into());
    v.extend(cmd.iter().cloned());
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn interactive_docker_box_plain() {
        let r = InteractiveRun {
            runtime: "docker".into(),
            session: "s1".into(),
            image: "llm-in-a-box:docker".into(),
            box_user: "agent".into(),
            host_user: "dev".into(),
            host_uid: 1000,
            host_gid: 1000,
            data_dir: "/work/proj".into(),
            ..Default::default()
        };
        assert_eq!(
            interactive_run_argv(&r),
            v(&[
                "run",
                "-d",
                "--privileged",
                "--name",
                "s1",
                "--hostname",
                "s1",
                "--label",
                "llm-in-a-box.runtime=docker",
                "--label",
                "llm-in-a-box.user=agent",
                "-e",
                "HOST_USER=dev",
                "-e",
                "HOST_UID=1000",
                "-e",
                "HOST_GID=1000",
                "-v",
                "/work/proj:/data",
                "-v",
                "s1-docker:/var/lib/docker",
                "llm-in-a-box:docker",
            ])
        );
    }

    #[test]
    fn interactive_sysbox_box_with_everything() {
        let r = InteractiveRun {
            runtime: "sysbox".into(),
            session: "s2".into(),
            image: "llm-in-a-box:sysbox".into(),
            box_user: "agent".into(),
            host_user: "dev".into(),
            host_uid: 1001,
            host_gid: 1002,
            gh_token: Some("ghp_x".into()),
            vm_web_port: "8443:443".into(),
            netwall: Some(Netwall {
                relay_name: "llm-in-a-box-relay-s2".into(),
                net_name: "llm-in-a-box-net-s2".into(),
                policy: "/p/enforce.json".into(),
            }),
            devices: v(&["/dev/ttyUSB0"]),
            ports: v(&["8443:8443", "18080:8080"]),
            data_dir: "/work/p".into(),
        };
        assert_eq!(
            interactive_run_argv(&r),
            v(&[
                "run",
                "-d",
                "--runtime=sysbox-runc",
                "--name",
                "s2",
                "--hostname",
                "s2",
                "--label",
                "llm-in-a-box.runtime=sysbox",
                "--label",
                "llm-in-a-box.user=agent",
                "-e",
                "HOST_USER=dev",
                "-e",
                "HOST_UID=1001",
                "-e",
                "HOST_GID=1002",
                "-e",
                "GH_TOKEN=ghp_x",
                "-e",
                "VM_WEB_PORT=8443:443",
                "-e",
                "HTTP_PROXY=http://llm-in-a-box-relay-s2:3128",
                "-e",
                "HTTPS_PROXY=http://llm-in-a-box-relay-s2:3128",
                "-e",
                "http_proxy=http://llm-in-a-box-relay-s2:3128",
                "-e",
                "https_proxy=http://llm-in-a-box-relay-s2:3128",
                "-e",
                "NO_PROXY=localhost,127.0.0.1",
                "-e",
                "no_proxy=localhost,127.0.0.1",
                "-e",
                "JAVA_TOOL_OPTIONS=-Dhttp.proxyHost=llm-in-a-box-relay-s2 -Dhttp.proxyPort=3128 -Dhttps.proxyHost=llm-in-a-box-relay-s2 -Dhttps.proxyPort=3128 -Dhttp.nonProxyHosts=localhost|127.0.0.1",
                "--device",
                "/dev/ttyUSB0",
                "--device",
                "/dev/net/tun",
                "--cap-add",
                "NET_ADMIN",
                "-p",
                "8443:8443",
                "-p",
                "18080:8080",
                "--network",
                "llm-in-a-box-net-s2",
                "--label",
                "llm-in-a-box.net-policy=/p/enforce.json",
                "-v",
                "/work/p:/data",
                "-v",
                "s2-docker:/var/lib/docker",
                "llm-in-a-box:sysbox",
            ])
        );
    }

    #[test]
    fn interactive_relay_vector() {
        assert_eq!(
            interactive_relay_argv(
                "llm-in-a-box-relay-s",
                1000,
                1000,
                "/p/e.json",
                "/st/netlogs/s",
                "llm-in-a-box-net-s",
                "llm-in-a-box-relaynet-s"
            ),
            v(&[
                "run",
                "-d",
                "--name",
                "llm-in-a-box-relay-s",
                "--user",
                "1000:1000",
                "-e",
                "LLMBOX_POLICY=/policy.json",
                "-e",
                "LLMBOX_DENY_LOG=/log/deny.log",
                "-v",
                "/p/e.json:/policy.json:ro",
                "-v",
                "/st/netlogs/s:/log",
                "--network",
                "llm-in-a-box-net-s",
                "--network",
                "llm-in-a-box-relaynet-s",
                "llm-in-a-box-relay:latest",
            ])
        );
    }

    #[test]
    fn run_relay_vector() {
        let r = RunRelay {
            relay: "llm-in-a-box-relay-j".into(),
            run_id: "0123456789abcdef0123456789abcdef".into(),
            uid: 1000,
            gid: 1000,
            policy_abs: "/p/enforce.json".into(),
            netlogs: "/st/netlogs/j".into(),
            net: "llm-in-a-box-net-j".into(),
            egress: "llm-in-a-box-relaynet-j".into(),
        };
        assert_eq!(
            run_relay_argv(&r),
            v(&[
                "run",
                "-d",
                "--pull",
                "never",
                "--name",
                "llm-in-a-box-relay-j",
                "--label",
                "llm-in-a-box.run-id=0123456789abcdef0123456789abcdef",
                "--user",
                "1000:1000",
                "--cap-drop",
                "ALL",
                "--security-opt",
                "no-new-privileges",
                "--read-only",
                "--tmpfs",
                "/tmp",
                "-e",
                "LLMBOX_POLICY=/policy.json",
                "-e",
                "LLMBOX_DENY_LOG=/log/deny.log",
                "-e",
                "HTTP_PROXY=",
                "-e",
                "http_proxy=",
                "-e",
                "HTTPS_PROXY=",
                "-e",
                "https_proxy=",
                "-e",
                "NO_PROXY=",
                "-e",
                "no_proxy=",
                "-e",
                "FTP_PROXY=",
                "-e",
                "ftp_proxy=",
                "-e",
                "ALL_PROXY=",
                "-e",
                "all_proxy=",
                "-v",
                "/p/enforce.json:/policy.json:ro",
                "-v",
                "/st/netlogs/j:/log",
                "--network",
                "llm-in-a-box-net-j",
                "--network",
                "llm-in-a-box-relaynet-j",
                "llm-in-a-box-relay:latest",
            ])
        );
    }

    fn run_box(no_network: bool, apparmor: &str, socket: &str) -> RunBox {
        RunBox {
            name: "job".into(),
            run_id: "ab".repeat(16),
            box_user: "agent".into(),
            apparmor_profile: apparmor.into(),
            host_user: "u".into(),
            host_uid: 1000,
            host_gid: 1000,
            proxy_env: if no_network {
                empty_proxy_env()
            } else {
                run_proxy_env("172.18.0.2")
            },
            net_args: if no_network {
                v(&["--network", "none"])
            } else {
                v(&["--network", "llm-in-a-box-net-job"])
            },
            data_abs: "/srv/d".into(),
            socket_abs: socket.into(),
            image: "llm-in-a-box:docker".into(),
            lifetime: 150,
        }
    }

    #[test]
    fn run_box_no_network_vector() {
        assert_eq!(
            run_box_argv(&run_box(true, "", "/srv/s")),
            v(&[
                "run",
                "-d",
                "--rm",
                "--pull",
                "never",
                "--name",
                "job",
                "--label",
                "llm-in-a-box.run-id=abababababababababababababababab",
                "--label",
                "llm-in-a-box.runtime=docker",
                "--label",
                "llm-in-a-box.user=agent",
                "--label",
                "llm-in-a-box.mode=run",
                "--cap-drop",
                "ALL",
                "--cap-add",
                "CHOWN",
                "--cap-add",
                "DAC_OVERRIDE",
                "--cap-add",
                "SETGID",
                "--cap-add",
                "SETUID",
                "--security-opt",
                "no-new-privileges",
                "--dns",
                "127.0.0.1",
                "--sysctl",
                "net.ipv6.conf.all.disable_ipv6=1",
                "-e",
                "HOST_USER=u",
                "-e",
                "HOST_UID=1000",
                "-e",
                "HOST_GID=1000",
                "-e",
                "LBX_NO_INNER_DOCKER=1",
                "-e",
                "HTTP_PROXY=",
                "-e",
                "http_proxy=",
                "-e",
                "HTTPS_PROXY=",
                "-e",
                "https_proxy=",
                "-e",
                "NO_PROXY=",
                "-e",
                "no_proxy=",
                "-e",
                "FTP_PROXY=",
                "-e",
                "ftp_proxy=",
                "-e",
                "ALL_PROXY=",
                "-e",
                "all_proxy=",
                "--network",
                "none",
                "-v",
                "/srv/d:/data",
                "--mount",
                "type=bind,source=/srv/s,target=/run/agent,readonly",
                "llm-in-a-box:docker",
                "sleep",
                "150",
            ])
        );
    }

    #[test]
    fn run_box_relay_and_apparmor_vector() {
        let got = run_box_argv(&run_box(false, "llm-in-a-box-run", ""));
        let expected_tail = v(&[
            "-e",
            "HOST_USER=u",
            "-e",
            "HOST_UID=1000",
            "-e",
            "HOST_GID=1000",
            "-e",
            "LBX_NO_INNER_DOCKER=1",
            "-e",
            "HTTP_PROXY=http://172.18.0.2:3128",
            "-e",
            "HTTPS_PROXY=http://172.18.0.2:3128",
            "-e",
            "http_proxy=http://172.18.0.2:3128",
            "-e",
            "https_proxy=http://172.18.0.2:3128",
            "-e",
            "NO_PROXY=localhost,127.0.0.1",
            "-e",
            "no_proxy=localhost,127.0.0.1",
            "-e",
            "FTP_PROXY=",
            "-e",
            "ftp_proxy=",
            "-e",
            "ALL_PROXY=",
            "-e",
            "all_proxy=",
            "-e",
            "JAVA_TOOL_OPTIONS=-Dhttp.proxyHost=172.18.0.2 -Dhttp.proxyPort=3128 -Dhttps.proxyHost=172.18.0.2 -Dhttps.proxyPort=3128 -Dhttp.nonProxyHosts=localhost|127.0.0.1",
            "--network",
            "llm-in-a-box-net-job",
            "-v",
            "/srv/d:/data",
            "llm-in-a-box:docker",
            "sleep",
            "150",
        ]);
        assert!(got.ends_with(&expected_tail), "{got:?}");
        let sec: Vec<&String> = got
            .windows(2)
            .filter(|w| w[0] == "--security-opt")
            .map(|w| &w[1])
            .collect();
        assert_eq!(sec, ["no-new-privileges", "apparmor=llm-in-a-box-run"]);
        assert_eq!(got.iter().filter(|a| *a == "--mount").count(), 0);
    }

    #[test]
    fn exec_vector_keeps_the_command_verbatim() {
        let cmd = v(&["sh", "-c", "echo --rm; exit 3", "--", "-x"]);
        assert_eq!(
            run_exec_argv("job", &v(&["TOKEN", "OTHER"]), "u", &cmd),
            v(&[
                "exec",
                "-i",
                "-w",
                "/data",
                "-e",
                "TOKEN",
                "-e",
                "OTHER",
                "job",
                "gosu",
                "u",
                "sh",
                "-c",
                "echo --rm; exit 3",
                "--",
                "-x"
            ])
        );
    }

    #[test]
    fn names() {
        assert_eq!(relay_container_name("a"), "llm-in-a-box-relay-a");
        assert_eq!(relay_network_name("a"), "llm-in-a-box-net-a");
        assert_eq!(relay_egress_network_name("a"), "llm-in-a-box-relaynet-a");
        assert_eq!(empty_proxy_env().len(), 20);
    }
}
