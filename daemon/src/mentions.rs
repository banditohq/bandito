//! `@` mentions in a message the person sends: a service, a teammate, a file or a browser tab named in the text.
//! The thread keeps them (`message.user.mentions`, for chips); the runtime reads a short `Mentioned:` block after
//! the text. See docs/ARCHITECTURE.md#mentions.

use serde::{Deserialize, Serialize};

/// Most mentions in one message.
pub const MAX_MENTIONS: usize = 20;
/// Longest label, in characters.
pub const MAX_LABEL_CHARS: usize = 120;
/// Longest id (a path for a file), in bytes.
pub const MAX_ID_BYTES: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MentionKind {
    Integration,
    Agent,
    File,
    BrowserTab,
}

/// One mention as the client sends it and the thread keeps it. `id`: the integration's id, the agent's id, the
/// absolute path of the file, the browser tab's id. `label`: the text after the `@` in the message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mention {
    pub kind: MentionKind,
    pub id: String,
    pub label: String,
}

/// The shape of a mention list, before anything is looked up: the count, and each id and label.
pub fn check_shape(list: &[Mention]) -> Result<(), String> {
    if list.len() > MAX_MENTIONS {
        return Err(format!("at most {MAX_MENTIONS} mentions per message"));
    }
    for m in list {
        if m.id.trim().is_empty() || m.id.len() > MAX_ID_BYTES || m.id.chars().any(char::is_control) {
            return Err("a mention has no valid id".into());
        }
        let label = m.label.trim();
        if label.is_empty() || label.chars().count() > MAX_LABEL_CHARS || label.chars().any(char::is_control) {
            return Err("a mention has no valid label".into());
        }
    }
    Ok(())
}

/// A mention with the facts the runtime needs, read from the daemon when the message was sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolved {
    /// The integration's name (the server name in the session, so its tools start with `mcp__<name>__`).
    Integration {
        name: String,
    },
    Agent {
        name: String,
    },
    File {
        path: String,
    },
    BrowserTab {
        url: String,
        title: String,
    },
}

/// The block added after the text for the runtime. `None` for no mentions. English, short, one line each.
pub fn note(items: &[Resolved]) -> Option<String> {
    if items.is_empty() {
        return None;
    }
    let mut out = String::from("Mentioned:");
    for item in items {
        out.push_str("\n- ");
        match item {
            Resolved::Integration { name } => out.push_str(&format!(
                "{name} (a connected service): use its tools (prefix mcp__{name}__) for this request"
            )),
            Resolved::Agent { name } => out.push_str(&format!(
                "@{name} is a teammate; hand this to them with crew_send if it belongs to them"
            )),
            Resolved::File { path } => out.push_str(&format!("file: {}", one_line(path))),
            Resolved::BrowserTab { url, title } => {
                out.push_str(&format!(
                    "browser tab: {} (\"{}\"); read it with the browser tool",
                    one_line(url),
                    one_line(title)
                ));
            }
        }
    }
    Some(out)
}

/// A title or name on one line: control characters and line breaks become spaces.
fn one_line(text: &str) -> String {
    text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mention(kind: MentionKind, id: &str, label: &str) -> Mention {
        Mention {
            kind,
            id: id.into(),
            label: label.into(),
        }
    }

    #[test]
    fn kinds_are_snake_case_on_the_wire() {
        let m: Mention = serde_json::from_str(r#"{"kind":"browser_tab","id":"T1","label":"Docs"}"#).unwrap();
        assert_eq!(m.kind, MentionKind::BrowserTab);
        assert_eq!(serde_json::to_value(&m).unwrap()["kind"], "browser_tab");
        assert!(serde_json::from_str::<Mention>(r#"{"kind":"web","id":"1","label":"x"}"#).is_err());
    }

    #[test]
    fn the_shape_is_checked() {
        assert!(check_shape(&[mention(MentionKind::Agent, "a", "Scout")]).is_ok());
        assert!(check_shape(&[mention(MentionKind::Agent, " ", "Scout")]).is_err());
        assert!(check_shape(&[mention(MentionKind::Agent, "a", "")]).is_err());
        assert!(check_shape(&[mention(MentionKind::Agent, "a", "x\ny")]).is_err());
        assert!(check_shape(&[mention(MentionKind::Agent, "a", &"я".repeat(MAX_LABEL_CHARS + 1))]).is_err());
        let many = vec![mention(MentionKind::Agent, "a", "Scout"); MAX_MENTIONS + 1];
        assert!(check_shape(&many).is_err());
    }

    #[test]
    fn the_note_is_short_english_with_one_line_each() {
        assert_eq!(note(&[]), None);
        let out = note(&[
            Resolved::Integration { name: "linear".into() },
            Resolved::Agent { name: "Scout".into() },
            Resolved::File {
                path: "/work/app/src/main.rs".into(),
            },
            Resolved::BrowserTab {
                url: "https://example.com/a".into(),
                title: "Docs\nPage".into(),
            },
        ])
        .unwrap();
        assert_eq!(
            out,
            "Mentioned:\n\
             - linear (a connected service): use its tools (prefix mcp__linear__) for this request\n\
             - @Scout is a teammate; hand this to them with crew_send if it belongs to them\n\
             - file: /work/app/src/main.rs\n\
             - browser tab: https://example.com/a (\"Docs Page\"); read it with the browser tool"
        );
    }
}
