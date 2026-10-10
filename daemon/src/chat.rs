//! Chat around a message: reactions (the emoji check, and the note the agent reads about them), and what a
//! message carries into the agent's prompt (the quoted message it replies to, its attachments).
//! See docs/ARCHITECTURE.md#reactions and docs/ARCHITECTURE.md#replies-and-attachments.

use crate::attachments::Attachment;

/// Longest reaction, in bytes. A reaction is one grapheme cluster of at most this size.
pub const EMOJI_MAX_BYTES: usize = 16;
/// How much of a message a reaction note quotes, in characters.
pub const REACTION_QUOTE_CHARS: usize = 80;
/// How much of the message a reply quotes, in characters.
pub const REPLY_QUOTE_CHARS: usize = 300;

/// Checks a reaction: one grapheme cluster, no whitespace or control characters, at most [`EMOJI_MAX_BYTES`].
/// The check is simple on purpose: it joins a character to the one before it when that is a zero-width joiner,
/// a variation selector, a skin tone, a combining mark, or the second half of a flag.
pub fn check_emoji(s: &str) -> Result<(), String> {
    if s.is_empty() {
        return Err("emoji is empty".into());
    }
    if s.len() > EMOJI_MAX_BYTES {
        return Err(format!("emoji is longer than {EMOJI_MAX_BYTES} bytes"));
    }
    if s.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("emoji must be one symbol, without spaces".into());
    }
    if graphemes(s) != 1 {
        return Err("emoji must be one symbol".into());
    }
    Ok(())
}

/// How many grapheme clusters the text has, counted by the simple rule of [`check_emoji`].
fn graphemes(s: &str) -> usize {
    let mut count = 0;
    let mut joins_next = false;
    let mut regional_open = false;
    for c in s.chars() {
        let cp = c as u32;
        let joins = matches!(cp,
            0x200D            // zero-width joiner: the next symbol belongs to this one
            | 0xFE0E | 0xFE0F // variation selectors
            | 0x1F3FB..=0x1F3FF // skin tone modifiers
            | 0x0300..=0x036F   // combining marks
            | 0x20D0..=0x20FF   // combining marks for symbols
            | 0xE0020..=0xE007F // tags (flags of regions)
        );
        if count == 0 {
            count = 1;
            regional_open = (0x1F1E6..=0x1F1FF).contains(&cp);
            joins_next = cp == 0x200D;
            continue;
        }
        if joins_next || joins {
            joins_next = cp == 0x200D;
            continue;
        }
        if regional_open && (0x1F1E6..=0x1F1FF).contains(&cp) {
            regional_open = false;
            continue;
        }
        count += 1;
        regional_open = (0x1F1E6..=0x1F1FF).contains(&cp);
        joins_next = false;
    }
    count
}

/// The first `max` characters of a message, on one line. A cut is marked with `…`.
pub fn quote(text: &str, max: usize) -> String {
    let one_line: String = text
        .chars()
        .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
        .collect();
    let mut chars = one_line.chars();
    let head: String = chars.by_ref().take(max).collect();
    if chars.next().is_some() {
        format!("{head}…")
    } else {
        head
    }
}

/// One reaction the human put on an agent message, as the agent should hear about it.
#[derive(Debug, Clone, PartialEq)]
pub struct ReactionNote {
    pub emoji: String,
    /// The text of the agent message the reaction is on.
    pub message: String,
}

/// The line that starts the next prompt: `(Реакции с прошлого раза: 👍 на «…»; 👀 на «…»)`. `None` when there is none.
pub fn reaction_note(items: &[ReactionNote]) -> Option<String> {
    if items.is_empty() {
        return None;
    }
    let parts: Vec<String> = items
        .iter()
        .map(|i| format!("{} на «{}»", i.emoji, quote(&i.message, REACTION_QUOTE_CHARS)))
        .collect();
    Some(format!("(Реакции с прошлого раза: {})", parts.join("; ")))
}

/// The text the runtime gets for a message: the reaction line first, then the quoted message it replies to,
/// then the text, then the attachments as paths. `reply` is the text of the message replied to.
pub fn runtime_text(text: &str, note: Option<&str>, reply: Option<&str>, attachments: &[Attachment]) -> String {
    let mut out = String::new();
    if let Some(note) = note {
        out.push_str(note);
        out.push_str("\n\n");
    }
    if let Some(reply) = reply {
        out.push_str(&format!("В ответ на: > {}\n\n", quote(reply, REPLY_QUOTE_CHARS)));
    }
    out.push_str(text);
    if !attachments.is_empty() {
        out.push_str("\n\nВложения:");
        for a in attachments {
            out.push_str(&format!("\n- {} ({}, {} байт)", a.path, a.mime, a.size));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn common_emoji_pass() {
        for e in ["👍", "👀", "❤️", "👍🏽", "🇷🇺", "é", "✅", "👩‍💻"] {
            assert!(check_emoji(e).is_ok(), "{e}");
        }
    }

    #[test]
    fn text_and_empty_fail() {
        assert!(check_emoji("").is_err());
        assert!(check_emoji("ok").is_err());
        assert!(check_emoji("👍 👍").is_err());
        assert!(check_emoji("👍\n").is_err());
        assert!(check_emoji("👍👀").is_err());
        assert!(check_emoji("🇷🇺🇺🇸").is_err());
    }

    #[test]
    fn the_byte_limit_is_16() {
        // A family is one cluster of 18 bytes: over the limit, so it is refused.
        let family = "👨‍👩‍👧";
        assert_eq!(family.len(), 18);
        assert!(check_emoji(family).unwrap_err().contains("longer than 16"));
        let two = "👍🏽👍🏽";
        assert!(check_emoji(two).is_err());
    }

    #[test]
    fn quote_cuts_on_characters_and_marks_the_cut() {
        assert_eq!(quote("привет", 3), "при…");
        assert_eq!(quote("привет", 6), "привет");
        assert_eq!(quote("a\nb", 10), "a b");
    }

    #[test]
    fn reaction_note_lists_each_reaction() {
        assert_eq!(reaction_note(&[]), None);
        let note = reaction_note(&[ReactionNote {
            emoji: "👍".into(),
            message: "Готово".into(),
        }]);
        assert_eq!(note.as_deref(), Some("(Реакции с прошлого раза: 👍 на «Готово»)"));
        let two = reaction_note(&[
            ReactionNote {
                emoji: "👍".into(),
                message: "a".into(),
            },
            ReactionNote {
                emoji: "👀".into(),
                message: "b".into(),
            },
        ])
        .unwrap();
        assert_eq!(two, "(Реакции с прошлого раза: 👍 на «a»; 👀 на «b»)");
    }

    #[test]
    fn reaction_note_quotes_the_first_80_characters() {
        let long = "я".repeat(100);
        let note = reaction_note(&[ReactionNote {
            emoji: "👀".into(),
            message: long,
        }])
        .unwrap();
        assert!(note.contains(&format!("«{}…»", "я".repeat(80))));
    }

    #[test]
    fn plain_text_is_unchanged() {
        assert_eq!(runtime_text("hi", None, None, &[]), "hi");
    }

    #[test]
    fn prompt_has_note_then_reply_then_text_then_attachments() {
        let files = [Attachment {
            path: "/w/.bandito/attachments/2026-10-10/a.png".into(),
            name: "a.png".into(),
            size: 12,
            mime: "image/png".into(),
        }];
        let note = "(Реакции с прошлого раза: 👍 на «x»)";
        let out = runtime_text("Да", Some(note), Some("Вопрос?"), &files);
        assert_eq!(
            out,
            "(Реакции с прошлого раза: 👍 на «x»)\n\nВ ответ на: > Вопрос?\n\nДа\n\nВложения:\n- /w/.bandito/attachments/2026-10-10/a.png (image/png, 12 байт)"
        );
    }

    #[test]
    fn the_reply_quote_is_cut_at_300_characters() {
        let out = runtime_text("ok", None, Some(&"а".repeat(301)), &[]);
        assert!(out.starts_with(&format!("В ответ на: > {}…\n\nok", "а".repeat(300))));
    }
}
