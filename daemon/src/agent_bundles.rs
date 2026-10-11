//! Agent bundles: a named set of templates that the owner makes in one go (`agent_bundles.json`, see
//! docs/ARCHITECTURE.md#agent-bundles). This module holds the catalog's shape, the embedded file and the test that holds
//! every entry to the rules. The RPCs are in `rpc/templates.rs`.

use crate::agent_templates::Category;
use serde::Deserialize;
use std::collections::BTreeMap;

/// The catalog as written, embedded in the binary. `agents.bundles` serves it as it is.
pub const CATALOG_JSON: &str = include_str!("agent_bundles.json");

/// Every bundle, parsed with the strict type.
pub fn catalog() -> Result<Vec<AgentBundle>, serde_json::Error> {
    serde_json::from_str(CATALOG_JSON)
}

/// The bundle with this id, if there is one.
pub fn find(id: &str) -> Result<Option<AgentBundle>, serde_json::Error> {
    Ok(catalog()?.into_iter().find(|b| b.id == id))
}

/// One bundle as written in `agent_bundles.json`. Unknown fields are an error, so a typo cannot pass silently.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentBundle {
    pub id: String,
    pub name_en: String,
    pub name_ru: String,
    pub description_en: String,
    pub description_ru: String,
    /// Names and descriptions for the other seven languages, keyed by language tag (as in `agent_templates.json`).
    pub l10n: BTreeMap<String, Localized>,
    /// An SF Symbol that exists in macOS 14.
    pub icon: String,
    /// `#RRGGBB`, muted enough to read on the dark background.
    pub accent: String,
    /// Template ids from `agent_templates.json`: three to five, none listed twice.
    pub templates: Vec<String>,
    /// The same categories as the templates, so the Marketplace can filter both alike.
    pub category: Category,
}

/// The texts of a bundle in one language.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Localized {
    pub name: String,
    pub description: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_templates;
    use std::collections::HashSet;

    const LANGUAGES: [&str; 7] = ["de", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans"];

    fn is_kebab_case(id: &str) -> bool {
        !id.is_empty()
            && id
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    }

    fn is_hex_color(s: &str) -> bool {
        s.len() == 7 && s.starts_with('#') && s[1..].chars().all(|c| c.is_ascii_hexdigit())
    }

    /// The shipped catalog, which the tests hold to the rules. Failing to parse it is a test failure.
    fn bundles() -> Vec<AgentBundle> {
        super::catalog().expect("agent_bundles.json matches the strict AgentBundle type")
    }

    #[test]
    fn the_catalog_has_the_six_bundles_of_the_plan() {
        let ids: Vec<String> = bundles().into_iter().map(|b| b.id).collect();
        assert_eq!(
            ids,
            [
                "startup-team",
                "content-studio",
                "market-research",
                "customer-support",
                "personal-assistant",
                "devops",
            ]
        );
    }

    #[test]
    fn ids_are_unique_and_kebab_case() {
        let mut seen = HashSet::new();
        for b in bundles() {
            assert!(is_kebab_case(&b.id), "bad id {:?}", b.id);
            assert!(seen.insert(b.id.clone()), "duplicate id {:?}", b.id);
        }
    }

    #[test]
    fn every_bundle_lists_three_to_five_existing_templates_once() {
        for b in bundles() {
            assert!(
                (3..=5).contains(&b.templates.len()),
                "{}: {} templates",
                b.id,
                b.templates.len()
            );
            let mut seen = HashSet::new();
            for id in &b.templates {
                let found = agent_templates::find(id).expect("agent_templates.json parses");
                assert!(found.is_some(), "{}: unknown template {:?}", b.id, id);
                assert!(seen.insert(id.as_str()), "{}: template {:?} listed twice", b.id, id);
            }
        }
    }

    #[test]
    fn every_text_is_filled_in_english_and_russian_and_in_all_seven_languages() {
        for b in bundles() {
            for (field, value) in [
                ("name_en", &b.name_en),
                ("name_ru", &b.name_ru),
                ("description_en", &b.description_en),
                ("description_ru", &b.description_ru),
            ] {
                assert!(!value.trim().is_empty(), "{}: {field} is empty", b.id);
            }
            let keys: HashSet<&str> = b.l10n.keys().map(String::as_str).collect();
            let expected: HashSet<&str> = LANGUAGES.into_iter().collect();
            assert_eq!(keys, expected, "{}: l10n languages", b.id);
            for (lang, l) in &b.l10n {
                assert!(!l.name.trim().is_empty(), "{}: {lang}.name is empty", b.id);
                assert!(
                    !l.description.trim().is_empty(),
                    "{}: {lang}.description is empty",
                    b.id
                );
            }
        }
    }

    #[test]
    fn names_fit_with_a_number_suffix() {
        // A second bot of the same name becomes "name 2", "name 3"…: the agent name limit is 32 characters.
        for b in bundles() {
            let names = [b.name_en.as_str(), b.name_ru.as_str()]
                .into_iter()
                .chain(b.l10n.values().map(|l| l.name.as_str()));
            for name in names {
                assert!(name.chars().count() <= 29, "{}: name {:?} is too long", b.id, name);
            }
        }
    }

    #[test]
    fn icon_and_accent_are_set() {
        for b in bundles() {
            assert!(
                !b.icon.trim().is_empty() && !b.icon.contains(char::is_whitespace),
                "{}: icon",
                b.id
            );
            assert!(
                is_hex_color(&b.accent),
                "{}: accent {:?} is not #RRGGBB",
                b.id,
                b.accent
            );
        }
    }

    #[test]
    fn an_unknown_field_is_refused() {
        let mut first: serde_json::Value = serde_json::from_str(CATALOG_JSON).unwrap();
        first[0]["bogus_field"] = serde_json::json!(1);
        assert!(serde_json::from_value::<AgentBundle>(first[0].clone()).is_err());
    }
}
