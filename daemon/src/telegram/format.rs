//! Turning an agent's markdown into Telegram HTML, and fitting it in one message. Telegram HTML knows `<b>`, `<code>`
//! and `<pre>` here; `&`, `<` and `>` are always escaped. Nothing is left open: a marker with no partner stays text.

/// Longest message Telegram takes.
pub const MESSAGE_LIMIT: usize = 4096;
/// An answer longer than this many characters of markdown is cut.
pub const ANSWER_CHARS: usize = 3500;

/// The first `max` characters of `s` (characters, not bytes: Cyrillic and emoji are not cut in the middle).
pub fn truncate_chars(s: &str, max: usize) -> &str {
    match s.char_indices().nth(max) {
        Some((end, _)) => &s[..end],
        None => s,
    }
}

/// `&`, `<` and `>` as entities.
pub fn escape_html(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            c => out.push(c),
        }
    }
    out
}

/// The text of Telegram HTML as plain text: tags dropped, entities undone. For a message Telegram refused to parse.
pub fn plain_from_html(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' if in_tag => in_tag = false,
            c if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
}

/// Length as Telegram may count it: UTF-16 units, the larger of the two usual counts.
pub fn utf16_len(s: &str) -> usize {
    s.encode_utf16().count()
}

/// Markdown to Telegram HTML: fenced blocks to `<pre>`, `code` to `<code>`, `**x**` to `<b>`.
pub fn markdown_to_html(src: &str) -> String {
    let mut blocks: Vec<String> = Vec::new();
    let mut fence: Option<Vec<&str>> = None;
    for line in src.split('\n') {
        match &mut fence {
            Some(body) => {
                if line.trim_start().starts_with("```") {
                    let body = std::mem::take(body);
                    fence = None;
                    push_pre(&mut blocks, &body);
                } else {
                    body.push(line);
                }
            }
            None => {
                if line.trim_start().starts_with("```") {
                    fence = Some(Vec::new());
                } else {
                    blocks.push(inline(line, true));
                }
            }
        }
    }
    // A fence never closed (an answer cut short) still ends here.
    if let Some(body) = fence {
        push_pre(&mut blocks, &body);
    }
    blocks.join("\n")
}

fn push_pre(blocks: &mut Vec<String>, body: &[&str]) {
    let text = body.join("\n");
    // Telegram refuses an empty `<pre>`.
    if !text.trim().is_empty() {
        blocks.push(format!("<pre>{}</pre>", escape_html(&text)));
    }
}

/// One line: code spans, then bold (not inside bold).
fn inline(line: &str, allow_bold: bool) -> String {
    let chars: Vec<char> = line.chars().collect();
    let mut out = String::with_capacity(line.len() + 16);
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '`' {
            let run = run_len(&chars, i, '`');
            if let Some(close) = find_run(&chars, i + run, '`', run) {
                let code: String = chars[i + run..close].iter().collect();
                if !code.trim().is_empty() {
                    out.push_str("<code>");
                    out.push_str(&escape_html(&code));
                    out.push_str("</code>");
                    i = close + run;
                    continue;
                }
            }
            out.extend(std::iter::repeat_n('`', run));
            i += run;
            continue;
        }
        if allow_bold && c == '*' && chars.get(i + 1) == Some(&'*') {
            let content_start = i + 2;
            if let Some(close) = find_bold_close(&chars, content_start) {
                let content: String = chars[content_start..close].iter().collect();
                if !content.trim().is_empty() {
                    out.push_str("<b>");
                    out.push_str(&inline(&content, false));
                    out.push_str("</b>");
                    i = close + 2;
                    continue;
                }
            }
            out.push_str("**");
            i += 2;
            continue;
        }
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            c => out.push(c),
        }
        i += 1;
    }
    out
}

fn run_len(chars: &[char], at: usize, c: char) -> usize {
    chars[at..].iter().take_while(|x| **x == c).count()
}

/// The start of the next run of exactly `len` of `c`, from `from`.
fn find_run(chars: &[char], from: usize, c: char, len: usize) -> Option<usize> {
    let mut i = from;
    while i < chars.len() {
        if chars[i] == c {
            let run = run_len(chars, i, c);
            if run == len {
                return Some(i);
            }
            i += run;
        } else {
            i += 1;
        }
    }
    None
}

/// The `**` that closes a bold span opened just before `from`, skipping code spans.
fn find_bold_close(chars: &[char], from: usize) -> Option<usize> {
    let mut i = from;
    while i + 1 < chars.len() {
        if chars[i] == '`' {
            let run = run_len(chars, i, '`');
            match find_run(chars, i + run, '`', run) {
                Some(close) => i = close + run,
                None => i += run,
            }
        } else if chars[i] == '*' && chars[i + 1] == '*' && i > from {
            return Some(i);
        } else {
            i += 1;
        }
    }
    None
}

/// An agent's answer as one HTML message: the name in bold, then the text. A text over [`ANSWER_CHARS`] is cut and
/// `notice` (where to read the rest) follows; whatever the escaping makes of it, the message stays within
/// [`MESSAGE_LIMIT`].
pub fn format_answer(name: &str, text: &str, notice: &str) -> String {
    let head = format!("<b>{}</b>\n", escape_html(name));
    let mut limit = ANSWER_CHARS;
    loop {
        let cut = truncate_chars(text, limit);
        let cut_short = cut.len() < text.len();
        let mut html = format!("{head}{}", markdown_to_html(cut));
        if cut_short {
            html.push_str("\n\n");
            html.push_str(&escape_html(notice));
        }
        if utf16_len(&html) <= MESSAGE_LIMIT || limit == 0 {
            return html;
        }
        // Escaping and tags made it longer: take off what is over, and a little more, until it fits.
        let over = utf16_len(&html) - MESSAGE_LIMIT;
        limit = limit.saturating_sub(over.div_ceil(2).max(1));
    }
}
