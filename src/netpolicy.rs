//! Netwall policy files: `{mode: open|enforce|locked, allow: [...], block:
//! [...], idle_timeout_seconds?: 30..=3600}`. The bash validates with an
//! inline python; the messages here follow its wording.

use serde_json::Value;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Policy {
    pub mode: String,
}

/// Validate the file. `Err` carries the text after "invalid net policy
/// file: " (empty for the four shape checks, like the python's bare raises).
pub fn validate(path: &Path) -> Result<Policy, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{e}"))?;
    let v: Value = serde_json::from_slice(&bytes).map_err(|e| format!("{e}"))?;
    let Value::Object(map) = &v else {
        return Err(String::new());
    };
    let mode = match map.get("mode") {
        Some(Value::String(m)) if matches!(m.as_str(), "open" | "enforce" | "locked") => m.clone(),
        _ => return Err(String::new()),
    };
    if let Some(a) = map.get("allow")
        && !a.is_array()
    {
        return Err(String::new());
    }
    if let Some(b) = map.get("block")
        && !b.is_array()
    {
        return Err(String::new());
    }
    if let Some(t) = map.get("idle_timeout_seconds") {
        let ok = match t {
            Value::Number(n) => n.as_i64().is_some_and(|i| (30..=3600).contains(&i)),
            _ => false,
        };
        if !ok {
            return Err(format!(
                "idle_timeout_seconds must be a whole number from 30 to 3600 (got {t})"
            ));
        }
    }
    Ok(Policy { mode })
}

/// Just the mode, for `--run`'s check (an unparsable file is `None`).
pub fn mode_of(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    Some(
        v.get("mode")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
    )
}
