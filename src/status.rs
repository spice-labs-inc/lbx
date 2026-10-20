//! The unattended-run outcome grammar:
//! `status=(setup-failed|timeout|signal|exited|refused) code=N( cleanup=incomplete)?`

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunStatus {
    SetupFailed,
    Timeout,
    Signal,
    Exited,
    Refused,
}

impl RunStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            RunStatus::SetupFailed => "setup-failed",
            RunStatus::Timeout => "timeout",
            RunStatus::Signal => "signal",
            RunStatus::Exited => "exited",
            RunStatus::Refused => "refused",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "setup-failed" => RunStatus::SetupFailed,
            "timeout" => RunStatus::Timeout,
            "signal" => RunStatus::Signal,
            "exited" => RunStatus::Exited,
            "refused" => RunStatus::Refused,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
    pub status: RunStatus,
    pub code: i32,
    pub cleanup_incomplete: bool,
}

impl Outcome {
    pub fn format(&self) -> String {
        let mut s = format!("status={} code={}", self.status.as_str(), self.code);
        if self.cleanup_incomplete {
            s.push_str(" cleanup=incomplete");
        }
        s
    }

    pub fn parse(line: &str) -> Option<Outcome> {
        let mut parts = line.split(' ');
        let status = RunStatus::parse(parts.next()?.strip_prefix("status=")?)?;
        let code: i32 = parts.next()?.strip_prefix("code=")?.parse().ok()?;
        let cleanup_incomplete = match parts.next() {
            None => false,
            Some("cleanup=incomplete") => true,
            Some(_) => return None,
        };
        if parts.next().is_some() {
            return None;
        }
        Some(Outcome {
            status,
            code,
            cleanup_incomplete,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        for line in [
            "status=exited code=0",
            "status=timeout code=124",
            "status=refused code=125",
            "status=exited code=0 cleanup=incomplete",
        ] {
            let o = Outcome::parse(line);
            assert!(o.is_some(), "{line}");
            assert_eq!(o.map(|o| o.format()).as_deref(), Some(line));
        }
    }

    #[test]
    fn rejects() {
        for line in [
            "status=ok code=0",
            "status=exited",
            "status=exited code=x",
            "status=exited code=0 cleanup=done",
            "status=exited code=0 cleanup=incomplete extra",
            "",
        ] {
            assert_eq!(Outcome::parse(line), None, "{line}");
        }
    }
}
