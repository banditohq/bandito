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

/// What the runtime reads in place of the text of a message that carries only files.
pub const NO_TEXT: &str = "(без текста)";

/// The text the runtime gets for a message: the reaction line first, then the quoted message it replies to,
/// then the text, then the attachments as paths. `reply` is the text of the message replied to. A message with
/// files and no text reads `(без текста)`. `mentioned` is the `Mentioned:` block of `@` mentions, last.
pub fn runtime_text(
    text: &str,
    note: Option<&str>,
    reply: Option<&str>,
    attachments: &[Attachment],
    mentioned: Option<&str>,
) -> String {
    let mut out = String::new();
    if let Some(note) = note {
        out.push_str(note);
        out.push_str("\n\n");
    }
    if let Some(reply) = reply {
        out.push_str(&format!("В ответ на: > {}\n\n", quote(reply, REPLY_QUOTE_CHARS)));
    }
    if text.trim().is_empty() && !attachments.is_empty() {
        out.push_str(NO_TEXT);
    } else {
        out.push_str(text);
    }
    if !attachments.is_empty() {
        out.push_str("\n\nВложения:");
        for a in attachments {
            out.push_str(&format!("\n- {} ({}, {} байт)", a.path, a.mime, a.size));
        }
    }
    if let Some(mentioned) = mentioned {
        out.push_str("\n\n");
        out.push_str(mentioned);
    }
    out
}

/// Most buttons in one set of quick replies.
pub const QUICK_BUTTONS_MAX: usize = 4;
/// Longest label of a button or a link, in characters.
pub const QUICK_LABEL_CHARS: usize = 40;
/// Longest reply a button sends, in characters.
pub const QUICK_REPLY_CHARS: usize = 200;
/// Longest link address, in characters.
pub const QUICK_URL_CHARS: usize = 2000;
/// Most steps "2 of 6" may count.
pub const QUICK_PROGRESS_MAX: u32 = 99;

/// A checked set of quick replies (the tool `reply_buttons`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickReplies {
    pub buttons: Vec<crate::event::QuickButton>,
    pub link: Option<crate::event::QuickLink>,
    pub progress: Option<crate::event::QuickProgress>,
}

/// A text of one line, trimmed, of 1 to `max` characters.
fn one_line(v: &serde_json::Value, what: &str, max: usize) -> Result<String, String> {
    let text = v.as_str().ok_or_else(|| format!("{what} must be text"))?.trim();
    if text.is_empty() {
        return Err(format!("{what} is empty"));
    }
    if text.chars().count() > max {
        return Err(format!("{what} is longer than {max} characters"));
    }
    if text
        .chars()
        .any(|c| c.is_control() || crate::sanitize::is_format(c) || matches!(c, '\u{2028}' | '\u{2029}'))
    {
        return Err(format!("{what} must be one line without control characters"));
    }
    Ok(text.to_string())
}

/// Checks the arguments of `reply_buttons`: 1 to 4 buttons `{label, reply}` (label up to 40 characters on one line,
/// reply one line up to 200, labels different), an optional `link` `{label, url}` with an https address, and an optional
/// `progress` `{done, total}`. Returns the text of the first mistake, for the agent to fix.
pub fn check_quick_replies(args: &serde_json::Value) -> Result<QuickReplies, String> {
    let list = args
        .get("buttons")
        .and_then(serde_json::Value::as_array)
        .ok_or("reply_buttons needs \"buttons\", a list of {label, reply}")?;
    if list.is_empty() || list.len() > QUICK_BUTTONS_MAX {
        return Err(format!("give 1 to {QUICK_BUTTONS_MAX} buttons"));
    }
    let mut buttons: Vec<crate::event::QuickButton> = Vec::new();
    for (i, b) in list.iter().enumerate() {
        let label = one_line(
            b.get("label").unwrap_or(&serde_json::Value::Null),
            &format!("label of button {}", i + 1),
            QUICK_LABEL_CHARS,
        )?;
        // One line like the label: what is sent is what the button stands for, and a line break could pass for two
        // messages.
        let reply_text = one_line(
            b.get("reply").unwrap_or(&serde_json::Value::Null),
            &format!("reply of button {}", i + 1),
            QUICK_REPLY_CHARS,
        )?;
        if buttons.iter().any(|x| x.label.to_lowercase() == label.to_lowercase()) {
            return Err(format!("two buttons are called {label}: give each its own label"));
        }
        buttons.push(crate::event::QuickButton {
            label,
            reply: reply_text,
        });
    }
    let link = match args.get("link").filter(|v| !v.is_null()) {
        None => None,
        Some(l) => {
            let label = one_line(
                l.get("label").unwrap_or(&serde_json::Value::Null),
                "label of the link",
                QUICK_LABEL_CHARS,
            )?;
            let url = l
                .get("url")
                .and_then(serde_json::Value::as_str)
                .ok_or("the link needs \"url\"")?
                .trim();
            check_https(url)?;
            Some(crate::event::QuickLink {
                label,
                url: url.to_string(),
            })
        }
    };
    let progress = match args.get("progress").filter(|v| !v.is_null()) {
        None => None,
        Some(p) => {
            let number = |key: &str| -> Result<u32, String> {
                p.get(key)
                    .and_then(serde_json::Value::as_u64)
                    .and_then(|n| u32::try_from(n).ok())
                    .ok_or_else(|| format!("progress needs \"{key}\", a whole number"))
            };
            let (done, total) = (number("done")?, number("total")?);
            if total == 0 || total > QUICK_PROGRESS_MAX || done > total {
                return Err(format!(
                    "progress needs 0 <= done <= total, and total from 1 to {QUICK_PROGRESS_MAX}"
                ));
            }
            Some(crate::event::QuickProgress { done, total })
        }
    };
    Ok(QuickReplies {
        buttons,
        link,
        progress,
    })
}

/// An https address a person may open: a host (letters, digits, `-`, `.`, with an optional port), no user name, no
/// spaces or control characters, at most [`QUICK_URL_CHARS`] characters.
fn check_https(url: &str) -> Result<(), String> {
    let bad = || "the link must be an https address, like https://example.com/page".to_string();
    if url.chars().count() > QUICK_URL_CHARS {
        return Err(format!("the link is longer than {QUICK_URL_CHARS} characters"));
    }
    if url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(bad());
    }
    let rest = url.strip_prefix("https://").ok_or_else(bad)?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    };
    let host_ok = !host.is_empty()
        && !host.starts_with(['.', '-'])
        && !host.ends_with(['-'])
        && host.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '.');
    let port_ok = port.is_none_or(|p| !p.is_empty() && p.len() <= 5 && p.chars().all(|c| c.is_ascii_digit()));
    if host_ok && port_ok { Ok(()) } else { Err(bad()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buttons(n: usize) -> serde_json::Value {
        let list: Vec<serde_json::Value> = (0..n)
            .map(|i| serde_json::json!({ "label": format!("Option {i}"), "reply": format!("I choose {i}") }))
            .collect();
        serde_json::json!({ "buttons": list })
    }

    #[test]
    fn one_to_four_buttons_pass_and_are_trimmed() {
        let ok = check_quick_replies(&serde_json::json!({
            "buttons": [{ "label": "  Done  ", "reply": " Mail is connected " }, { "label": "Not yet", "reply": "Not yet" }],
        }))
        .unwrap();
        assert_eq!(ok.buttons[0].label, "Done");
        assert_eq!(ok.buttons[0].reply, "Mail is connected");
        assert_eq!((ok.link, ok.progress), (None, None));
        assert!(check_quick_replies(&buttons(4)).is_ok());
        assert!(check_quick_replies(&buttons(5)).is_err());
        assert!(check_quick_replies(&buttons(0)).is_err());
        assert!(check_quick_replies(&serde_json::json!({})).is_err());
    }

    #[test]
    fn labels_and_replies_are_bounded() {
        let one = |label: &str, reply: &str| {
            check_quick_replies(&serde_json::json!({ "buttons": [{ "label": label, "reply": reply }] }))
        };
        assert!(one(&"é".repeat(40), "x").is_ok());
        assert!(one(&"é".repeat(41), "x").is_err());
        assert!(one("ok", &"я".repeat(200)).is_ok());
        assert!(one("ok", &"я".repeat(201)).is_err());
        // A reply is one line, like a label: a line break could pass for two messages.
        for broken in ["one\ntwo", "one\r\ntwo", "one\u{2028}two", "tab\there", "nul\u{0}"] {
            assert!(one("ok", broken).unwrap_err().contains("one line"), "{broken:?}");
        }
        assert!(one("", "x").is_err());
        assert!(one("   ", "x").is_err());
        assert!(one("ok", "  ").is_err());
        assert!(one("two\nlines", "x").is_err());
        assert!(
            check_quick_replies(&serde_json::json!({ "buttons": [{ "label": "ok" }] }))
                .unwrap_err()
                .contains("reply")
        );
        let same =
            serde_json::json!({ "buttons": [{ "label": "Yes", "reply": "a" }, { "label": "yes", "reply": "b" }] });
        assert!(check_quick_replies(&same).unwrap_err().contains("own label"));
    }

    #[test]
    fn a_link_is_https_only() {
        let with = |url: &str| {
            let mut args = buttons(1);
            args["link"] = serde_json::json!({ "label": "Open", "url": url });
            check_quick_replies(&args)
        };
        assert!(with("https://mail.google.com/mail/u/0/#inbox").is_ok());
        assert!(with("https://example.com:8443/x?y=1").is_ok());
        for bad in [
            "http://example.com",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "https://",
            "https:///path",
            "https://user@evil.com",
            "https://example.com/a b",
            "https://exa mple.com",
            "https://example.com:port/",
            "//example.com",
            "example.com",
        ] {
            assert!(with(bad).is_err(), "{bad}");
        }
        assert!(with(&format!("https://example.com/{}", "a".repeat(2000))).is_err());
        let mut args = buttons(1);
        args["link"] = serde_json::json!({ "label": "Open" });
        assert!(check_quick_replies(&args).is_err());
    }

    #[test]
    fn progress_counts_whole_steps() {
        let with = |done: serde_json::Value, total: serde_json::Value| {
            let mut args = buttons(1);
            args["progress"] = serde_json::json!({ "done": done, "total": total });
            check_quick_replies(&args)
        };
        assert_eq!(
            with(2.into(), 6.into()).unwrap().progress.map(|p| (p.done, p.total)),
            Some((2, 6))
        );
        assert!(with(0.into(), 6.into()).is_ok());
        assert!(with(6.into(), 6.into()).is_ok());
        assert!(with(7.into(), 6.into()).is_err());
        assert!(with(1.into(), 0.into()).is_err());
        assert!(with(1.into(), 100.into()).is_err());
        assert!(with((-1).into(), 6.into()).is_err());
        assert!(with(serde_json::json!("2"), 6.into()).is_err());
        assert!(with(1.5.into(), 6.into()).is_err());
    }

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
        assert_eq!(runtime_text("hi", None, None, &[], None), "hi");
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
        let out = runtime_text("Да", Some(note), Some("Вопрос?"), &files, None);
        assert_eq!(
            out,
            "(Реакции с прошлого раза: 👍 на «x»)\n\nВ ответ на: > Вопрос?\n\nДа\n\nВложения:\n- /w/.bandito/attachments/2026-10-10/a.png (image/png, 12 байт)"
        );
    }

    #[test]
    fn a_message_with_files_and_no_text_reads_no_text() {
        let files = [Attachment {
            path: "/w/.bandito/attachments/2026-10-10/a.png".into(),
            name: "a.png".into(),
            size: 12,
            mime: "image/png".into(),
        }];
        assert_eq!(
            runtime_text("", None, None, &files, None),
            "(без текста)\n\nВложения:\n- /w/.bandito/attachments/2026-10-10/a.png (image/png, 12 байт)"
        );
        assert_eq!(
            runtime_text("  ", None, None, &files, None),
            runtime_text("", None, None, &files, None)
        );
        // Without files an empty text stays empty; the daemon refuses such a message before it gets here.
        assert_eq!(runtime_text("", None, None, &[], None), "");
    }

    #[test]
    fn the_reply_quote_is_cut_at_300_characters() {
        let out = runtime_text("ok", None, Some(&"а".repeat(301)), &[], None);
        assert!(out.starts_with(&format!("В ответ на: > {}…\n\nok", "а".repeat(300))));
    }
}
