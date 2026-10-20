//! Files the launcher ships: the three net policies and the first-reader
//! note for the vm artifact directory. They are embedded so a release
//! binary works without a checkout; a copy next to the launcher (the
//! `LBX_SCRIPT_DIR` seam, else the executable's directory) wins.

pub const POLICY_NAMES: [&str; 3] = ["open", "enforce", "locked"];

pub fn policy(name: &str) -> Option<&'static str> {
    Some(match name {
        "open" => include_str!("../net-policies/open.json"),
        "enforce" => include_str!("../net-policies/enforce.json"),
        "locked" => include_str!("../net-policies/locked.json"),
        _ => return None,
    })
}

pub const STATE_DIR_MESSAGE: &str = include_str!("../docker/state-dir-message.md");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shipped_policies_are_valid_json_with_their_mode() {
        for name in POLICY_NAMES {
            let text = policy(name).unwrap_or("");
            let v: serde_json::Value =
                serde_json::from_str(text).unwrap_or(serde_json::Value::Null);
            assert_eq!(v.get("mode").and_then(|m| m.as_str()), Some(name));
        }
        assert_eq!(policy("other"), None);
    }
}
