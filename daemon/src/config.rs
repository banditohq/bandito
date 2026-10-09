//! The daemon's optional config file, `$BANDITO_HOME/config.json`. Keys:
//! - `allowed_hosts`: extra `Host` names a loopback listener accepts, for a reverse proxy or tunnel on
//!   this server (see docs/ARCHITECTURE.md#trust-model). Names only, without a port.

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use std::path::Path;

/// The file name in the data folder.
pub const FILE: &str = "config.json";

#[derive(Debug, Deserialize, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    /// Extra `Host` names for a loopback listener (see docs/ARCHITECTURE.md#trust-model).
    pub allowed_hosts: Vec<String>,
    /// Run agent CLIs under the macOS sandbox (`runtime::sandbox`). Has no effect elsewhere.
    pub agent_sandbox: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            allowed_hosts: Vec::new(),
            agent_sandbox: true,
        }
    }
}

/// Reads `<home>/config.json`. A missing file is an empty config. A broken one stops the daemon
/// rather than running with settings nobody meant.
pub fn load(home: &Path) -> Result<Config> {
    let path = home.join(FILE);
    match std::fs::read_to_string(&path) {
        Ok(text) => parse(&text).with_context(|| format!("{} is not a valid config", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
        Err(e) => Err(e).with_context(|| format!("read {}", path.display())),
    }
}

/// Parses the file's text and checks the values.
pub fn parse(text: &str) -> Result<Config> {
    let config: Config = serde_json::from_str(text)?;
    for host in &config.allowed_hosts {
        let name = host.trim();
        if name.is_empty() || name.contains(|c: char| c.is_whitespace() || matches!(c, '/' | ':' | '[' | ']')) {
            bail!("allowed_hosts entry {host:?} must be a host name, without a port or a path");
        }
    }
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowed_hosts_are_names() {
        let c = parse(r#"{"allowed_hosts": ["mac.tailnet.ts.net", "proxy.example"]}"#).unwrap();
        assert_eq!(c.allowed_hosts, vec!["mac.tailnet.ts.net", "proxy.example"]);
        assert_eq!(parse("{}").unwrap(), Config::default());
    }

    #[test]
    fn a_host_with_a_port_or_a_path_is_refused() {
        for bad in ["proxy.example:443", "https://proxy.example", "a b", "", "[::1]"] {
            let text = serde_json::json!({ "allowed_hosts": [bad] }).to_string();
            assert!(parse(&text).is_err(), "{bad:?} should be refused");
        }
    }

    #[test]
    fn the_sandbox_is_on_unless_switched_off() {
        assert!(parse("{}").unwrap().agent_sandbox);
        assert!(!parse(r#"{"agent_sandbox": false}"#).unwrap().agent_sandbox);
    }

    #[test]
    fn unknown_keys_are_refused() {
        assert!(parse(r#"{"allowd_hosts": []}"#).is_err());
    }

    #[test]
    fn a_missing_file_is_an_empty_config() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(load(dir.path()).unwrap(), Config::default());
        std::fs::write(dir.path().join(FILE), r#"{"allowed_hosts": ["x.example"]}"#).unwrap();
        assert_eq!(load(dir.path()).unwrap().allowed_hosts, vec!["x.example"]);
    }
}
