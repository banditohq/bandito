//! The daemon's own log, for the app's journal view (`daemon.logs`, see docs/ARCHITECTURE.md#logs).
//!
//! Where the lines are: under systemd (Linux) the journal of the user unit; under launchd and in a
//! background process, `<home>/logs/daemon.log` (see `service::install_plan`). Tracing writes the
//! level as a word on each line (`INFO`, `WARN`, ...), which is how a level filter works.

use crate::service::{self, Paths};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::Command;

/// The most lines one call returns.
pub const MAX_LINES: u32 = 2000;
/// The lines returned when the caller asks for none.
pub const DEFAULT_LINES: u32 = 500;
/// How much of the end of the log file is read: enough for the newest lines of a busy day.
const TAIL_BYTES: u64 = 4 * 1024 * 1024;
/// How many journal lines are read before filtering.
const JOURNAL_SCAN_LINES: u32 = 10_000;

/// A tracing level. Only `Info`, `Warn` and `Error` are asked for; the others appear in lines.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl Level {
    /// The minimum level a caller may ask for: `info`, `warn` or `error`.
    pub fn parse_min(s: &str) -> Option<Level> {
        match s {
            "info" => Some(Level::Info),
            "warn" => Some(Level::Warn),
            "error" => Some(Level::Error),
            _ => None,
        }
    }
}

/// The level tracing wrote on a line: the first of its first four words that names one.
pub fn line_level(line: &str) -> Option<Level> {
    line.split_whitespace().take(4).find_map(|word| match word {
        "TRACE" => Some(Level::Trace),
        "DEBUG" => Some(Level::Debug),
        "INFO" => Some(Level::Info),
        "WARN" => Some(Level::Warn),
        "ERROR" => Some(Level::Error),
        _ => None,
    })
}

/// Removes terminal colour codes (`ESC [ ... m`), which tracing writes when it prints to a terminal.
pub fn strip_ansi(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            for next in chars.by_ref() {
                if next == 'm' {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// The last `count` lines at `min` level or above, in order. A line without a level takes the level
/// of the line before it (`Info` for the first line), so a wrapped error stays with its error.
pub fn select<'a>(lines: impl IntoIterator<Item = &'a str>, min: Option<Level>, count: usize) -> Vec<String> {
    let mut level = Level::Info;
    let mut kept: Vec<String> = Vec::new();
    for line in lines {
        level = line_level(line).unwrap_or(level);
        if min.is_none_or(|m| level >= m) {
            kept.push(strip_ansi(line));
        }
    }
    let skip = kept.len().saturating_sub(count);
    kept.split_off(skip)
}

/// Replaces the secret part of Bandito's tokens (`bdt_` for paired devices, `bat_` for agent sessions)
/// with `••••`, so a log line never carries a usable token. The prefix stays, so a token is still recognisable.
pub fn mask_tokens(text: &str) -> String {
    const PREFIXES: [&str; 2] = ["bdt_", "bat_"];
    /// Shorter bodies are not tokens: a word that only starts like one stays as it is.
    const MIN_BODY: usize = 16;
    let is_token_char = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-';
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    loop {
        let found = PREFIXES
            .iter()
            .filter_map(|p| rest.find(p).map(|at| (at, p.len())))
            .min_by_key(|(at, _)| *at);
        let Some((at, prefix_len)) = found else {
            out.push_str(rest);
            return out;
        };
        let after = &rest[at + prefix_len..];
        let body = after.find(|c: char| !is_token_char(c)).unwrap_or(after.len());
        out.push_str(&rest[..at + prefix_len]);
        if body >= MIN_BODY {
            out.push_str("••••");
        } else {
            out.push_str(&after[..body]);
        }
        rest = &after[body..];
    }
}

/// Where the daemon's lines come from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// The user's systemd journal, for this unit.
    Journal(String),
    /// A log file.
    File(PathBuf),
}

impl Source {
    /// The source for a daemon whose data folder is `home`, decided by how the daemon runs:
    /// a systemd user unit writes to the journal, everything else to the log file.
    pub fn for_home(home: &Path) -> Source {
        let user_home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/"));
        let paths = Paths::new(home, &user_home);
        if cfg!(target_os = "linux") && paths.unit_file.exists() {
            Source::Journal(service::UNIT_NAME.to_string())
        } else {
            Source::File(paths.log_file)
        }
    }

    /// Name shown in the reply.
    pub fn name(&self) -> &'static str {
        match self {
            Source::Journal(_) => "journald",
            Source::File(_) => "file",
        }
    }

    /// The last `count` lines at `min` level or above, read from the source. Nothing is redacted here.
    pub fn read(&self, count: usize, min: Option<Level>) -> io::Result<Vec<String>> {
        let text = match self {
            Source::File(path) => match read_tail(path, TAIL_BYTES)? {
                Some(text) => text,
                None => return Ok(Vec::new()),
            },
            Source::Journal(unit) => read_journal(unit, JOURNAL_SCAN_LINES)?,
        };
        Ok(select(text.lines(), min, count))
    }
}

/// The last `max` bytes of a file, from the first whole line in them. `None` when the file does not exist.
pub fn read_tail(path: &Path, max: u64) -> io::Result<Option<String>> {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let len = file.metadata()?.len();
    let start = len.saturating_sub(max);
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::with_capacity((len - start) as usize);
    file.read_to_end(&mut bytes)?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    if start == 0 {
        return Ok(Some(text));
    }
    // The first line may be cut: drop it.
    Ok(Some(match text.find('\n') {
        Some(at) => text[at + 1..].to_string(),
        None => String::new(),
    }))
}

/// The last `lines` lines of the user's journal for `unit`, as text (`journalctl -o cat`).
pub fn read_journal(unit: &str, lines: u32) -> io::Result<String> {
    let out = Command::new("journalctl")
        .args([
            "--user",
            "-u",
            unit,
            "-n",
            &lines.to_string(),
            "-o",
            "cat",
            "--no-pager",
        ])
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(
            String::from_utf8_lossy(&out.stderr).trim().to_string(),
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    const LINES: &[&str] = &[
        "2026-10-09T10:00:00Z  INFO bandito: started",
        "2026-10-09T10:00:01Z DEBUG bandito::x: noisy",
        "2026-10-09T10:00:02Z  WARN bandito::sched: skipped",
        "  continued warning text",
        "2026-10-09T10:00:03Z ERROR bandito::rpc: failed",
        "2026-10-09T10:00:04Z  INFO bandito: done",
    ];

    #[test]
    fn level_is_read_from_the_first_words() {
        assert_eq!(line_level(LINES[0]), Some(Level::Info));
        assert_eq!(line_level(LINES[2]), Some(Level::Warn));
        assert_eq!(line_level(LINES[4]), Some(Level::Error));
        assert_eq!(line_level("nothing here"), None);
        // A message that says "ERROR" later on is not a level.
        assert_eq!(line_level("2026-10-09T10:00:00Z  INFO a b c ERROR"), Some(Level::Info));
    }

    #[test]
    fn colour_codes_are_removed_from_lines() {
        assert_eq!(
            strip_ansi("\u{1b}[2m2026\u{1b}[0m \u{1b}[32m INFO\u{1b}[0m hi"),
            "2026  INFO hi"
        );
        let coloured = "\u{1b}[31mERROR\u{1b}[0m boom";
        assert_eq!(line_level(coloured), None, "level is read from the raw line only");
        assert_eq!(select([coloured], None, 10), vec!["ERROR boom".to_string()]);
    }

    #[test]
    fn select_keeps_the_last_lines_at_the_minimum_level() {
        let all = select(LINES.iter().copied(), None, 100);
        assert_eq!(all.len(), 6);
        // The continuation line belongs to the WARN above it: WARN, its continuation, then ERROR.
        let warn_up = select(LINES.iter().copied(), Some(Level::Warn), 100);
        assert_eq!(warn_up.len(), 3, "{warn_up:?}");
        assert!(warn_up[1].contains("continued"));
        let errors = select(LINES.iter().copied(), Some(Level::Error), 100);
        assert_eq!(errors, vec![LINES[4].to_string()]);
        // The count keeps the newest lines.
        let last_two = select(LINES.iter().copied(), Some(Level::Info), 2);
        assert_eq!(last_two, vec![LINES[4].to_string(), LINES[5].to_string()]);
        assert!(select(LINES.iter().copied(), None, 0).is_empty());
    }

    #[test]
    fn tokens_keep_their_prefix_and_lose_the_secret_part() {
        let bat = format!("bat_{}", "Ab3_-".repeat(9));
        let bdt = format!("bdt_{}", "0f".repeat(32));
        let text = format!("env BANDITO_AGENT_TOKEN={bat} and device {bdt}.");
        let masked = mask_tokens(&text);
        assert_eq!(masked, "env BANDITO_AGENT_TOKEN=bat_•••• and device bdt_••••.");
        assert!(!masked.contains("Ab3"));
        assert_eq!(mask_tokens("bat_short and bdt_x"), "bat_short and bdt_x");
        assert_eq!(mask_tokens("no token here"), "no token here");
        assert_eq!(mask_tokens(""), "");
    }

    #[test]
    fn tail_reads_the_end_and_drops_a_cut_first_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("daemon.log");
        assert_eq!(read_tail(&path, 100).unwrap(), None);
        std::fs::write(&path, "first line\nsecond line\nthird\n").unwrap();
        assert_eq!(
            read_tail(&path, 1000).unwrap().as_deref(),
            Some("first line\nsecond line\nthird\n")
        );
        // 12 bytes from the end cut "second line": only whole lines come back.
        assert_eq!(read_tail(&path, 12).unwrap().as_deref(), Some("third\n"));
    }

    #[test]
    fn source_reads_a_file_with_level_filter_and_count() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("daemon.log");
        std::fs::write(&path, LINES.join("\n")).unwrap();
        let source = Source::File(path);
        assert_eq!(source.name(), "file");
        let errors = source.read(10, Some(Level::Error)).unwrap();
        assert_eq!(errors, vec![LINES[4].to_string()]);
        assert_eq!(source.read(1, None).unwrap(), vec![LINES[5].to_string()]);
        let missing = Source::File(dir.path().join("none.log"));
        assert!(missing.read(10, None).unwrap().is_empty());
    }
}
