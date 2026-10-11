//! Text an agent writes that a person reads on a card and that later becomes another agent's instructions or name
//! (docs/ARCHITECTURE.md#agents-creating-agents). What the person reads must be what is stored, so text is cleaned
//! before it is shown and stored, not only when it is drawn: no invisible characters (zero-width, bidi controls,
//! format characters), no control characters, no endless blank lines, and a name whose word mixes alphabets is refused.

/// Unicode category Cf (format) characters: zero-width, bidirectional controls, soft hyphen, tags, and the like.
pub fn is_format(c: char) -> bool {
    matches!(c as u32,
        0x00AD | 0x0600..=0x0605 | 0x061C | 0x06DD | 0x070F | 0x0890..=0x0891 | 0x08E2 | 0x180E
        | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF
        | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3
        | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F)
}

/// A character that starts a new line: `\n`, `\r`, NEL, line and paragraph separators.
fn is_line_break(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0085}' | '\u{2028}' | '\u{2029}')
}

/// Whether the text holds a format or control character (a newline and a tab included).
pub fn has_hidden(text: &str) -> bool {
    text.chars().any(|c| is_format(c) || c.is_control())
}

/// One line: format characters are dropped, every other separator or control (a newline, a tab, a non-breaking
/// space) becomes a space, runs of spaces collapse, the ends are trimmed.
pub fn line(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = false;
    for c in text.chars() {
        if is_format(c) {
            continue;
        }
        if c.is_whitespace() || c.is_control() {
            space = !out.is_empty();
            continue;
        }
        if space {
            out.push(' ');
            space = false;
        }
        out.push(c);
    }
    out
}

/// Several lines: line breaks become `\n`, tabs become spaces, other control and format characters are dropped,
/// the end of each line is trimmed, and a series of more than two blank lines shrinks to two.
pub fn block(text: &str) -> String {
    let mut normal = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\r' && chars.peek() == Some(&'\n') {
            continue;
        }
        if is_line_break(c) {
            normal.push('\n');
        } else if c == '\t' {
            normal.push(' ');
        } else if is_format(c) || c.is_control() {
            continue;
        } else {
            normal.push(c);
        }
    }
    let mut out: Vec<&str> = Vec::new();
    let mut blanks = 0;
    for l in normal.split('\n') {
        let l = l.trim_end();
        if l.is_empty() {
            blanks += 1;
            if blanks > 2 {
                continue;
            }
        } else {
            blanks = 0;
        }
        out.push(l);
    }
    out.join("\n").trim().to_string()
}

/// The writing system of a letter, as far as confusing one with another goes. Digits and marks have none.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Script {
    Latin,
    Cyrillic,
    Greek,
    /// Han, Hiragana and Katakana mix in one Japanese word.
    Cjk,
    Hangul,
    Other(u32),
}

fn script_of(c: char) -> Option<Script> {
    if !c.is_alphabetic() {
        return None;
    }
    let cp = c as u32;
    Some(match cp {
        0x41..=0x5A | 0x61..=0x7A | 0xC0..=0x24F | 0x1E00..=0x1EFF | 0x2C60..=0x2C7F | 0xA720..=0xA7FF => Script::Latin,
        0x400..=0x52F | 0x1C80..=0x1C8F | 0x2DE0..=0x2DFF | 0xA640..=0xA69F => Script::Cyrillic,
        0x370..=0x3FF | 0x1F00..=0x1FFF => Script::Greek,
        0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x2FFFF => Script::Cjk,
        0xAC00..=0xD7AF | 0x1100..=0x11FF | 0x3130..=0x318F => Script::Hangul,
        // Fullwidth Latin letters fall to `Other`: among Latin letters they are a lookalike, not the same script.
        _ => Script::Other(cp >> 7),
    })
}

/// True when one word of the name (split at spaces, `-` and `_`) has letters of two writing systems, such as a Latin
/// `a` among Cyrillic letters: a name that looks like another name but is not.
pub fn mixes_scripts(name: &str) -> bool {
    name.split(|c: char| !c.is_alphanumeric()).any(|word| {
        let mut seen: Option<Script> = None;
        word.chars().filter_map(script_of).any(|s| match seen {
            None => {
                seen = Some(s);
                false
            }
            Some(first) => first != s,
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invisible_characters_are_found_and_dropped() {
        // Zero-width space, joiner, bidi override and isolate, BOM, soft hyphen, a tag character.
        for hidden in [
            "a\u{200B}b",
            "a\u{200D}b",
            "a\u{202E}b",
            "a\u{2066}b",
            "\u{FEFF}ab",
            "a\u{00AD}b",
            "a\u{E0041}b",
        ] {
            assert!(has_hidden(hidden), "{hidden:?}");
            assert_eq!(line(hidden), "ab", "{hidden:?}");
            assert_eq!(block(hidden), "ab", "{hidden:?}");
        }
        assert!(!has_hidden("plain text, привет, 日本語"));
        assert!(has_hidden("two\nlines"));
    }

    #[test]
    fn a_right_to_left_override_cannot_reorder_what_is_read() {
        // "gnp.exe" shown as "exe.png" is the classic trick: the override is removed, the order is the real one.
        assert_eq!(line("report\u{202E}gnp.exe"), "reportgnp.exe");
        assert_eq!(block("safe \u{202E}evil\u{202C} text"), "safe evil text");
    }

    #[test]
    fn a_line_has_no_breaks_or_odd_spaces() {
        assert_eq!(line("  Mail \n\t watcher\u{00A0}\u{2028}bot  "), "Mail watcher bot");
        assert_eq!(line("\n\n"), "");
        assert_eq!(line("a\u{0007}b"), "a b");
    }

    #[test]
    fn a_block_keeps_its_lines_and_loses_the_rest() {
        assert_eq!(
            block("one\r\ntwo\rthree\u{2028}four\u{0085}five"),
            "one\ntwo\nthree\nfour\nfive"
        );
        assert_eq!(block("a\tb\u{0000}c"), "a bc");
        assert_eq!(block("a  \nb"), "a\nb");
        // More than two blank lines shrink to two; one and two stay.
        assert_eq!(block("a\n\n\n\n\n\nb"), "a\n\n\nb");
        assert_eq!(block("a\n\nb"), "a\n\nb");
        assert_eq!(block("a\n \n\t\n \n \nb"), "a\n\n\nb");
        assert_eq!(block("\n\n  text \n\n"), "text");
    }

    #[test]
    fn a_word_that_mixes_alphabets_is_found() {
        // Cyrillic "а" (U+0430) and "е" among Latin letters, and a Latin "a" in a Cyrillic word.
        assert!(mixes_scripts("p\u{0430}ypal"));
        assert!(mixes_scripts("Mail\u{0435}r"));
        assert!(mixes_scripts("Почт\u{0061}"));
        assert!(mixes_scripts("Αlpha"), "a Greek capital alpha in a Latin word");
        assert!(mixes_scripts("Ｍail"), "a fullwidth letter in a Latin word");
        // Words of one alphabet, digits and marks, other words in the same name, and Japanese kana with kanji.
        assert!(!mixes_scripts("Mailer"));
        assert!(!mixes_scripts("Почтальон"));
        assert!(!mixes_scripts("Mail Почта"));
        assert!(!mixes_scripts("bot-2_Бот"));
        assert!(!mixes_scripts("Café Zoë"));
        assert!(!mixes_scripts("メール係"));
        assert!(!mixes_scripts("agent7"));
        assert!(!mixes_scripts("Привет7"));
    }
}
