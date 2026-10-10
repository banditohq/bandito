//! Slash commands of an agent's CLI: what the agent can run (`commands.list`), how a
//! `/name args` message reaches the runtime, and installing commands and skills on the
//! server. See docs/ARCHITECTURE.md#commands.

use crate::event::Source;
use crate::runtime::RuntimeKind;
use crate::store::Agent;
use crate::supervisor::Inbound;
use anyhow::{Context, Result, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::{Component, Path, PathBuf};

/// Largest command or `SKILL.md` file that is listed or expanded, in bytes.
pub const MAX_FILE_BYTES: u64 = 256 * 1024;
/// Commands listed for one agent.
pub const MAX_COMMANDS: usize = 500;
/// Folders below `commands/` or `skills/` that are searched.
pub const MAX_DEPTH: usize = 4;
/// Files one install may carry.
pub const MAX_INSTALL_FILES: usize = 50;
/// Decoded bytes one install may carry, in total.
pub const MAX_INSTALL_BYTES: usize = 2 * 1024 * 1024;

/// Where a command comes from. When names clash, the source that sorts first wins.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandSource {
    Project,
    User,
    Skill,
    CodexPrompt,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Command {
    pub name: String,
    pub description: Option<String>,
    pub args_hint: Option<String>,
    pub source: CommandSource,
    /// The command's `.md` file, or the skill's `SKILL.md`, on the server.
    pub path: PathBuf,
    /// The CLI runs it itself, so the message goes to it as typed.
    pub runtime_native: bool,
}

/// The front matter keys the daemon reads.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Meta {
    pub name: Option<String>,
    pub description: Option<String>,
    pub args_hint: Option<String>,
}

/// Commands and skills an agent can run: the agent's folder (`cwd`) and, when there is one,
/// the daemon user's home (`home`). Sorted by source, then name.
///
/// Claude runs its own commands and skills (`runtime_native`); for every other runtime the
/// daemon expands them, so one command works for every agent.
pub fn discover(home: Option<&Path>, cwd: &Path, runtime: RuntimeKind) -> Vec<Command> {
    let native = runtime == RuntimeKind::Claude;
    let mut out = Vec::new();
    let project = cwd.join(".claude");
    collect_markdown(&project.join("commands"), CommandSource::Project, native, &mut out);
    collect_skills(&project.join("skills"), native, &mut out);
    if let Some(home) = home {
        collect_markdown(&home.join(".claude/commands"), CommandSource::User, native, &mut out);
        collect_skills(&home.join(".claude/skills"), native, &mut out);
        collect_codex_prompts(&home.join(".codex/prompts"), &mut out);
    }
    out.sort_by(|a, b| (a.source, &a.name).cmp(&(b.source, &b.name)));
    out
}

fn collect_markdown(root: &Path, source: CommandSource, native: bool, out: &mut Vec<Command>) {
    walk_markdown(root, root, 0, source, native, out);
}

fn walk_markdown(root: &Path, dir: &Path, depth: usize, source: CommandSource, native: bool, out: &mut Vec<Command>) {
    for entry in sorted_entries(dir) {
        if out.len() >= MAX_COMMANDS {
            return;
        }
        let path = entry.path();
        // `file_type` does not follow symlinks, so links are skipped.
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            if depth < MAX_DEPTH {
                walk_markdown(root, &path, depth + 1, source, native, out);
            }
        } else if kind.is_file() && path.extension().is_some_and(|e| e == "md") {
            let Some(name) = markdown_name(root, &path) else {
                continue;
            };
            if let Some(cmd) = command_from(&path, name, source, native) {
                out.push(cmd);
            }
        }
    }
}

fn collect_skills(root: &Path, native: bool, out: &mut Vec<Command>) {
    for entry in sorted_entries(root) {
        if out.len() >= MAX_COMMANDS {
            return;
        }
        if !entry.file_type().is_ok_and(|t| t.is_dir()) {
            continue;
        }
        let skill = entry.path().join("SKILL.md");
        let Ok(text) = read_limited(&skill) else { continue };
        let (meta, _) = parse_front_matter(&text);
        let folder = entry.file_name().to_string_lossy().into_owned();
        let name = meta.name.unwrap_or(folder);
        if !valid_name(&name) {
            continue;
        }
        out.push(Command {
            name,
            description: meta.description,
            args_hint: meta.args_hint,
            source: CommandSource::Skill,
            path: skill,
            runtime_native: native,
        });
    }
}

/// `~/.codex/prompts/*.md`, one folder level only.
fn collect_codex_prompts(root: &Path, out: &mut Vec<Command>) {
    for entry in sorted_entries(root) {
        if out.len() >= MAX_COMMANDS {
            return;
        }
        let path = entry.path();
        if !entry.file_type().is_ok_and(|t| t.is_file()) || path.extension().is_none_or(|e| e != "md") {
            continue;
        }
        let Some(name) = path.file_stem().and_then(|s| s.to_str()).map(str::to_string) else {
            continue;
        };
        if !valid_name(&name) {
            continue;
        }
        if let Some(cmd) = command_from(&path, name, CommandSource::CodexPrompt, false) {
            out.push(cmd);
        }
    }
}

/// Directory entries in name order, so that the listing is stable.
fn sorted_entries(dir: &Path) -> Vec<fs::DirEntry> {
    let Ok(read) = fs::read_dir(dir) else { return Vec::new() };
    let mut entries: Vec<fs::DirEntry> = read.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    entries
}

/// `commands/git/commit.md` is `git:commit`.
fn markdown_name(root: &Path, path: &Path) -> Option<String> {
    let rel = path.strip_prefix(root).ok()?.with_extension("");
    let parts: Option<Vec<&str>> = rel
        .components()
        .map(|c| match c {
            Component::Normal(s) => s.to_str(),
            _ => None,
        })
        .collect();
    let name = parts?.join(":");
    valid_name(&name).then_some(name)
}

fn command_from(path: &Path, name: String, source: CommandSource, native: bool) -> Option<Command> {
    let text = read_limited(path).ok()?;
    let (meta, _) = parse_front_matter(&text);
    Some(Command {
        name,
        description: meta.description,
        args_hint: meta.args_hint,
        source,
        path: path.to_path_buf(),
        runtime_native: native,
    })
}

/// Names the app can type after `/`: letters, digits, `_ : . -`, not starting with a dot.
fn valid_name(name: &str) -> bool {
    name.chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | ':' | '.' | '-'))
}

/// The text of a regular file (a symlink is refused) of at most `MAX_FILE_BYTES`.
fn read_limited(path: &Path) -> Result<String> {
    let meta = fs::symlink_metadata(path).with_context(|| format!("could not read {}", path.display()))?;
    if !meta.file_type().is_file() {
        bail!("{} is not a regular file", path.display());
    }
    if meta.len() > MAX_FILE_BYTES {
        bail!("{} is over 256 KiB", path.display());
    }
    fs::read_to_string(path).with_context(|| format!("could not read {}", path.display()))
}

/// Splits a leading `---` block off a file. Only top-level `key: value` lines are read
/// (nested and comment lines are skipped, quotes around a value are removed). Returns the
/// keys and the body after the closing `---`. Without a closed block, the whole text is body.
pub fn parse_front_matter(text: &str) -> (Meta, &str) {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut lines = text.split_inclusive('\n');
    if lines.next().map(str::trim_end) != Some("---") {
        return (Meta::default(), text);
    }
    let mut consumed = text.find('\n').map_or(text.len(), |i| i + 1);
    let mut meta = Meta::default();
    let mut args = None;
    for line in lines {
        consumed += line.len();
        let trimmed = line.trim_end();
        if trimmed == "---" {
            // `argument-hint` wins over the older `args` key, whatever the order in the file.
            meta.args_hint = meta.args_hint.or(args);
            return (meta, &text[consumed..]);
        }
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with(char::is_whitespace) {
            continue;
        }
        let Some((key, value)) = trimmed.split_once(':') else {
            continue;
        };
        let value = unquote(value.trim());
        let value = (!value.is_empty()).then(|| value.to_string());
        match key.trim() {
            "name" => meta.name = value,
            "description" => meta.description = value,
            "argument-hint" => meta.args_hint = value,
            "args" => args = value,
            _ => {}
        }
    }
    (Meta::default(), text)
}

fn unquote(value: &str) -> &str {
    let b = value.as_bytes();
    if value.len() >= 2 && (b[0] == b'"' || b[0] == b'\'') && b[value.len() - 1] == b[0] {
        &value[1..value.len() - 1]
    } else {
        value
    }
}

/// The text a runtime gets when `cmd` is called with `args`: the file without its front
/// matter, with `$ARGUMENTS` and `$1`…`$9` filled in. A file without placeholders gets the
/// arguments appended. A skill is wrapped in a short instruction instead.
pub fn expand(cmd: &Command, args: &str) -> Result<String> {
    let text = read_limited(&cmd.path).with_context(|| format!("could not read /{}", cmd.name))?;
    let (_, body) = parse_front_matter(&text);
    let body = body.trim();
    if cmd.source == CommandSource::Skill {
        return Ok(if args.is_empty() {
            format!("Use the skill below.\n\n{body}")
        } else {
            format!("Use the skill below.\n\n{body}\n\nTask: {args}")
        });
    }
    Ok(fill(body, args))
}

/// One pass over the body, so text that a placeholder brings in is never expanded again.
fn fill(body: &str, args: &str) -> String {
    let words = split_words(args);
    let mut out = String::with_capacity(body.len() + args.len());
    let mut used = false;
    let mut rest = body;
    while let Some(at) = rest.find('$') {
        out.push_str(&rest[..at]);
        let tail = &rest[at..];
        if let Some(after) = tail.strip_prefix("$ARGUMENTS") {
            out.push_str(args);
            used = true;
            rest = after;
            continue;
        }
        match tail.as_bytes().get(1).copied() {
            Some(d @ b'1'..=b'9') => {
                out.push_str(words.get((d - b'1') as usize).map_or("", String::as_str));
                used = true;
                rest = &tail[2..];
            }
            _ => {
                out.push('$');
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    if !used && !args.is_empty() {
        format!("{}\n\nArguments: {args}", out.trim_end())
    } else {
        out
    }
}

/// Splits arguments like a shell does for simple cases: whitespace separates words, `"…"`
/// and `'…'` group them (single quotes take everything literally), and a backslash escapes
/// the next character outside single quotes.
pub fn split_words(args: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut cur = String::new();
    let mut in_word = false;
    let mut quote: Option<char> = None;
    let mut chars = args.chars().peekable();
    while let Some(c) = chars.next() {
        match quote {
            Some(q) if c == q => quote = None,
            Some('"') if c == '\\' => match chars.peek().copied() {
                Some(n @ ('"' | '\\')) => {
                    cur.push(n);
                    chars.next();
                }
                _ => cur.push(c),
            },
            Some(_) => cur.push(c),
            None if c.is_whitespace() => {
                if in_word {
                    words.push(std::mem::take(&mut cur));
                    in_word = false;
                }
            }
            None if c == '"' || c == '\'' => {
                quote = Some(c);
                in_word = true;
            }
            None if c == '\\' => {
                if let Some(n) = chars.next() {
                    cur.push(n);
                }
                in_word = true;
            }
            None => {
                cur.push(c);
                in_word = true;
            }
        }
    }
    if in_word {
        words.push(cur);
    }
    words
}

/// `/name rest` → `("name", "rest")`. The name ends at the first character outside
/// `[A-Za-z0-9_:.-]`, and that must be a space or the end of the text (`/a/b` is no command).
pub fn parse_slash(text: &str) -> Option<(&str, &str)> {
    let rest = text.strip_prefix('/')?;
    let end = rest
        .find(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '_' | ':' | '.' | '-')))
        .unwrap_or(rest.len());
    let name = &rest[..end];
    if name.is_empty() {
        return None;
    }
    let after = &rest[end..];
    if !after.is_empty() && !after.starts_with(char::is_whitespace) {
        return None;
    }
    Some((name, after.trim()))
}

/// A message as the runtime should receive it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prepared {
    /// Text for the runtime.
    pub text: String,
    /// What the person typed, when `text` is its expansion. The thread shows this.
    pub typed: Option<String>,
    /// Name of the slash command in the message, when one was recognised.
    pub command: Option<String>,
}

impl Prepared {
    /// The text goes as it is, with no command.
    pub fn plain(text: &str) -> Self {
        Self {
            text: text.to_string(),
            typed: None,
            command: None,
        }
    }

    pub fn into_inbound(self, source: Source) -> Inbound {
        Inbound {
            text: self.text,
            typed: self.typed,
            command: self.command,
            source,
            from_agent: None,
            hops: 0,
            chain: None,
            reply_to: None,
            attachments: Vec::new(),
            mentions: Vec::new(),
            mention_note: None,
        }
    }
}

/// How a message that starts with `/name` reaches the runtime. A command the runtime runs
/// itself goes as typed. Any other known command is expanded, and the thread keeps what was
/// typed. An unknown `/x` goes as typed, for the CLI to deal with.
pub fn resolve(home: Option<&Path>, cwd: &Path, runtime: RuntimeKind, text: &str) -> Result<Prepared> {
    let Some((name, args)) = parse_slash(text) else {
        return Ok(Prepared::plain(text));
    };
    // `discover` is sorted by priority, so the first match is the one that runs.
    let Some(cmd) = discover(home, cwd, runtime).into_iter().find(|c| c.name == name) else {
        return Ok(Prepared::plain(text));
    };
    let command = Some(name.to_string());
    if cmd.runtime_native {
        return Ok(Prepared {
            text: text.to_string(),
            typed: None,
            command,
        });
    }
    Ok(Prepared {
        text: expand(&cmd, args)?,
        typed: Some(text.to_string()),
        command,
    })
}

/// `resolve` for a message to `agent`. `None` (an unknown agent) sends the text as typed.
pub fn prepare(agent: Option<&Agent>, text: &str) -> Result<Prepared> {
    match agent {
        Some(a) => resolve(dirs::home_dir().as_deref(), Path::new(&a.cwd), a.runtime, text),
        None => Ok(Prepared::plain(text)),
    }
}

/// An install that failed. `reason` is the stable code the app reads from `error.data.reason`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallError {
    pub reason: &'static str,
    pub message: String,
}

impl std::fmt::Display for InstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

fn fail<T>(reason: &'static str, message: impl Into<String>) -> Result<T, InstallError> {
    Err(InstallError {
        reason,
        message: message.into(),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InstallKind {
    Command,
    Skill,
}

/// One file of an install: `path` inside the command's or skill's folder, `content` in base64.
#[derive(Debug, Clone, Deserialize)]
pub struct InstallFile {
    pub path: String,
    pub content: String,
}

/// Writes a command or skill under `base`, which is the daemon user's home or the agent's
/// folder. A command is `<base>/.claude/commands/<name>.md` (`git:commit` is
/// `commands/git/commit.md`). A skill is the folder `<base>/.claude/skills/<name>/`, and must
/// contain `SKILL.md`. Everything is checked before the first write. Without `overwrite`, an
/// existing command or skill is an error. With it, a skill folder is replaced as a whole.
pub fn install(
    base: &Path,
    kind: InstallKind,
    name: &str,
    files: &[InstallFile],
    overwrite: bool,
) -> Result<PathBuf, InstallError> {
    let segments: Vec<&str> = name.split(':').collect();
    let names_ok =
        segments.iter().all(|s| is_install_segment(s)) && (kind == InstallKind::Command || segments.len() == 1);
    if !names_ok {
        return fail("invalid_name", format!("bad name {name}"));
    }
    if files.len() > MAX_INSTALL_FILES {
        return fail("too_many_files", format!("at most {MAX_INSTALL_FILES} files"));
    }
    if files.is_empty() || (kind == InstallKind::Command && files.len() != 1) {
        return fail("file_count", "a command is one .md file; a skill needs SKILL.md");
    }

    let mut decoded: Vec<(PathBuf, Vec<u8>)> = Vec::with_capacity(files.len());
    let mut seen = HashSet::new();
    let mut total = 0usize;
    for f in files {
        let Some(rel) = safe_relative(&f.path) else {
            return fail("invalid_path", format!("bad path {}", f.path));
        };
        if !seen.insert(rel.clone()) {
            return fail("invalid_path", format!("duplicate path {}", f.path));
        }
        let bytes = STANDARD
            .decode(&f.content)
            .or_else(|_| fail("invalid_content", format!("{} is not base64", f.path)))?;
        total += bytes.len();
        decoded.push((rel, bytes));
    }
    if total > MAX_INSTALL_BYTES {
        return fail("too_large", format!("at most {MAX_INSTALL_BYTES} bytes in total"));
    }
    for (rel, bytes) in &decoded {
        let is_md = kind == InstallKind::Command || rel == Path::new("SKILL.md");
        if is_md && bytes.len() as u64 > MAX_FILE_BYTES {
            return fail("too_large", format!("{} is over 256 KiB", rel.display()));
        }
        if is_md && std::str::from_utf8(bytes).is_err() {
            return fail("invalid_content", format!("{} is not UTF-8", rel.display()));
        }
    }

    let root = base.join(".claude");
    let target = match kind {
        InstallKind::Command => {
            let mut target = root.join("commands");
            for s in &segments[..segments.len() - 1] {
                target.push(s);
            }
            target.join(format!("{}.md", segments[segments.len() - 1]))
        }
        InstallKind::Skill => {
            if !decoded.iter().any(|(rel, _)| rel == Path::new("SKILL.md")) {
                return fail("missing_skill_file", "a skill needs SKILL.md");
            }
            root.join("skills").join(name)
        }
    };
    let exists = fs::symlink_metadata(&target).is_ok();
    if exists && !overwrite {
        return fail("exists", format!("{} already exists", target.display()));
    }

    match kind {
        InstallKind::Command => {
            let (_, bytes) = &decoded[0];
            write_file(&target, bytes)?;
        }
        InstallKind::Skill => {
            if exists {
                fs::remove_dir_all(&target).map_err(|e| io_error(&target, &e))?;
            }
            for (rel, bytes) in &decoded {
                write_file(&target.join(rel), bytes)?;
            }
        }
    }
    Ok(target)
}

/// One segment of a command or skill name: letters, digits, `_` and `-`.
fn is_install_segment(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
}

/// A relative path that stays inside its folder: no root, no `..`, no `.`, no backslash.
fn safe_relative(path: &str) -> Option<PathBuf> {
    if path.is_empty() || path.contains(['\\', '\0']) {
        return None;
    }
    let mut out = PathBuf::new();
    for c in Path::new(path).components() {
        match c {
            Component::Normal(s) => out.push(s),
            _ => return None,
        }
    }
    (!out.as_os_str().is_empty()).then_some(out)
}

fn write_file(path: &Path, bytes: &[u8]) -> Result<(), InstallError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| io_error(parent, &e))?;
    }
    fs::write(path, bytes).map_err(|e| io_error(path, &e))
}

fn io_error(path: &Path, e: &std::io::Error) -> InstallError {
    InstallError {
        reason: "io",
        message: format!("{}: {e}", path.display()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;
    use tempfile::TempDir;

    fn put(path: &Path, content: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, content).unwrap();
    }

    fn listed(cmds: &[Command]) -> Vec<(&str, CommandSource)> {
        cmds.iter().map(|c| (c.name.as_str(), c.source)).collect()
    }

    fn command_at(path: &Path, source: CommandSource) -> Command {
        Command {
            name: "x".into(),
            description: None,
            args_hint: None,
            source,
            path: path.to_path_buf(),
            runtime_native: false,
        }
    }

    fn file(path: &str, content: &str) -> InstallFile {
        InstallFile {
            path: path.into(),
            content: STANDARD.encode(content),
        }
    }

    #[test]
    fn discovers_user_project_namespaced_and_codex_commands() {
        let home = TempDir::new().unwrap();
        let cwd = TempDir::new().unwrap();
        put(&home.path().join(".claude/commands/review.md"), "Review it");
        put(&home.path().join(".claude/commands/git/commit.md"), "Commit");
        put(&cwd.path().join(".claude/commands/deploy.md"), "Deploy");
        put(&home.path().join(".codex/prompts/fix.md"), "Fix");

        let cmds = discover(Some(home.path()), cwd.path(), RuntimeKind::Claude);
        assert_eq!(
            listed(&cmds),
            vec![
                ("deploy", CommandSource::Project),
                ("git:commit", CommandSource::User),
                ("review", CommandSource::User),
                ("fix", CommandSource::CodexPrompt),
            ]
        );
        let native: Vec<bool> = cmds.iter().map(|c| c.runtime_native).collect();
        assert_eq!(native, vec![true, true, true, false]);

        let codex = discover(Some(home.path()), cwd.path(), RuntimeKind::Codex);
        assert_eq!(codex.len(), 4, "every agent sees every source");
        assert!(codex.iter().all(|c| !c.runtime_native), "Codex runs none natively");
    }

    #[test]
    fn without_a_home_only_the_project_is_listed() {
        let cwd = TempDir::new().unwrap();
        put(&cwd.path().join(".claude/commands/deploy.md"), "Deploy");
        let cmds = discover(None, cwd.path(), RuntimeKind::Claude);
        assert_eq!(listed(&cmds), vec![("deploy", CommandSource::Project)]);
    }

    #[test]
    fn discovers_skills_named_by_front_matter_or_folder() {
        let home = TempDir::new().unwrap();
        let cwd = TempDir::new().unwrap();
        put(
            &home.path().join(".claude/skills/pdf/SKILL.md"),
            "---\nname: pdf-tools\ndescription: \"Work with PDFs\"\n---\nRead PDFs.",
        );
        put(&cwd.path().join(".claude/skills/notes/SKILL.md"), "Take notes.");
        put(&home.path().join(".claude/skills/empty/README.md"), "no SKILL.md here");

        let cmds = discover(Some(home.path()), cwd.path(), RuntimeKind::Claude);
        assert_eq!(
            listed(&cmds),
            vec![("notes", CommandSource::Skill), ("pdf-tools", CommandSource::Skill)]
        );
        assert_eq!(cmds[1].description.as_deref(), Some("Work with PDFs"));
        assert!(cmds.iter().all(|c| c.runtime_native));
    }

    #[test]
    fn reads_front_matter_keys_and_strips_quotes() {
        let text = "---\ndescription: \"Say hi\"\nargument-hint: '<who>'\nargs: ignored\n---\nHello $1\n";
        let (meta, body) = parse_front_matter(text);
        assert_eq!(meta.description.as_deref(), Some("Say hi"));
        assert_eq!(meta.args_hint.as_deref(), Some("<who>"));
        assert_eq!(body, "Hello $1\n");
    }

    #[test]
    fn args_key_is_the_hint_when_argument_hint_is_missing() {
        let (meta, _) = parse_front_matter("---\nargs: <file>\n---\nx");
        assert_eq!(meta.args_hint.as_deref(), Some("<file>"));
    }

    #[test]
    fn text_without_a_closed_front_matter_is_all_body() {
        for text in ["Plain text\n", "---\ndescription: x\nno closing line\n"] {
            let (meta, body) = parse_front_matter(text);
            assert_eq!(meta, Meta::default());
            assert_eq!(body, text);
        }
    }

    #[test]
    fn empty_and_nested_values_are_ignored() {
        let (meta, body) = parse_front_matter("---\ndescription:\nmeta:\n  nested: 1\n# comment\n---\nBody");
        assert_eq!(meta, Meta::default());
        assert_eq!(body, "Body");
    }

    #[test]
    fn skips_oversized_symlinked_and_badly_named_files() {
        let cwd = TempDir::new().unwrap();
        let dir = cwd.path().join(".claude/commands");
        put(&dir.join("ok.md"), "ok");
        put(&dir.join("edge.md"), &"x".repeat(MAX_FILE_BYTES as usize));
        put(&dir.join("big.md"), &"x".repeat(MAX_FILE_BYTES as usize + 1));
        put(&dir.join("bad name.md"), "space in the name");
        #[cfg(unix)]
        link_outside(&dir);

        let cmds = discover(None, cwd.path(), RuntimeKind::Claude);
        let names: Vec<&str> = cmds.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["edge", "ok"]);
    }

    #[cfg(unix)]
    fn link_outside(dir: &Path) {
        let outside = TempDir::new().unwrap();
        put(&outside.path().join("secret.md"), "outside");
        std::os::unix::fs::symlink(outside.path().join("secret.md"), dir.join("link.md")).unwrap();
        std::os::unix::fs::symlink(outside.path(), dir.join("linked-dir")).unwrap();
    }

    #[test]
    fn lists_at_most_500_commands() {
        let cwd = TempDir::new().unwrap();
        for i in 0..MAX_COMMANDS + 10 {
            put(&cwd.path().join(format!(".claude/commands/c{i:04}.md")), "x");
        }
        assert_eq!(discover(None, cwd.path(), RuntimeKind::Claude).len(), MAX_COMMANDS);
    }

    #[test]
    fn walks_at_most_four_folders_deep() {
        let cwd = TempDir::new().unwrap();
        let dir = cwd.path().join(".claude/commands");
        put(&dir.join("a/b/c/d/in.md"), "x");
        put(&dir.join("a/b/c/d/e/out.md"), "x");
        let names: Vec<String> = discover(None, cwd.path(), RuntimeKind::Claude)
            .into_iter()
            .map(|c| c.name)
            .collect();
        assert_eq!(names, vec!["a:b:c:d:in"]);
    }

    #[test]
    fn arguments_placeholder_takes_the_whole_argument_string() {
        let cwd = TempDir::new().unwrap();
        let path = cwd.path().join("fix.md");
        put(&path, "---\ndescription: Fix\n---\nFix: $ARGUMENTS\nAgain: $ARGUMENTS");
        let cmd = command_at(&path, CommandSource::Project);
        assert_eq!(
            expand(&cmd, "the login  bug").unwrap(),
            "Fix: the login  bug\nAgain: the login  bug"
        );
    }

    #[test]
    fn numbered_placeholders_take_shell_like_words() {
        let cwd = TempDir::new().unwrap();
        let path = cwd.path().join("pair.md");
        put(&path, "A=$1 B=$2 C=$3");
        let cmd = command_at(&path, CommandSource::User);
        assert_eq!(
            expand(&cmd, r#""hello world" 'x y' z"#).unwrap(),
            "A=hello world B=x y C=z"
        );
        assert_eq!(expand(&cmd, "one").unwrap(), "A=one B= C=");
    }

    #[test]
    fn placeholder_values_are_not_expanded_again() {
        let cwd = TempDir::new().unwrap();
        let path = cwd.path().join("echo.md");
        put(&path, "Say $ARGUMENTS and $1");
        let cmd = command_at(&path, CommandSource::User);
        assert_eq!(expand(&cmd, "$1 x").unwrap(), "Say $1 x and $1");
    }

    #[test]
    fn text_without_placeholders_gets_the_arguments_appended() {
        let cwd = TempDir::new().unwrap();
        let path = cwd.path().join("plain.md");
        put(&path, "Do the thing.\n");
        let cmd = command_at(&path, CommandSource::User);
        assert_eq!(expand(&cmd, "now").unwrap(), "Do the thing.\n\nArguments: now");
        assert_eq!(expand(&cmd, "").unwrap(), "Do the thing.");
    }

    #[test]
    fn front_matter_is_not_part_of_the_expansion() {
        let cwd = TempDir::new().unwrap();
        let path = cwd.path().join("body.md");
        put(&path, "---\ndescription: d\n---\nBody $1");
        let cmd = command_at(&path, CommandSource::User);
        assert_eq!(expand(&cmd, "x").unwrap(), "Body x");
    }

    #[test]
    fn skill_text_uses_the_skill_template() {
        let cwd = TempDir::new().unwrap();
        let path = cwd.path().join("SKILL.md");
        put(&path, "---\nname: s\n---\nDo X.\n");
        let cmd = command_at(&path, CommandSource::Skill);
        assert_eq!(
            expand(&cmd, "fast").unwrap(),
            "Use the skill below.\n\nDo X.\n\nTask: fast"
        );
        assert_eq!(expand(&cmd, "").unwrap(), "Use the skill below.\n\nDo X.");
    }

    #[test]
    fn split_words_groups_quotes_and_escapes() {
        assert_eq!(
            split_words(r#"a "b c" 'd e' f\ g "" "#),
            vec!["a", "b c", "d e", "f g", ""]
        );
        assert_eq!(split_words(r#""open quote"#), vec!["open quote"]);
    }

    #[test]
    fn parse_slash_reads_the_name_and_the_rest() {
        assert_eq!(parse_slash("/deploy prod now"), Some(("deploy", "prod now")));
        assert_eq!(parse_slash("/review"), Some(("review", "")));
        assert_eq!(parse_slash("/x.y:z-1  p "), Some(("x.y:z-1", "p")));
        assert_eq!(parse_slash("/a/b"), None);
        assert_eq!(parse_slash("/"), None);
        assert_eq!(parse_slash("hi /x"), None);
        assert_eq!(parse_slash("/ spaced"), None);
    }

    #[test]
    fn resolve_keeps_native_commands_and_expands_for_codex() {
        let home = TempDir::new().unwrap();
        let cwd = TempDir::new().unwrap();
        put(
            &cwd.path().join(".claude/commands/deploy.md"),
            "---\ndescription: Deploy\n---\nDeploy to $1 now.",
        );
        let claude = resolve(Some(home.path()), cwd.path(), RuntimeKind::Claude, "/deploy prod").unwrap();
        assert_eq!(
            claude,
            Prepared {
                text: "/deploy prod".into(),
                typed: None,
                command: Some("deploy".into()),
            }
        );

        let codex = resolve(Some(home.path()), cwd.path(), RuntimeKind::Codex, "/deploy prod").unwrap();
        assert_eq!(
            codex,
            Prepared {
                text: "Deploy to prod now.".into(),
                typed: Some("/deploy prod".into()),
                command: Some("deploy".into()),
            }
        );

        for (runtime, text) in [(RuntimeKind::Codex, "/nope x"), (RuntimeKind::Claude, "just text")] {
            let plain = resolve(Some(home.path()), cwd.path(), runtime, text).unwrap();
            assert_eq!(
                plain,
                Prepared {
                    text: text.into(),
                    typed: None,
                    command: None,
                }
            );
        }
    }

    #[test]
    fn installs_a_command_into_claude_commands_and_refuses_to_overwrite() {
        let home = TempDir::new().unwrap();
        let files = [file("commit.md", "Commit it")];
        let path = install(home.path(), InstallKind::Command, "git:commit", &files, false).unwrap();
        assert_eq!(path, home.path().join(".claude/commands/git/commit.md"));
        assert_eq!(fs::read_to_string(&path).unwrap(), "Commit it");

        let err = install(home.path(), InstallKind::Command, "git:commit", &files, false).unwrap_err();
        assert_eq!(err.reason, "exists");

        let updated = [file("commit.md", "Commit better")];
        install(home.path(), InstallKind::Command, "git:commit", &updated, true).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "Commit better");
    }

    #[test]
    fn installs_a_skill_folder_and_overwrite_replaces_it() {
        let home = TempDir::new().unwrap();
        let first = [
            file("SKILL.md", "---\nname: pdf\n---\nRead PDFs."),
            file("scripts/run.sh", "echo 1"),
        ];
        let dir = install(home.path(), InstallKind::Skill, "pdf", &first, false).unwrap();
        assert_eq!(dir, home.path().join(".claude/skills/pdf"));
        assert_eq!(fs::read_to_string(dir.join("scripts/run.sh")).unwrap(), "echo 1");

        let err = install(home.path(), InstallKind::Skill, "pdf", &first, false).unwrap_err();
        assert_eq!(err.reason, "exists");

        let second = [file("SKILL.md", "Only skill.")];
        install(home.path(), InstallKind::Skill, "pdf", &second, true).unwrap();
        assert_eq!(fs::read_to_string(dir.join("SKILL.md")).unwrap(), "Only skill.");
        assert!(
            !dir.join("scripts/run.sh").exists(),
            "overwrite replaces the whole folder"
        );
    }

    #[test]
    fn project_scope_writes_under_the_given_root() {
        let cwd = TempDir::new().unwrap();
        let path = install(
            cwd.path(),
            InstallKind::Command,
            "deploy",
            &[file("deploy.md", "Deploy")],
            false,
        )
        .unwrap();
        assert_eq!(path, cwd.path().join(".claude/commands/deploy.md"));
    }

    #[test]
    fn refuses_unsafe_paths_and_names_and_writes_nothing() {
        let home = TempDir::new().unwrap();
        for bad in ["../x", "/etc/x", "a/../../b", "", "a\\b", "./x"] {
            let files = [file("SKILL.md", "x"), file(bad, "x")];
            let err = install(home.path(), InstallKind::Skill, "s", &files, false).unwrap_err();
            assert_eq!(err.reason, "invalid_path", "{bad}");
        }
        for bad in ["../evil", "a/b", "", "x.y", ".hidden", "sp ace"] {
            let err = install(home.path(), InstallKind::Skill, bad, &[file("SKILL.md", "x")], false).unwrap_err();
            assert_eq!(err.reason, "invalid_name", "{bad}");
        }
        let err = install(home.path(), InstallKind::Command, "a:..:b", &[file("a.md", "x")], false).unwrap_err();
        assert_eq!(err.reason, "invalid_name");
        assert!(!home.path().join(".claude").exists(), "nothing written on errors");
    }

    #[test]
    fn requires_skill_md_and_exactly_one_command_file() {
        let home = TempDir::new().unwrap();
        let err = install(home.path(), InstallKind::Skill, "s", &[file("notes.md", "x")], false).unwrap_err();
        assert_eq!(err.reason, "missing_skill_file");

        let two = [file("a.md", "x"), file("b.md", "y")];
        let err = install(home.path(), InstallKind::Command, "c", &two, false).unwrap_err();
        assert_eq!(err.reason, "file_count");

        let broken = [InstallFile {
            path: "a.md".into(),
            content: "!!! not base64".into(),
        }];
        let err = install(home.path(), InstallKind::Command, "c", &broken, false).unwrap_err();
        assert_eq!(err.reason, "invalid_content");
    }

    #[test]
    fn limits_file_count_and_sizes() {
        let home = TempDir::new().unwrap();
        let mut many = vec![file("SKILL.md", "x")];
        for i in 0..MAX_INSTALL_FILES {
            many.push(file(&format!("f{i}.txt"), "x"));
        }
        let err = install(home.path(), InstallKind::Skill, "s", &many, false).unwrap_err();
        assert_eq!(err.reason, "too_many_files");

        let big = "x".repeat(MAX_FILE_BYTES as usize + 1);
        let err = install(home.path(), InstallKind::Command, "c", &[file("c.md", &big)], false).unwrap_err();
        assert_eq!(err.reason, "too_large");

        let mb = "y".repeat(1024 * 1024);
        let total = [
            file("SKILL.md", "x"),
            file("one.bin", &mb),
            file("two.bin", &mb),
            file("three.bin", &mb),
        ];
        let err = install(home.path(), InstallKind::Skill, "s", &total, false).unwrap_err();
        assert_eq!(err.reason, "too_large");
    }
}
