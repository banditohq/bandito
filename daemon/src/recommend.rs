//! Catalog templates that suit an agent's folder, found from the files the folder shows (see
//! docs/ARCHITECTURE.md#recommendations). Nothing runs and nothing leaves the server: the rules look at names and read
//! the content of a few known files only. Links are never followed.

use crate::store::Integration;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Most suggestions one answer carries.
pub const MAX_SUGGESTIONS: usize = 6;
/// A file the rules read is skipped above this size.
const FILE_LIMIT: u64 = 256 * 1024;
/// How much of a README is searched.
const README_LIMIT: usize = 64 * 1024;

/// A template the folder suggests: why (a key for the app's text) and the file that shows it, relative to the folder.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Suggestion {
    pub template_id: &'static str,
    pub reason_key: &'static str,
    pub evidence: String,
}

/// What the rules need of a catalog entry (`daemon/src/integrations_catalog.json`): its id and its address.
#[derive(Debug, Deserialize)]
pub struct Template {
    pub id: String,
    #[serde(default)]
    pub url: Option<String>,
}

/// The suggestions for the folder `root`, at most [`MAX_SUGGESTIONS`]. A template the owner has connected is left out:
/// one of `rows` is named after it, or has its address. A template that several rules suggest appears once, with the
/// reason of the first rule in the order of docs/ARCHITECTURE.md#recommendations.
pub fn for_folder(root: &Path, catalog: &[Template], rows: &[Integration]) -> Vec<Suggestion> {
    let mut out: Vec<Suggestion> = Vec::new();
    for s in candidates(root) {
        if out.len() == MAX_SUGGESTIONS {
            break;
        }
        if out.iter().any(|o| o.template_id == s.template_id) || connected(s.template_id, catalog, rows) {
            continue;
        }
        out.push(s);
    }
    out
}

/// Whether the owner has the template connected: an integration named after it, or one at the template's address.
fn connected(template: &str, catalog: &[Template], rows: &[Integration]) -> bool {
    catalog.iter().filter(|t| t.id == template).any(|t| {
        rows.iter().any(|r| {
            r.name == t.id
                || match (t.url.as_deref(), r.url.as_deref()) {
                    (Some(a), Some(b)) => same_address(a, b),
                    _ => false,
                }
        })
    })
}

/// Two addresses are the same when they differ only in the case of the scheme and host, or in a trailing `/`.
fn same_address(a: &str, b: &str) -> bool {
    address_key(a) == address_key(b)
}

fn address_key(raw: &str) -> String {
    let trimmed = raw.trim().trim_end_matches('/');
    match trimmed.split_once("://") {
        Some((scheme, rest)) => {
            let cut = rest.find('/').unwrap_or(rest.len());
            format!(
                "{}://{}{}",
                scheme.to_ascii_lowercase(),
                rest[..cut].to_ascii_lowercase(),
                rest[cut..].trim_end_matches('/')
            )
        }
        None => trimmed.to_string(),
    }
}

/// A `package.json` or a Python requirements file: the names it lists, in lower case (PEP 503 for Python).
struct Listed {
    path: PathBuf,
    names: Vec<String>,
}

/// Every rule that holds for the folder, in the order of the rules. Not yet filtered for connected templates.
fn candidates(root: &Path) -> Vec<Suggestion> {
    let Some(levels) = levels(root) else {
        return Vec::new();
    };
    let manifests = package_manifests(&levels);
    let python = python_manifests(&levels);
    let mut out = Vec::new();

    // Git remotes: .git/config of the folder or of one folder below it.
    for level in &levels {
        let Some(config) = plain_file(level, ".git/config") else {
            continue;
        };
        for host in remote_hosts(&read_text(&config).unwrap_or_default()) {
            match host.as_str() {
                "github.com" => out.push(found("github", "recommend.reason.gitRemoteGithub", root, &config)),
                "gitlab.com" => out.push(found("gitlab", "recommend.reason.gitRemoteGitlab", root, &config)),
                _ => {}
            }
        }
    }
    if let Some(m) = manifests.iter().find(|m| m.names.iter().any(|n| n == "next")) {
        out.push(found("vercel", "recommend.reason.nextPackage", root, &m.path));
    }
    if let Some(p) = first_file(&levels, "netlify.toml") {
        out.push(found("netlify", "recommend.reason.netlifyToml", root, &p));
    }
    if let Some(p) = first_file(&levels, "vercel.json") {
        out.push(found("vercel", "recommend.reason.vercelJson", root, &p));
    }
    if let Some(p) = first_file(&levels, "sentry.properties") {
        out.push(found("sentry", "recommend.reason.sentryProperties", root, &p));
    }
    if let Some(m) = manifests
        .iter()
        .find(|m| m.names.iter().any(|n| n.starts_with("@sentry/")))
    {
        out.push(found("sentry", "recommend.reason.sentryPackage", root, &m.path));
    }
    if let Some(m) = python.iter().find(|m| m.names.iter().any(|n| n == "sentry-sdk")) {
        out.push(found("sentry", "recommend.reason.sentryPython", root, &m.path));
    }
    if let Some(p) = first_dir(&levels, "supabase") {
        out.push(found("supabase", "recommend.reason.supabaseFolder", root, &p));
    }
    if let Some(m) = manifests
        .iter()
        .find(|m| m.names.iter().any(|n| n.starts_with("@supabase/")))
    {
        out.push(found("supabase", "recommend.reason.supabasePackage", root, &m.path));
    }
    if let Some(p) = first_file(&levels, "prisma/schema.prisma") {
        out.push(found("prisma", "recommend.reason.prismaSchema", root, &p));
    }
    if let Some(p) = first_file(&levels, "wrangler.toml") {
        out.push(found("cloudflare", "recommend.reason.wranglerToml", root, &p));
    }
    // The catalog's id for Google MCP Toolbox for PostgreSQL.
    for path in files_matching(&levels, |n| n.starts_with("docker-compose") && n.ends_with(".yml")) {
        if read_text(&path).is_some_and(|t| t.to_ascii_lowercase().contains("postgres")) {
            out.push(found(
                "toolbox-postgres",
                "recommend.reason.composePostgres",
                root,
                &path,
            ));
        }
    }
    if let Some(p) = first_entry(&levels, ".linear") {
        out.push(found("linear", "recommend.reason.linearFolder", root, &p));
    }
    for path in files_matching(&levels, |n| n.to_ascii_lowercase().starts_with("readme")) {
        if read_bytes(&path).is_some_and(|b| head_contains(&b, README_LIMIT, "linear.app")) {
            out.push(found("linear", "recommend.reason.linearReadme", root, &path));
        }
    }
    if let Some(m) = manifests.iter().find(|m| m.names.iter().any(|n| n.contains("posthog"))) {
        out.push(found("posthog", "recommend.reason.posthogPackage", root, &m.path));
    }
    if let Some(m) = manifests.iter().find(|m| m.names.iter().any(|n| n.contains("stripe"))) {
        out.push(found("stripe", "recommend.reason.stripePackage", root, &m.path));
    }
    if let Some(m) = python.iter().find(|m| m.names.iter().any(|n| n == "stripe")) {
        out.push(found("stripe", "recommend.reason.stripePackage", root, &m.path));
    }
    out
}

fn found(template_id: &'static str, reason_key: &'static str, root: &Path, path: &Path) -> Suggestion {
    Suggestion {
        template_id,
        reason_key,
        evidence: path.strip_prefix(root).unwrap_or(path).to_string_lossy().into_owned(),
    }
}

/// The folder itself and each real folder directly below it, root first. None when the folder is not a real folder
/// (a link counts as no folder).
fn levels(root: &Path) -> Option<Vec<PathBuf>> {
    if !std::fs::symlink_metadata(root).ok()?.is_dir() {
        return None;
    }
    let mut subs: Vec<PathBuf> = std::fs::read_dir(root)
        .ok()?
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.path())
        .collect();
    subs.sort();
    let mut out = vec![root.to_path_buf()];
    out.extend(subs);
    Some(out)
}

/// `rel` (`a/b`) under `level`, when every folder on the way is a real folder. A link on the way, or at the end, is
/// refused.
fn under(level: &Path, rel: &str) -> Option<PathBuf> {
    let parts: Vec<&str> = rel.split('/').collect();
    let mut cur = level.to_path_buf();
    for (i, part) in parts.iter().enumerate() {
        cur.push(part);
        let meta = std::fs::symlink_metadata(&cur).ok()?;
        if meta.file_type().is_symlink() || (i + 1 < parts.len() && !meta.is_dir()) {
            return None;
        }
    }
    Some(cur)
}

fn plain_file(level: &Path, rel: &str) -> Option<PathBuf> {
    under(level, rel).filter(|p| std::fs::symlink_metadata(p).is_ok_and(|m| m.is_file()))
}

fn first_file(levels: &[PathBuf], rel: &str) -> Option<PathBuf> {
    levels.iter().find_map(|l| plain_file(l, rel))
}

fn first_dir(levels: &[PathBuf], rel: &str) -> Option<PathBuf> {
    levels
        .iter()
        .find_map(|l| under(l, rel).filter(|p| std::fs::symlink_metadata(p).is_ok_and(|m| m.is_dir())))
}

/// A file or a folder named `rel`.
fn first_entry(levels: &[PathBuf], rel: &str) -> Option<PathBuf> {
    levels.iter().find_map(|l| under(l, rel))
}

/// The regular files of `level` whose names match, sorted. Links are not files here.
fn files_in(level: &Path, matches: impl Fn(&str) -> bool) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(level) else {
        return Vec::new();
    };
    let mut out: Vec<PathBuf> = entries
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()) && matches(&e.file_name().to_string_lossy()))
        .map(|e| e.path())
        .collect();
    out.sort();
    out
}

fn files_matching(levels: &[PathBuf], matches: impl Fn(&str) -> bool + Copy) -> Vec<PathBuf> {
    levels.iter().flat_map(|l| files_in(l, matches)).collect()
}

/// The bytes of a regular file of at most [`FILE_LIMIT`]; None when it is missing, a link, bigger, or unreadable.
fn read_bytes(path: &Path) -> Option<Vec<u8>> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || meta.len() > FILE_LIMIT {
        return None;
    }
    std::fs::read(path).ok()
}

fn read_text(path: &Path) -> Option<String> {
    read_bytes(path).map(|b| String::from_utf8_lossy(&b).into_owned())
}

fn head_contains(bytes: &[u8], limit: usize, needle: &str) -> bool {
    let head = &bytes[..bytes.len().min(limit)];
    String::from_utf8_lossy(head).to_ascii_lowercase().contains(needle)
}

/// The dependency names of each `package.json` (keys of `dependencies` and `devDependencies`), in lower case.
fn package_manifests(levels: &[PathBuf]) -> Vec<Listed> {
    let mut out = Vec::new();
    for level in levels {
        let Some(path) = plain_file(level, "package.json") else {
            continue;
        };
        let Some(value) = read_bytes(&path).and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok()) else {
            continue;
        };
        let mut names = Vec::new();
        for key in ["dependencies", "devDependencies"] {
            if let Some(deps) = value.get(key).and_then(|d| d.as_object()) {
                names.extend(deps.keys().map(|k| k.to_ascii_lowercase()));
            }
        }
        out.push(Listed { path, names });
    }
    out
}

/// The package names of each `requirements*.txt` and `pyproject.toml`, normalized.
fn python_manifests(levels: &[PathBuf]) -> Vec<Listed> {
    let mut out = Vec::new();
    for level in levels {
        let mut paths = files_in(level, |n| n.starts_with("requirements") && n.ends_with(".txt"));
        paths.extend(plain_file(level, "pyproject.toml"));
        for path in paths {
            let Some(text) = read_text(&path) else {
                continue;
            };
            let names = if path.ends_with("pyproject.toml") {
                pyproject_names(&text)
            } else {
                requirement_names(&text)
            };
            out.push(Listed { path, names });
        }
    }
    out
}

/// One package per line of a requirements file; options and comments are skipped.
fn requirement_names(text: &str) -> Vec<String> {
    text.lines()
        .filter(|l| !l.trim_start().starts_with(['#', '-']))
        .filter_map(package_name)
        .collect()
}

/// The packages a pyproject names: every string in quotes that starts with a package name.
fn pyproject_names(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in text.lines() {
        for quoted in line.split(['"', '\'']).skip(1).step_by(2) {
            out.extend(package_name(quoted));
        }
    }
    out
}

/// The package name at the start of a requirement (`name[extra]>=1; marker`), normalized as PEP 503 does. None when
/// the text after the name is not a requirement's.
fn package_name(spec: &str) -> Option<String> {
    let spec = spec.trim();
    let end = spec
        .find(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')))
        .unwrap_or(spec.len());
    let (name, rest) = spec.split_at(end);
    if !name.starts_with(|c: char| c.is_ascii_alphanumeric()) {
        return None;
    }
    let rest = rest.trim_start();
    if !(rest.is_empty() || rest.starts_with(['[', '<', '>', '=', '!', '~', ';', '@', '(', '#'])) {
        return None;
    }
    Some(name.to_ascii_lowercase().replace(['_', '.'], "-"))
}

/// The hosts of the `url` lines of the `[remote …]` sections of a git config, in lower case.
fn remote_hosts(config: &str) -> Vec<String> {
    let mut in_remote = false;
    let mut hosts = Vec::new();
    for line in config.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_remote = line.starts_with("[remote");
            continue;
        }
        if !in_remote {
            continue;
        }
        let Some(value) = line.strip_prefix("url").and_then(|v| v.trim_start().strip_prefix('=')) else {
            continue;
        };
        hosts.extend(url_host(value.trim()));
    }
    hosts
}

/// The host of a git remote: `https://host/…`, `ssh://user@host:port/…`, or the scp form `user@host:path`.
fn url_host(url: &str) -> Option<String> {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    let authority = &rest[..rest.find(['/', ':']).unwrap_or(rest.len())];
    let host = authority.rsplit('@').next()?.to_ascii_lowercase();
    (!host.is_empty()).then_some(host)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn catalog() -> Vec<Template> {
        serde_json::from_str(include_str!("integrations_catalog.json")).unwrap()
    }

    /// Writes the files into a new folder of the test's own and runs the rules on it.
    fn scan(files: &[(&str, &str)]) -> Vec<Suggestion> {
        let dir = tempfile::tempdir().unwrap();
        for (rel, body) in files {
            write(dir.path(), rel, body);
        }
        for_folder(dir.path(), &catalog(), &[])
    }

    fn write(root: &Path, rel: &str, body: &str) {
        let path = root.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, body).unwrap();
    }

    fn ids(found: &[Suggestion]) -> Vec<&'static str> {
        found.iter().map(|s| s.template_id).collect()
    }

    #[test]
    fn each_rule_is_found_from_its_own_file() {
        // (file, content, template, reason, evidence): one file for each rule, so only that rule can hold.
        let cases: &[(&str, &str, &str, &str, &str)] = &[
            (
                ".git/config",
                "[remote \"origin\"]\n\turl = git@github.com:bandito/x.git\n",
                "github",
                "recommend.reason.gitRemoteGithub",
                ".git/config",
            ),
            (
                ".git/config",
                "[remote \"origin\"]\n\turl = https://gitlab.com/x/y.git\n",
                "gitlab",
                "recommend.reason.gitRemoteGitlab",
                ".git/config",
            ),
            (
                "package.json",
                r#"{"dependencies":{"next":"15.0.0"}}"#,
                "vercel",
                "recommend.reason.nextPackage",
                "package.json",
            ),
            (
                "package.json",
                r#"{"devDependencies":{"next":"15.0.0"}}"#,
                "vercel",
                "recommend.reason.nextPackage",
                "package.json",
            ),
            (
                "netlify.toml",
                "[build]\n",
                "netlify",
                "recommend.reason.netlifyToml",
                "netlify.toml",
            ),
            (
                "vercel.json",
                "{}",
                "vercel",
                "recommend.reason.vercelJson",
                "vercel.json",
            ),
            (
                "sentry.properties",
                "defaults.org=x\n",
                "sentry",
                "recommend.reason.sentryProperties",
                "sentry.properties",
            ),
            (
                "package.json",
                r#"{"dependencies":{"@sentry/node":"8"}}"#,
                "sentry",
                "recommend.reason.sentryPackage",
                "package.json",
            ),
            (
                "requirements.txt",
                "flask==3.0\nsentry-sdk[flask]>=2\n",
                "sentry",
                "recommend.reason.sentryPython",
                "requirements.txt",
            ),
            (
                "pyproject.toml",
                "[project]\ndependencies = [\"Sentry_SDK>=2\"]\n",
                "sentry",
                "recommend.reason.sentryPython",
                "pyproject.toml",
            ),
            (
                "supabase/config.toml",
                "project_id = \"x\"\n",
                "supabase",
                "recommend.reason.supabaseFolder",
                "supabase",
            ),
            (
                "package.json",
                r#"{"dependencies":{"@supabase/supabase-js":"2"}}"#,
                "supabase",
                "recommend.reason.supabasePackage",
                "package.json",
            ),
            (
                "prisma/schema.prisma",
                "datasource db {}\n",
                "prisma",
                "recommend.reason.prismaSchema",
                "prisma/schema.prisma",
            ),
            (
                "wrangler.toml",
                "name = \"x\"\n",
                "cloudflare",
                "recommend.reason.wranglerToml",
                "wrangler.toml",
            ),
            (
                "docker-compose.yml",
                "services:\n  db:\n    image: postgres:16\n",
                "toolbox-postgres",
                "recommend.reason.composePostgres",
                "docker-compose.yml",
            ),
            (
                ".linear/config.json",
                "{}",
                "linear",
                "recommend.reason.linearFolder",
                ".linear",
            ),
            (
                "README.md",
                "Issues live at https://linear.app/team\n",
                "linear",
                "recommend.reason.linearReadme",
                "README.md",
            ),
            (
                "package.json",
                r#"{"dependencies":{"posthog-js":"1"}}"#,
                "posthog",
                "recommend.reason.posthogPackage",
                "package.json",
            ),
            (
                "package.json",
                r#"{"dependencies":{"stripe":"1"}}"#,
                "stripe",
                "recommend.reason.stripePackage",
                "package.json",
            ),
            (
                "requirements.txt",
                "stripe>=10\n",
                "stripe",
                "recommend.reason.stripePackage",
                "requirements.txt",
            ),
        ];
        let catalog = catalog();
        for &(file, body, template, reason, evidence) in cases {
            let got = scan(&[(file, body)]);
            let want = Suggestion {
                template_id: template,
                reason_key: reason,
                evidence: evidence.to_string(),
            };
            assert_eq!(got, vec![want], "{file}");
            assert!(
                catalog.iter().any(|t| t.id == template),
                "{template} is not in the catalog"
            );
        }
    }

    #[test]
    fn the_folder_and_one_level_below_are_read_and_nothing_deeper() {
        let got = scan(&[
            ("app/netlify.toml", "[build]\n"),
            ("app/.git/config", "[remote \"o\"]\nurl = https://github.com/x/y\n"),
        ]);
        assert_eq!(ids(&got), ["github", "netlify"]);
        assert_eq!(got[1].evidence, "app/netlify.toml");
        assert_eq!(got[0].evidence, "app/.git/config");
        assert!(scan(&[("a/b/netlify.toml", "[build]\n")]).is_empty());
    }

    #[test]
    fn suggestions_follow_the_order_of_the_rules() {
        let got = scan(&[
            ("netlify.toml", "[build]\n"),
            ("package.json", r#"{"dependencies":{"stripe":"1","next":"15"}}"#),
            (
                ".git/config",
                "[remote \"origin\"]\n\turl = https://github.com/x/y.git\n",
            ),
        ]);
        assert_eq!(ids(&got), ["github", "vercel", "netlify", "stripe"]);
    }

    #[test]
    fn a_template_from_two_rules_appears_once_with_the_first_reason() {
        let got = scan(&[
            ("vercel.json", "{}"),
            ("package.json", r#"{"dependencies":{"next":"15"}}"#),
        ]);
        assert_eq!(
            got,
            vec![Suggestion {
                template_id: "vercel",
                reason_key: "recommend.reason.nextPackage",
                evidence: "package.json".into(),
            }]
        );
    }

    #[test]
    fn at_most_six_suggestions_come_back() {
        let got = scan(&[
            ("netlify.toml", "[build]\n"),
            ("vercel.json", "{}"),
            ("sentry.properties", ""),
            ("supabase/config.toml", ""),
            ("prisma/schema.prisma", ""),
            ("wrangler.toml", ""),
            (".linear/x", ""),
            ("package.json", r#"{"dependencies":{"posthog-js":"1","stripe":"1"}}"#),
        ]);
        assert_eq!(
            ids(&got),
            ["netlify", "vercel", "sentry", "supabase", "prisma", "cloudflare"]
        );
    }

    #[test]
    fn an_empty_folder_gives_nothing() {
        assert!(scan(&[]).is_empty());
        assert!(for_folder(Path::new("/nonexistent-bandito-folder"), &catalog(), &[]).is_empty());
    }

    #[test]
    fn a_file_that_does_not_read_skips_only_its_rule() {
        let got = scan(&[("package.json", "{not json"), ("netlify.toml", "[build]\n")]);
        assert_eq!(ids(&got), ["netlify"]);
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("package.json"), [0xff, 0xfe, 0x00]).unwrap();
        std::fs::write(dir.path().join("netlify.toml"), "[build]\n").unwrap();
        assert_eq!(ids(&for_folder(dir.path(), &catalog(), &[])), ["netlify"]);
    }

    #[test]
    fn a_file_over_256_kilobytes_is_skipped() {
        let big = format!(
            r#"{{"dependencies":{{"next":"15"}},"pad":"{}"}}"#,
            "x".repeat(260 * 1024)
        );
        assert!(scan(&[("package.json", big.as_str())]).is_empty());
        let just_under = format!(
            r#"{{"dependencies":{{"next":"15"}},"pad":"{}"}}"#,
            "x".repeat(200 * 1024)
        );
        assert_eq!(ids(&scan(&[("package.json", just_under.as_str())])), ["vercel"]);
    }

    #[test]
    fn a_readme_is_searched_for_its_first_64_kilobytes_only() {
        let early = format!("linear.app {}", "a".repeat(200 * 1024));
        assert_eq!(ids(&scan(&[("README.md", early.as_str())])), ["linear"]);
        let late = format!("{} linear.app", "a".repeat(100 * 1024));
        assert!(scan(&[("README.md", late.as_str())]).is_empty());
        let huge = format!("linear.app {}", "a".repeat(300 * 1024));
        assert!(scan(&[("README.md", huge.as_str())]).is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn links_never_lead_outside_the_folder() {
        let outside = tempfile::tempdir().unwrap();
        write(outside.path(), "package.json", r#"{"dependencies":{"next":"15"}}"#);
        write(outside.path(), "netlify.toml", "[build]\n");
        write(
            outside.path(),
            ".git/config",
            "[remote \"o\"]\nurl = https://github.com/x/y\n",
        );
        let dir = tempfile::tempdir().unwrap();
        symlink(outside.path().join("package.json"), dir.path().join("package.json")).unwrap();
        symlink(outside.path().join("netlify.toml"), dir.path().join("netlify.toml")).unwrap();
        symlink(outside.path(), dir.path().join("linked")).unwrap();
        std::fs::create_dir(dir.path().join("real")).unwrap();
        symlink(outside.path().join(".git"), dir.path().join("real/.git")).unwrap();
        assert!(for_folder(dir.path(), &catalog(), &[]).is_empty());
        // The folder itself is a link: nothing is read.
        let link = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        write(target.path(), "netlify.toml", "[build]\n");
        let folder = link.path().join("agent");
        symlink(target.path(), &folder).unwrap();
        assert!(for_folder(&folder, &catalog(), &[]).is_empty());
    }

    #[test]
    fn a_remote_of_another_host_or_a_url_section_suggests_nothing() {
        let got = scan(&[(
            ".git/config",
            "[remote \"origin\"]\n\turl = https://example.com/x.git\n[url \"https://github.com/\"]\n\tinsteadOf = gh:\n",
        )]);
        assert!(got.is_empty());
    }

    #[test]
    fn requirement_names_are_read_from_their_start() {
        assert_eq!(
            package_name("Stripe_Py[x]>=1 ; python_version>'3'"),
            Some("stripe-py".into())
        );
        assert_eq!(package_name("stripe # pinned"), Some("stripe".into()));
        assert_eq!(package_name("Stripe is great"), None);
        assert_eq!(package_name("-r other.txt"), None);
    }

    #[test]
    fn remote_hosts_come_from_all_three_address_forms() {
        assert_eq!(url_host("git@github.com:x/y.git").as_deref(), Some("github.com"));
        assert_eq!(url_host("https://GitLab.com:443/x/y").as_deref(), Some("gitlab.com"));
        assert_eq!(url_host("ssh://git@github.com/x/y").as_deref(), Some("github.com"));
    }

    #[test]
    fn addresses_compare_without_case_of_host_or_trailing_slash() {
        assert!(same_address(
            "https://MCP.Sentry.dev/mcp/",
            "https://mcp.sentry.dev/mcp"
        ));
        assert!(!same_address(
            "https://mcp.sentry.dev/other",
            "https://mcp.sentry.dev/mcp"
        ));
    }
}
