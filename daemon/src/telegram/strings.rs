//! The bot's texts: `telegram_strings.json` maps a key to its text in each of the nine languages. A text may hold
//! `{name}` placeholders. The texts are sent as Telegram HTML, so none holds `<`, `>` or `&` (a test checks), and a
//! value put into a placeholder must be escaped by the caller.

use serde_json::Value;
use std::collections::HashMap;
use std::sync::LazyLock;

/// The languages of the texts; the first is the fallback.
pub const LANGUAGES: [&str; 9] = ["en", "ru", "de", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans"];

static TABLE: LazyLock<HashMap<String, HashMap<String, String>>> = LazyLock::new(|| {
    let raw: Value = serde_json::from_str(include_str!("../telegram_strings.json"))
        .expect("telegram_strings.json is valid JSON (a test reads it)");
    raw.as_object()
        .map(|keys| {
            keys.iter()
                .map(|(key, langs)| {
                    let texts = langs
                        .as_object()
                        .map(|m| {
                            m.iter()
                                .filter_map(|(l, t)| t.as_str().map(|t| (l.clone(), t.to_string())))
                                .collect()
                        })
                        .unwrap_or_default();
                    (key.clone(), texts)
                })
                .collect()
        })
        .unwrap_or_default()
});

/// Whether the table has a text for `key`.
#[cfg(test)]
pub fn has_key(key: &str) -> bool {
    TABLE.contains_key(key)
}

/// The text `key` in `lang` (English when the language or its text is missing; the key itself when there is no such
/// key), with `{name}` replaced from `args` in one pass: a value that looks like a placeholder stays as it is.
pub fn tr(lang: &str, key: &str, args: &[(&str, &str)]) -> String {
    let Some(texts) = TABLE.get(key) else {
        return key.to_string();
    };
    let Some(template) = texts.get(lang).or_else(|| texts.get(LANGUAGES[0])) else {
        return key.to_string();
    };
    let mut out = String::with_capacity(template.len());
    let mut rest = template.as_str();
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        match after.find('}') {
            Some(close) => {
                let name = &after[..close];
                match args.iter().find(|(n, _)| *n == name) {
                    Some((_, value)) => out.push_str(value),
                    None => {
                        out.push('{');
                        out.push_str(name);
                        out.push('}');
                    }
                }
                rest = &after[close + 1..];
            }
            None => {
                out.push_str(&rest[open..]);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}
