//! MCP servers for the agents: what an integration may hold, which of them a session gets, and how each runtime
//! is given them (see docs/ARCHITECTURE.md#integrations). Rows live in `store/integrations.rs`.
//!
//! Secret values never go into an argument list: Claude gets them in its owner-only `--mcp-config` file, Grok
//! in the ACP request on stdin, and Codex through environment variables that its `env_http_headers` names.

use crate::store::{Integration, IntegrationAuth, IntegrationKind, check_name};
use anyhow::{Result, bail};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashMap};

/// A header or environment variable a catalog entry asks the owner for. `value_template` has `{secret}` where the
/// secret's reference goes (`Bearer {secret}`).
#[cfg(test)]
#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CatalogKey {
    pub key: String,
    pub label_en: String,
    pub label_ru: String,
    pub secret: bool,
    pub value_template: String,
}

/// One template of the built-in catalog (`integrations_catalog.json`), as the app reads it. Only the first block of
/// fields is required; the rest is optional, so an older app that ignores them still works. The catalog is served as
/// it is; this type is what the tests hold it to.
#[cfg(test)]
#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CatalogEntry {
    pub id: String,
    pub name: String,
    pub description_en: String,
    pub description_ru: String,
    pub kind: IntegrationKind,
    pub docs_url: String,
    pub icon: String,
    /// One of [`CATALOG_CATEGORIES`].
    pub category: Option<String>,
    /// The service's brand color as `#RRGGBB`, for its tile in the app.
    pub accent: Option<String>,
    pub publisher: Option<String>,
    pub official: Option<bool>,
    pub homepage: Option<String>,
    pub long_en: Option<String>,
    pub long_ru: Option<String>,
    pub abilities_en: Option<Vec<String>>,
    pub abilities_ru: Option<Vec<String>>,
    pub needs_en: Option<String>,
    pub needs_ru: Option<String>,
    pub command: Option<String>,
    pub args: Option<Vec<String>>,
    pub env_keys: Option<Vec<CatalogKey>>,
    pub url: Option<String>,
    pub url_hint: Option<String>,
    pub headers_keys: Option<Vec<CatalogKey>>,
}

/// The categories a catalog entry may have.
#[cfg(test)]
pub const CATALOG_CATEGORIES: [&str; 6] = ["dev", "productivity", "data", "web", "design", "other"];

/// Marks a secret inside a value: `secret:<NAME>`, read when the session starts.
pub const SECRET_PREFIX: &str = "secret:";

/// The crew server's name in every MCP config. An integration may not take it.
pub const RESERVED_NAME: &str = "bandito";

/// Prefix of the secrets the daemon keeps for browser sign-ins (`mcp_oauth.rs`). The secrets calls of the owner and
/// the apps do not list, set or delete them.
pub const OAUTH_SECRET_PREFIX: &str = "MCP_OAUTH_";

/// The id of an integration in a secret name: its hex digits, upper case.
fn oauth_id_part(id: &str) -> String {
    id.chars()
        .filter(char::is_ascii_hexdigit)
        .map(|c| c.to_ascii_uppercase())
        .collect()
}

/// The secret that holds the access token of an OAuth integration.
pub fn oauth_access_name(id: &str) -> String {
    format!("{OAUTH_SECRET_PREFIX}{}_ACCESS", oauth_id_part(id))
}

/// The secret that holds the rest of its sign-in (refresh token, client, endpoints, expiry), as JSON.
pub fn oauth_state_name(id: &str) -> String {
    format!("{OAUTH_SECRET_PREFIX}{}_STATE", oauth_id_part(id))
}

/// The name rules: 1 to 40 characters of `a-z 0-9 _ -`, not the reserved one.
pub fn check_integration_name(name: &str) -> Result<()> {
    let valid = !name.is_empty()
        && name.len() <= 40
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-');
    if !valid {
        bail!("name must be 1 to 40 characters: a-z, 0-9, _ and -");
    }
    if name == RESERVED_NAME {
        bail!("the name bandito belongs to Bandito's own crew server");
    }
    Ok(())
}

/// A stdio integration needs a command; an http one an `https://` url, or `http://localhost`.
pub fn check_definition(kind: IntegrationKind, command: Option<&str>, url: Option<&str>) -> Result<()> {
    match kind {
        IntegrationKind::Stdio => {
            if command.map(str::trim).is_none_or(str::is_empty) {
                bail!("a stdio integration needs a command");
            }
        }
        IntegrationKind::Http => {
            let url = url.unwrap_or_default().trim();
            let local = url
                .strip_prefix("http://localhost")
                .is_some_and(|rest| rest.is_empty() || rest.starts_with('/') || rest.starts_with(':'));
            if !(url.starts_with("https://") || local) {
                bail!("an http integration needs an https:// url (or http://localhost)");
            }
        }
    }
    Ok(())
}

/// The secret names a value refers to: each `secret:<NAME>` in it (a value may be `Bearer secret:TOKEN`).
fn refs(value: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut rest = value;
    while let Some(at) = rest.find(SECRET_PREFIX) {
        let after = &rest[at + SECRET_PREFIX.len()..];
        let len = after
            .bytes()
            .take_while(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || *b == b'_')
            .count();
        if len > 0 {
            out.push(&after[..len]);
        }
        rest = &after[len..];
    }
    out
}

/// Environment or header names, and values: every `secret:<NAME>` in a value must name a valid secret.
pub fn check_pairs(what: &str, map: &BTreeMap<String, String>) -> Result<()> {
    for (key, value) in map {
        let valid = !key.is_empty()
            && key.len() <= 64
            && key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b'.');
        if !valid {
            bail!("{what} name {key:?} is not valid");
        }
        let found = refs(value);
        if found.len() != value.matches(SECRET_PREFIX).count() {
            bail!("{what} {key}: secret: must be followed by a name in capitals, for example secret:GITHUB_TOKEN");
        }
        for name in found {
            check_name(name)?;
        }
    }
    Ok(())
}

/// One environment entry or header of a server. `secret` marks a value that came from a secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pair {
    pub key: String,
    pub value: String,
    pub secret: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Transport {
    Stdio {
        command: String,
        args: Vec<String>,
        env: Vec<Pair>,
    },
    Http {
        url: String,
        headers: Vec<Pair>,
    },
}

/// A server ready for a session: its name and transport, with every secret reference read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Server {
    pub name: String,
    pub transport: Transport,
}

/// The integrations a session of an agent gets: enabled ones, and only those in the agent's list (`None` is
/// every enabled one).
pub fn for_agent<'a>(all: &'a [Integration], ids: Option<&[String]>) -> Vec<&'a Integration> {
    all.iter()
        .filter(|i| i.enabled && ids.is_none_or(|ids| ids.contains(&i.id)))
        .collect()
}

/// The names of the secrets the integrations refer to, so their values can be redacted.
pub fn secret_names(list: &[&Integration]) -> Vec<String> {
    let mut names: Vec<String> = list
        .iter()
        .flat_map(|i| i.env.values().chain(i.headers.values()))
        .flat_map(|v| refs(v))
        .map(str::to_string)
        .chain(
            list.iter()
                .filter(|i| i.auth == IntegrationAuth::Oauth)
                .map(|i| oauth_access_name(&i.id)),
        )
        .collect();
    names.sort();
    names.dedup();
    names
}

/// Whether a server carries values in its environment or headers, which must not reach argv.
pub fn has_values(server: &Server) -> bool {
    match &server.transport {
        Transport::Stdio { env, .. } => !env.is_empty(),
        Transport::Http { headers, .. } => !headers.is_empty(),
    }
}

/// The servers for a session. An integration with a secret reference whose secret is missing is skipped,
/// with a warning in the daemon log; the others start as usual.
pub fn resolve(list: &[&Integration], secrets: &HashMap<String, String>) -> Vec<Server> {
    list.iter()
        .filter_map(|i| {
            let pairs = |map: &BTreeMap<String, String>| -> Option<Vec<Pair>> {
                map.iter().map(|(k, v)| pair(k, v, secrets)).collect()
            };
            let transport = match i.kind {
                IntegrationKind::Stdio => Transport::Stdio {
                    command: i.command.clone().unwrap_or_default(),
                    args: i.args.clone(),
                    env: pairs(&i.env)?,
                },
                IntegrationKind::Http => {
                    let mut headers = pairs(&i.headers)?;
                    if i.auth == IntegrationAuth::Oauth {
                        // The token is the daemon's, not a header the owner wrote: it replaces any `Authorization`.
                        let Some(token) = secrets.get(&oauth_access_name(&i.id)) else {
                            tracing::warn!(integration = i.name, "integration skipped: not signed in");
                            return None;
                        };
                        headers.retain(|h| !h.key.eq_ignore_ascii_case("authorization"));
                        headers.push(Pair {
                            key: "Authorization".into(),
                            value: format!("Bearer {token}"),
                            secret: true,
                        });
                    }
                    Transport::Http {
                        url: i.url.clone().unwrap_or_default(),
                        headers,
                    }
                }
            };
            Some(Server {
                name: i.name.clone(),
                transport,
            })
        })
        .collect()
}

/// The value with each `secret:<NAME>` replaced by the secret. `None` when one names no secret.
fn pair(key: &str, value: &str, secrets: &HashMap<String, String>) -> Option<Pair> {
    let mut out = String::new();
    let mut secret = false;
    let mut rest = value;
    while let Some(at) = rest.find(SECRET_PREFIX) {
        out.push_str(&rest[..at]);
        let after = &rest[at + SECRET_PREFIX.len()..];
        let len = after
            .bytes()
            .take_while(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || *b == b'_')
            .count();
        if len == 0 {
            out.push_str(SECRET_PREFIX);
            rest = after;
            continue;
        }
        let name = &after[..len];
        let Some(found) = secrets.get(name) else {
            tracing::warn!(secret = name, "integration skipped: no secret with that name");
            return None;
        };
        out.push_str(found);
        secret = true;
        rest = &after[len..];
    }
    out.push_str(rest);
    Some(Pair {
        key: key.to_string(),
        value: out,
        secret,
    })
}

/// The entries of Claude's `mcpServers`, by name.
pub fn claude_entries(servers: &[Server]) -> Map<String, Value> {
    servers
        .iter()
        .map(|s| {
            let entry = match &s.transport {
                Transport::Stdio { command, args, env } => json!({
                    "command": command,
                    "args": args,
                    "env": pairs_object(env),
                }),
                Transport::Http { url, headers } => json!({
                    "type": "http",
                    "url": url,
                    "headers": pairs_object(headers),
                }),
            };
            (s.name.clone(), entry)
        })
        .collect()
}

/// The `mcpServers` of Grok's ACP `session/new`: env and headers as name and value lists.
pub fn grok_servers(servers: &[Server]) -> Vec<Value> {
    servers
        .iter()
        .map(|s| match &s.transport {
            Transport::Stdio { command, args, env } => json!({
                "name": s.name,
                "command": command,
                "args": args,
                "env": pairs_list(env, "name", "value"),
            }),
            Transport::Http { url, headers } => json!({
                "type": "http",
                "name": s.name,
                "url": url,
                "headers": pairs_list(headers, "name", "value"),
            }),
        })
        .collect()
}

/// What Codex needs: `-c` overrides, and environment variables to start the codex process with.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct CodexConfig {
    pub overrides: Vec<String>,
    pub env: Vec<(String, String)>,
}

/// Variables the codex process and the daemon depend on: no integration may set them through Codex.
fn is_reserved(key: &str) -> bool {
    const EXACT: &[&str] = &[
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "LANG",
        "TMPDIR",
        "TERM",
        "PWD",
        "CODEX_HOME",
        "SSH_AUTH_SOCK",
    ];
    let upper = key.to_ascii_uppercase();
    EXACT.contains(&key)
        || key.starts_with("LC_")
        || upper.starts_with("BANDITO_")
        || upper.starts_with("CODEX_")
        || upper.starts_with("DYLD_")
        || upper.starts_with("LD_")
}

/// The Codex config of the servers. Codex's `-c` values sit in the argument list, so they carry no secret:
/// an http header that holds one travels in an environment variable, named by `env_http_headers`. A stdio
/// server with a secret in its environment cannot be started that way, so it is skipped with a warning.
pub fn codex_config(servers: &[Server]) -> CodexConfig {
    let mut out = CodexConfig::default();
    // One counter for the whole config: names like `a-b` and `a_b` cannot collide this way.
    let mut next_var = 0usize;
    // The stdio environment values by key, for the clash check.
    let mut seen: BTreeMap<String, String> = BTreeMap::new();
    for s in servers {
        let base = format!("mcp_servers.{}", s.name);
        match &s.transport {
            Transport::Stdio { command, args, env } => {
                // The values go into the codex process environment; `env_vars` names them for the server, so the
                // argument list carries names only. A variable Codex or the daemon uses, or one another server
                // sets to a different value, would be a clash: the server is skipped instead.
                let clash = env
                    .iter()
                    .any(|p| is_reserved(&p.key) || seen.get(&p.key).is_some_and(|value| value != &p.value));
                if clash {
                    tracing::warn!(
                        server = s.name,
                        "codex integration skipped: its environment names a reserved variable or clashes with another server's"
                    );
                    continue;
                }
                for p in env {
                    seen.insert(p.key.clone(), p.value.clone());
                    out.env.push((p.key.clone(), p.value.clone()));
                }
                out.overrides.push(format!("{base}.command={}", json!(command)));
                out.overrides.push(format!("{base}.args={}", json!(args)));
                if !env.is_empty() {
                    let names: Vec<&str> = env.iter().map(|p| p.key.as_str()).collect();
                    out.overrides.push(format!("{base}.env_vars={}", json!(names)));
                }
            }
            Transport::Http { url, headers } => {
                out.overrides.push(format!("{base}.url={}", json!(url)));
                if !headers.is_empty() {
                    let names: Vec<(String, String)> = headers
                        .iter()
                        .map(|h| {
                            let var = format!("BANDITO_MCP_HEADER_{next_var}");
                            next_var += 1;
                            out.env.push((var.clone(), h.value.clone()));
                            (h.key.clone(), var)
                        })
                        .collect();
                    let table: Vec<String> = names
                        .iter()
                        .map(|(k, var)| format!("{} = {}", json!(k), json!(var)))
                        .collect();
                    out.overrides
                        .push(format!("{base}.env_http_headers={{ {} }}", table.join(", ")));
                }
            }
        }
    }
    out
}

/// The line put in the agent's prompt when it has integrations; `None` for none.
pub fn prompt_line(names: &[&str]) -> Option<String> {
    (!names.is_empty()).then(|| {
        format!(
            "Подключённые интеграции: {}. Используйте их инструменты, когда задача про эти сервисы.",
            names.join(", ")
        )
    })
}

/// The line put in the agent's prompt for OAuth integrations that need the owner to sign in again; `None` for none.
pub fn relogin_line(names: &[&str]) -> Option<String> {
    (!names.is_empty()).then(|| {
        format!(
            "Интеграции без входа: {}. Их инструментов в этой сессии нет: попросите владельца нажать «Подключить» у этой интеграции в маркетплейсе Bandito.",
            names.join(", ")
        )
    })
}

fn pairs_object(pairs: &[Pair]) -> Value {
    Value::Object(pairs.iter().map(|p| (p.key.clone(), json!(p.value))).collect())
}

fn pairs_list(pairs: &[Pair], name: &str, value: &str) -> Value {
    Value::Array(pairs.iter().map(|p| json!({ name: p.key, value: p.value })).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stdio(name: &str, env: &[(&str, &str)]) -> Integration {
        Integration {
            id: format!("id-{name}"),
            name: name.into(),
            kind: IntegrationKind::Stdio,
            command: Some("npx".into()),
            args: vec!["-y".into(), "pkg".into()],
            url: None,
            env: env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            headers: BTreeMap::new(),
            enabled: true,
            created_at: 0,
            auth: Default::default(),
        }
    }

    fn http(name: &str, headers: &[(&str, &str)]) -> Integration {
        Integration {
            id: format!("id-{name}"),
            name: name.into(),
            kind: IntegrationKind::Http,
            command: None,
            args: vec![],
            url: Some("https://api.example.com/mcp/".into()),
            env: BTreeMap::new(),
            headers: headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            enabled: true,
            created_at: 0,
            auth: Default::default(),
        }
    }

    fn secrets() -> HashMap<String, String> {
        HashMap::from([("GITHUB_TOKEN".to_string(), "tok-real-value".to_string())])
    }

    #[test]
    fn names_are_short_lowercase_and_not_the_crew_server() {
        for ok in ["fetch", "gh-1", "a_b", &"x".repeat(40)] {
            assert!(check_integration_name(ok).is_ok(), "{ok}");
        }
        for bad in ["", "Fetch", "a b", "a.b", "é", "bandito", &"x".repeat(41)] {
            assert!(check_integration_name(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn stdio_needs_a_command_and_http_an_https_url_or_localhost() {
        assert!(check_definition(IntegrationKind::Stdio, Some("npx"), None).is_ok());
        assert!(check_definition(IntegrationKind::Stdio, Some("  "), None).is_err());
        assert!(check_definition(IntegrationKind::Stdio, None, None).is_err());
        assert!(check_definition(IntegrationKind::Http, None, Some("https://mcp.example.com/x")).is_ok());
        assert!(check_definition(IntegrationKind::Http, None, Some("http://localhost:3000/mcp")).is_ok());
        assert!(check_definition(IntegrationKind::Http, None, Some("http://localhost")).is_ok());
        for bad in ["http://example.com/mcp", "http://localhost.evil.com", "ftp://x", ""] {
            assert!(
                check_definition(IntegrationKind::Http, None, Some(bad)).is_err(),
                "{bad}"
            );
        }
    }

    #[test]
    fn pairs_need_valid_names_and_valid_secret_references() {
        let ok = BTreeMap::from([
            ("X-Api-Key".to_string(), "secret:GITHUB_TOKEN".to_string()),
            ("Accept".to_string(), "application/json".to_string()),
        ]);
        assert!(check_pairs("header", &ok).is_ok());
        let bad_name = BTreeMap::from([("bad name".to_string(), "x".to_string())]);
        assert!(check_pairs("env", &bad_name).is_err());
        let bad_secret = BTreeMap::from([("K".to_string(), "secret:lower-case".to_string())]);
        assert!(check_pairs("env", &bad_secret).is_err());
    }

    #[test]
    fn a_session_gets_enabled_integrations_in_the_agents_list() {
        let mut off = stdio("off", &[]);
        off.enabled = false;
        let all = vec![stdio("fetch", &[]), http("gh", &[]), off];
        assert_eq!(for_agent(&all, None).len(), 2, "null = every enabled one");
        let only_gh = vec!["id-gh".to_string()];
        let chosen = for_agent(&all, Some(&only_gh));
        assert_eq!(chosen.iter().map(|i| i.name.as_str()).collect::<Vec<_>>(), ["gh"]);
        assert!(for_agent(&all, Some(&[])).is_empty());
    }

    #[test]
    fn secrets_resolve_and_a_missing_one_skips_only_its_integration() {
        let gh = http("gh", &[("Authorization", "Bearer secret:GITHUB_TOKEN")]);
        let broken = http("broken", &[("Authorization", "secret:NOPE")]);
        let fetch = stdio("fetch", &[("LOG", "1")]);
        let servers = resolve(&[&gh, &broken, &fetch], &secrets());
        let names: Vec<&str> = servers.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, ["gh", "fetch"]);
        match &servers[0].transport {
            Transport::Http { headers, .. } => assert_eq!(headers[0].value, "Bearer tok-real-value"),
            _ => panic!(),
        }
    }

    #[test]
    fn a_secret_reference_is_read_into_the_value_and_marked() {
        let gh = http("gh", &[("Authorization", "secret:GITHUB_TOKEN")]);
        let servers = resolve(&[&gh], &secrets());
        match &servers[0].transport {
            Transport::Http { headers, .. } => {
                assert_eq!(
                    headers[0],
                    Pair {
                        key: "Authorization".into(),
                        value: "tok-real-value".into(),
                        secret: true
                    }
                );
            }
            _ => panic!(),
        }
    }

    #[test]
    fn claude_gets_the_values_inline_in_its_config() {
        let gh = http("gh", &[("Authorization", "secret:GITHUB_TOKEN")]);
        let fetch = stdio("fetch", &[("LOG", "1")]);
        let servers = resolve(&[&gh, &fetch], &secrets());
        let entries = claude_entries(&servers);
        assert_eq!(entries["fetch"]["command"], "npx");
        assert_eq!(entries["fetch"]["env"]["LOG"], "1");
        assert_eq!(entries["gh"]["type"], "http");
        assert_eq!(entries["gh"]["headers"]["Authorization"], "tok-real-value");
    }

    #[test]
    fn grok_gets_name_and_value_lists_in_acp_form() {
        let gh = http("gh", &[("Authorization", "secret:GITHUB_TOKEN")]);
        let fetch = stdio("fetch", &[("LOG", "1")]);
        let servers = resolve(&[&gh, &fetch], &secrets());
        let list = grok_servers(&servers);
        assert_eq!(list[0]["name"], "gh");
        assert_eq!(
            list[0]["headers"],
            json!([{ "name": "Authorization", "value": "tok-real-value" }])
        );
        assert_eq!(list[1]["env"], json!([{ "name": "LOG", "value": "1" }]));
        assert_eq!(list[1]["args"], json!(["-y", "pkg"]));
    }

    #[test]
    fn codex_keeps_header_secrets_out_of_argv() {
        let gh = http("gh", &[("Authorization", "Bearer secret:GITHUB_TOKEN")]);
        let servers = resolve(&[&gh], &secrets());
        let cfg = codex_config(&servers);
        assert!(
            cfg.overrides.iter().all(|o| !o.contains("tok-real-value")),
            "{:?}",
            cfg.overrides
        );
        assert_eq!(
            cfg.overrides,
            [
                "mcp_servers.gh.url=\"https://api.example.com/mcp/\"".to_string(),
                "mcp_servers.gh.env_http_headers={ \"Authorization\" = \"BANDITO_MCP_HEADER_0\" }".to_string(),
            ]
        );
        assert_eq!(
            cfg.env,
            [("BANDITO_MCP_HEADER_0".to_string(), "Bearer tok-real-value".to_string())]
        );
    }

    #[test]
    fn codex_header_variables_do_not_collide_for_similar_names() {
        let a = http("a-b", &[("Authorization", "secret:GITHUB_TOKEN")]);
        let b = http("a_b", &[("X-Key", "secret:GITHUB_TOKEN"), ("X-Two", "two")]);
        let servers = resolve(&[&a, &b], &secrets());
        let cfg = codex_config(&servers);
        let vars: Vec<&str> = cfg.env.iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(vars.len(), 3);
        let unique: std::collections::BTreeSet<&str> = vars.iter().copied().collect();
        assert_eq!(unique.len(), 3, "every header gets its own variable: {vars:?}");
        // Each server's table points at its own variables, in order.
        assert!(cfg.overrides[1].contains("BANDITO_MCP_HEADER_0"), "{:?}", cfg.overrides);
        assert!(cfg.overrides[3].contains("BANDITO_MCP_HEADER_1") && cfg.overrides[3].contains("BANDITO_MCP_HEADER_2"));
    }

    #[test]
    fn codex_stdio_values_travel_in_the_environment_never_in_argv() {
        let fetch = stdio("fetch", &[("LOG", "1")]);
        let leaky = stdio("leaky", &[("TOKEN", "secret:GITHUB_TOKEN")]);
        let servers = resolve(&[&fetch, &leaky], &secrets());
        let cfg = codex_config(&servers);
        assert_eq!(
            cfg.overrides,
            [
                "mcp_servers.fetch.command=\"npx\"".to_string(),
                "mcp_servers.fetch.args=[\"-y\",\"pkg\"]".to_string(),
                "mcp_servers.fetch.env_vars=[\"LOG\"]".to_string(),
                "mcp_servers.leaky.command=\"npx\"".to_string(),
                "mcp_servers.leaky.args=[\"-y\",\"pkg\"]".to_string(),
                "mcp_servers.leaky.env_vars=[\"TOKEN\"]".to_string(),
            ]
        );
        // No value of any environment entry is in an argument.
        let argv = cfg.overrides.join(" ");
        assert!(
            !argv.contains("tok-real-value") && !argv.contains("=1") && !argv.contains("\"1\""),
            "{argv}"
        );
        assert_eq!(
            cfg.env,
            [
                ("LOG".to_string(), "1".to_string()),
                ("TOKEN".to_string(), "tok-real-value".to_string()),
            ]
        );
    }

    #[test]
    fn codex_skips_a_stdio_server_that_clashes_or_names_a_reserved_variable() {
        let reserved = stdio("reserved", &[("PATH", "/evil")]);
        let first = stdio("first", &[("API_BASE", "one")]);
        let clash = stdio("clash", &[("API_BASE", "two")]);
        let same = stdio("same", &[("API_BASE", "one")]);
        let servers = resolve(&[&reserved, &first, &clash, &same], &secrets());
        let cfg = codex_config(&servers);
        let names: Vec<&str> = cfg
            .overrides
            .iter()
            .filter_map(|o| o.strip_prefix("mcp_servers."))
            .filter_map(|o| o.split('.').next())
            .collect();
        let mut kinds: Vec<&str> = names.clone();
        kinds.dedup();
        assert_eq!(kinds, ["first", "same"], "{names:?}");
        assert_eq!(
            cfg.env.iter().filter(|(k, _)| k == "API_BASE").count(),
            2,
            "equal values share the key"
        );
        assert!(cfg.env.iter().all(|(k, _)| k != "PATH"));
    }

    #[test]
    fn an_oauth_integration_gets_the_daemons_token_as_its_authorization_header() {
        let mut row = http("notion", &[("Authorization", "secret:GITHUB_TOKEN"), ("X-Team", "one")]);
        row.auth = IntegrationAuth::Oauth;
        let access = oauth_access_name(&row.id);
        assert!(secret_names(&[&row]).contains(&access));
        let mut map = secrets();
        // Without the token the integration is left out.
        assert!(resolve(&[&row], &map).is_empty());
        map.insert(access, "at-live-token".into());
        let servers = resolve(&[&row], &map);
        match &servers[0].transport {
            Transport::Http { headers, .. } => {
                let auth: Vec<&Pair> = headers
                    .iter()
                    .filter(|h| h.key.eq_ignore_ascii_case("authorization"))
                    .collect();
                assert_eq!(auth.len(), 1, "the owner's own Authorization header is replaced");
                assert_eq!((auth[0].value.as_str(), auth[0].secret), ("Bearer at-live-token", true));
                assert!(headers.iter().any(|h| h.key == "X-Team"));
            }
            _ => panic!(),
        }
    }

    #[test]
    fn oauth_secret_names_are_valid_secret_names() {
        let id = "0198f3a2-7b1c-7d4e-8a55-0123456789ab";
        for name in [oauth_access_name(id), oauth_state_name(id)] {
            check_name(&name).unwrap();
            assert!(name.starts_with(OAUTH_SECRET_PREFIX));
        }
        assert_ne!(oauth_access_name(id), oauth_state_name(id));
    }

    #[test]
    fn prompt_line_names_the_integrations_or_is_absent() {
        assert_eq!(prompt_line(&[]), None);
        assert_eq!(
            prompt_line(&["fetch", "gh"]).unwrap(),
            "Подключённые интеграции: fetch, gh. Используйте их инструменты, когда задача про эти сервисы."
        );
    }
}
