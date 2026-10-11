//! Text an agent writes that a person reads on a card and that later becomes another agent's instructions or name
//! (docs/ARCHITECTURE.md#agents-creating-agents). What the person reads must be what is stored, so text is cleaned
//! before it is shown and stored, not only when it is drawn: no invisible characters (zero-width, bidi controls,
//! format characters), no control characters, no endless blank lines, and a name whose word mixes alphabets is refused.

/// Characters with no visible shape: the Unicode format category (Cf: zero-width, bidirectional controls, soft hyphen,
/// tags), and the others that draw nothing (variation selectors, the combining grapheme joiner, Hangul and Braille
/// fillers, Khmer inherent vowels, Mongolian free variation selectors, the object replacement character).
pub fn is_format(c: char) -> bool {
    matches!(c as u32,
        0x00AD | 0x0600..=0x0605 | 0x061C | 0x06DD | 0x070F | 0x0890..=0x0891 | 0x08E2 | 0x180E
        | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF
        | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3
        | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F
        // Not Cf, still invisible.
        | 0x034F | 0x115F | 0x1160 | 0x17B4 | 0x17B5 | 0x180B..=0x180F | 0x2800 | 0x3164
        | 0xFE00..=0xFE0F | 0xFFA0 | 0xFFFC | 0xE0100..=0xE01EF)
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

/// The writing system of a letter, as far as confusing one with another goes. Digits, marks and `_-` have none.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Script {
    Latin,
    Cyrillic,
    Greek,
    Arabic,
    Hebrew,
    /// Han, Hiragana and Katakana mix in one Japanese word.
    Cjk,
    Hangul,
    /// Another writing system the table knows (Devanagari, Thai, Armenian…), by name.
    Named(&'static str),
    /// A letter of no writing system in the table: not allowed in a name.
    Unknown,
}

/// The ranges of each writing system, by the Unicode blocks the letters live in.
const SCRIPTS: &[(u32, u32, Script)] = &[
    (0x41, 0x5A, Script::Latin),
    (0x61, 0x7A, Script::Latin),
    (0xAA, 0xAA, Script::Latin),
    (0xB5, 0xB5, Script::Latin),
    (0xBA, 0xBA, Script::Latin),
    (0xC0, 0xD6, Script::Latin),
    (0xD8, 0xF6, Script::Latin),
    // Latin Extended-A and B, IPA Extensions, spacing modifier letters.
    (0xF8, 0x2B8, Script::Latin),
    (0x1D00, 0x1D25, Script::Latin),
    (0x1D2C, 0x1D5C, Script::Latin),
    (0x1D62, 0x1D65, Script::Latin),
    (0x1D6B, 0x1D77, Script::Latin),
    (0x1D79, 0x1DBE, Script::Latin),
    (0x1E00, 0x1EFF, Script::Latin),
    (0x2071, 0x2071, Script::Latin),
    (0x207F, 0x207F, Script::Latin),
    (0x2090, 0x209C, Script::Latin),
    (0x212A, 0x212B, Script::Latin),
    (0x2132, 0x2132, Script::Latin),
    (0x214E, 0x214E, Script::Latin),
    (0x2160, 0x2188, Script::Latin),
    (0x2C60, 0x2C7F, Script::Latin),
    (0xA722, 0xA787, Script::Latin),
    (0xA78B, 0xA7FF, Script::Latin),
    (0xAB30, 0xAB5A, Script::Latin),
    (0xAB5C, 0xAB64, Script::Latin),
    (0xFB00, 0xFB06, Script::Latin),
    (0x0370, 0x03FF, Script::Greek),
    (0x1D26, 0x1D2A, Script::Greek),
    (0x1F00, 0x1FFF, Script::Greek),
    (0x0400, 0x052F, Script::Cyrillic),
    (0x1C80, 0x1C8F, Script::Cyrillic),
    (0x1D2B, 0x1D2B, Script::Cyrillic),
    (0x1D78, 0x1D78, Script::Cyrillic),
    (0x2DE0, 0x2DFF, Script::Cyrillic),
    (0xA640, 0xA69F, Script::Cyrillic),
    (0x0530, 0x058F, Script::Named("armenian")),
    (0xFB13, 0xFB17, Script::Named("armenian")),
    (0x0590, 0x05FF, Script::Hebrew),
    (0xFB1D, 0xFB4F, Script::Hebrew),
    // Arabic, Arabic Supplement, Extended-A, Presentation Forms A and B.
    (0x0600, 0x06FF, Script::Arabic),
    (0x0750, 0x077F, Script::Arabic),
    (0x0870, 0x08FF, Script::Arabic),
    (0xFB50, 0xFDFF, Script::Arabic),
    (0xFE70, 0xFEFF, Script::Arabic),
    (0x0700, 0x074F, Script::Named("syriac")),
    (0x0780, 0x07BF, Script::Named("thaana")),
    (0x07C0, 0x07FF, Script::Named("nko")),
    (0x0900, 0x097F, Script::Named("devanagari")),
    (0x0980, 0x09FF, Script::Named("bengali")),
    (0x0A00, 0x0A7F, Script::Named("gurmukhi")),
    (0x0A80, 0x0AFF, Script::Named("gujarati")),
    (0x0B00, 0x0B7F, Script::Named("oriya")),
    (0x0B80, 0x0BFF, Script::Named("tamil")),
    (0x0C00, 0x0C7F, Script::Named("telugu")),
    (0x0C80, 0x0CFF, Script::Named("kannada")),
    (0x0D00, 0x0D7F, Script::Named("malayalam")),
    (0x0D80, 0x0DFF, Script::Named("sinhala")),
    (0x0E00, 0x0E7F, Script::Named("thai")),
    (0x0E80, 0x0EFF, Script::Named("lao")),
    (0x0F00, 0x0FFF, Script::Named("tibetan")),
    (0x1000, 0x109F, Script::Named("myanmar")),
    (0x10A0, 0x10FF, Script::Named("georgian")),
    (0x2D00, 0x2D2F, Script::Named("georgian")),
    (0x1200, 0x139F, Script::Named("ethiopic")),
    (0x1780, 0x17FF, Script::Named("khmer")),
    (0x1800, 0x18AF, Script::Named("mongolian")),
    (0x1100, 0x11FF, Script::Hangul),
    (0x3130, 0x318F, Script::Hangul),
    (0xA960, 0xA97F, Script::Hangul),
    (0xAC00, 0xD7FF, Script::Hangul),
    (0x3005, 0x3007, Script::Cjk),
    (0x3041, 0x30FF, Script::Cjk),
    (0x31F0, 0x31FF, Script::Cjk),
    (0x3400, 0x4DBF, Script::Cjk),
    (0x4E00, 0x9FFF, Script::Cjk),
    (0xF900, 0xFAFF, Script::Cjk),
    (0x20000, 0x323AF, Script::Cjk),
];

fn script_of(c: char) -> Option<Script> {
    if !c.is_alphabetic() {
        return None;
    }
    let cp = c as u32;
    Some(
        SCRIPTS
            .iter()
            .find(|(lo, hi, _)| (*lo..=*hi).contains(&cp))
            .map_or(Script::Unknown, |(_, _, script)| *script),
    )
}

/// True when one word of the name (split at spaces, `-` and `_`) has letters of two writing systems, such as a Latin
/// `a` among Cyrillic letters: a name that looks like another name but is not. Digits and `_-` are neutral.
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

/// True when the name has a letter of no writing system the table knows.
pub fn has_unknown_letters(name: &str) -> bool {
    name.chars().any(|c| script_of(c) == Some(Script::Unknown))
}

/// True when the name changes under NFKC: it holds fullwidth, mathematical or other compatibility letters, ligatures,
/// `ª`, `µ`, which are lookalikes of plain letters. A name keeps only the plain form.
pub fn has_compatibility_letters(name: &str) -> bool {
    use unicode_normalization::UnicodeNormalization;
    name.nfkc().collect::<String>() != name
}

/// The look of a name with the lookalikes folded together: NFKC, lower case (Unicode, in Rust), the main Cyrillic and
/// Greek lookalikes of Latin letters mapped to those letters, `0` to `o`, `1` to `l`, and the separators dropped. Two
/// names with the same skeleton read the same to a person.
pub fn skeleton(name: &str) -> String {
    use unicode_normalization::UnicodeNormalization;
    name.nfkc()
        .collect::<String>()
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .map(|c| match c {
            // Cyrillic
            'а' => 'a',
            'в' => 'b',
            'е' | 'ё' | 'є' => 'e',
            'к' => 'k',
            'м' => 'm',
            'н' => 'h',
            'о' => 'o',
            'р' => 'p',
            'с' => 'c',
            'т' => 't',
            'у' => 'y',
            'х' => 'x',
            'і' | 'ї' => 'i',
            'ј' => 'j',
            'ѕ' => 's',
            'ԁ' => 'd',
            'һ' => 'h',
            'ӏ' => 'l',
            'ԛ' => 'q',
            'ԝ' => 'w',
            // Greek
            'α' => 'a',
            'β' => 'b',
            'ε' => 'e',
            'η' => 'n',
            'ι' => 'i',
            'κ' => 'k',
            'μ' => 'u',
            'ν' => 'v',
            'ο' => 'o',
            'ρ' => 'p',
            'τ' => 't',
            'υ' => 'u',
            'χ' => 'x',
            'γ' => 'y',
            // Digits that stand for letters
            '0' => 'o',
            '1' => 'l',
            'ı' | 'ɩ' => 'l',
            other => other,
        })
        .collect()
}

/// Why a name for a new agent is refused, or `None`: it has an invisible or control character, a compatibility
/// (fullwidth, mathematical…) letter, a letter of an alphabet that is not known, a word that mixes alphabets, or its
/// skeleton is that of an agent already in the crew (`invalid: name (looks like <name>)`).
pub fn name_problem(name: &str, crew: &[String]) -> Option<String> {
    if has_hidden(name) {
        return Some(
            "invalid: name has invisible or control characters (a line break, a zero-width or direction mark)".into(),
        );
    }
    if has_compatibility_letters(name) {
        return Some(
            "invalid: name has lookalike letters (fullwidth, mathematical, ligatures, ª or µ): use plain letters"
                .into(),
        );
    }
    if has_unknown_letters(name) {
        return Some("invalid: name has letters of an alphabet that is not supported".into());
    }
    if mixes_scripts(name) {
        return Some(
            "invalid: name mixes letters of different alphabets in one word (it could pass for another name)".into(),
        );
    }
    let mine = skeleton(name);
    crew.iter()
        .find(|other| skeleton(other) == mine)
        .map(|other| format!("invalid: name (looks like {other})"))
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

    #[test]
    fn invisible_characters_outside_the_format_category_are_dropped_too() {
        // Variation selectors, the combining grapheme joiner, Hangul and Braille fillers, Khmer inherent vowels,
        // Mongolian variation selectors, the object replacement character.
        for c in [
            '\u{FE00}',
            '\u{FE0F}',
            '\u{E0100}',
            '\u{E01EF}',
            '\u{034F}',
            '\u{115F}',
            '\u{1160}',
            '\u{3164}',
            '\u{FFA0}',
            '\u{2800}',
            '\u{17B4}',
            '\u{17B5}',
            '\u{180B}',
            '\u{180F}',
            '\u{FFFC}',
        ] {
            let text = format!("a{c}b");
            assert!(has_hidden(&text), "{c:?}");
            assert_eq!(line(&text), "ab", "{c:?}");
            assert_eq!(block(&text), "ab", "{c:?}");
            assert!(
                name_problem(&text, &[]).is_some_and(|w| w.starts_with("invalid: name")),
                "{c:?}"
            );
        }
    }

    #[test]
    fn scripts_follow_the_real_ranges() {
        // Arabic letters are all Arabic, the extended and presentation forms too: no mix.
        assert!(!mixes_scripts("لگ"));
        assert!(!mixes_scripts("\u{FB8E}\u{FE8E}\u{0750}"));
        // µ and ª are Latin letters: not a mix with Latin.
        assert!(!mixes_scripts("Mailµ"));
        assert!(!mixes_scripts("ª"));
        assert!(!mixes_scripts("Zoë·Ångström Łódź ɐɑ"));
        // Other alphabets are told apart by their blocks.
        assert!(!mixes_scripts("नमस्ते"));
        assert!(mixes_scripts("Mailनमस्ते"));
        assert!(mixes_scripts("שלוםabc"));
        assert!(mixes_scripts("Mailلگ"));
        assert!(!mixes_scripts("שלום"));
        assert!(!mixes_scripts("สวัสดี"));
        // Digits and separators are neutral.
        assert!(!mixes_scripts("لگ2 mail-3_Бот"));
        // A letter the table does not know is found.
        assert!(has_unknown_letters("a\u{10330}"));
        assert!(!has_unknown_letters("Mail Почта لگ 日本語 한국어"));
    }

    #[test]
    fn lookalike_names_have_the_same_skeleton() {
        assert_eq!(skeleton("СОРЕХ"), skeleton("copex"));
        assert_eq!(skeleton("ΡΟΧ"), skeleton("POX"));
        assert_eq!(skeleton("Ѕcout"), skeleton("scout"));
        assert_eq!(skeleton("Hell0"), skeleton("hello"));
        assert_eq!(skeleton("Mail er-bot"), skeleton("mailer_bot"));
        // Unicode case folding is Rust's, not an ASCII one.
        assert_eq!(skeleton("ÄRGER"), skeleton("ärger"));
        assert_ne!(skeleton("Scout"), skeleton("Scoot"));
        assert_ne!(skeleton("Почта"), skeleton("Pochta"));
    }

    #[test]
    fn a_name_that_looks_like_a_teammate_is_refused_with_its_name() {
        let crew = vec!["COPEX".to_string(), "Scout".to_string(), "Ärger".to_string()];
        assert_eq!(
            name_problem("СОРЕХ", &crew).as_deref(),
            Some("invalid: name (looks like COPEX)")
        );
        assert_eq!(
            name_problem("SCOUT", &crew).as_deref(),
            Some("invalid: name (looks like Scout)")
        );
        assert_eq!(
            name_problem("ärger", &crew).as_deref(),
            Some("invalid: name (looks like Ärger)")
        );
        assert_eq!(name_problem("Mailer", &crew), None);
        assert_eq!(name_problem("Почта", &crew), None);
    }

    #[test]
    fn compatibility_letters_are_not_allowed_in_a_name() {
        // Fullwidth, mathematical bold and script letters, a ligature, ª and µ: all change under NFKC.
        for name in ["Ｍailer", "𝐌ailer", "𝓜ailer", "ﬁle", "ªgent", "Mailµ", "ⓜailer", "ℌost"] {
            assert!(has_compatibility_letters(name), "{name}");
            assert!(
                name_problem(name, &[]).is_some_and(|w| w.starts_with("invalid: name has lookalike")),
                "{name}"
            );
        }
        assert!(!has_compatibility_letters("Mailer Почта لگ 日本語"));
        // A letter of an unknown alphabet.
        assert!(name_problem("a\u{10330}", &[]).is_some_and(|w| w.contains("not supported")));
    }
}
