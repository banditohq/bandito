//! Agent templates: the built-in starting points for a bot (`agent_templates.json`, see docs/ARCHITECTURE.md#agent-templates-data).
//! This module holds the catalog's shape, the embedded file and the test that holds every entry to the rules. The RPC
//! that serves the list and creates a bot from one is `rpc/templates.rs` (docs/ARCHITECTURE.md#agent-templates).

use serde::Deserialize;
use std::collections::BTreeMap;

/// The catalog as written, embedded in the binary. `agents.templates` serves it as it is.
pub const CATALOG_JSON: &str = include_str!("agent_templates.json");

/// Every template, parsed with the strict type. A parse error is an error for the caller (a request answers it as a
/// server error); the catalog tests keep the shipped file valid.
pub fn catalog() -> Result<Vec<AgentTemplate>, serde_json::Error> {
    serde_json::from_str(CATALOG_JSON)
}

/// The template with this id, if there is one.
pub fn find(id: &str) -> Result<Option<AgentTemplate>, serde_json::Error> {
    Ok(catalog()?.into_iter().find(|t| t.id == id))
}

/// One template as written in `agent_templates.json`. Unknown fields are an error, so a typo cannot pass silently.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentTemplate {
    pub id: String,
    pub name_en: String,
    pub name_ru: String,
    pub description_en: String,
    pub description_ru: String,
    pub long_en: String,
    pub long_ru: String,
    /// Texts for the other seven languages, keyed by language tag (`de`, `es`, `fr`, `ja`, `ko`, `pt-BR`, `zh-Hans`).
    pub l10n: BTreeMap<String, Localized>,
    pub category: Category,
    /// An SF Symbol that exists in macOS 14.
    pub icon: String,
    /// `#RRGGBB`, muted enough to read on the dark background.
    pub accent: String,
    pub role_en: String,
    pub system_prompt: String,
    pub runtime: String,
    pub effort: Option<Effort>,
    /// A subset of the capability names (`terminal`, `files`, `browser`, `team`, `screen`).
    pub capabilities: Vec<String>,
    pub integrations: Vec<TemplateIntegration>,
    /// Skill ids; empty until the skills catalog exists.
    pub skills: Vec<String>,
    pub schedules: Vec<TemplateSchedule>,
    pub starter_en: String,
    pub starter_ru: String,
}

/// The texts of a template in one language. `schedule_prompts` line up with the template's `schedules`.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Localized {
    pub name: String,
    pub description: String,
    pub long: String,
    pub starter: String,
    pub schedule_prompts: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Category {
    Dev,
    Ops,
    Research,
    Writing,
    Business,
    Personal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Effort {
    Medium,
    High,
}

/// An integration from `integrations_catalog.json` that the template uses.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TemplateIntegration {
    pub id: String,
    pub required: bool,
}

/// A schedule the owner can keep when the bot is created. `cron` is a 5-field cron, read by the scheduler.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TemplateSchedule {
    pub cron: String,
    pub prompt_en: String,
    pub prompt_ru: String,
    pub enabled_by_default: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{ALL_CAPABILITIES, Capability};
    use std::collections::HashSet;

    const INTEGRATIONS_JSON: &str = include_str!("integrations_catalog.json");
    const LANGUAGES: [&str; 7] = ["de", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans"];

    fn integration_ids() -> HashSet<String> {
        let entries: Vec<serde_json::Value> = serde_json::from_str(INTEGRATIONS_JSON).unwrap();
        entries
            .iter()
            .map(|e| e["id"].as_str().expect("catalog entry has an id").to_string())
            .collect()
    }

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
    fn catalog() -> Vec<AgentTemplate> {
        super::catalog().expect("agent_templates.json matches the strict AgentTemplate type")
    }

    #[test]
    fn the_catalog_has_the_sixteen_templates_and_parses_strictly() {
        let templates = catalog();
        assert_eq!(templates.len(), 16);
    }

    #[test]
    fn ids_are_unique_and_kebab_case() {
        let mut seen = HashSet::new();
        for t in catalog() {
            assert!(is_kebab_case(&t.id), "bad id {:?}", t.id);
            assert!(seen.insert(t.id.clone()), "duplicate id {:?}", t.id);
        }
    }

    #[test]
    fn every_text_is_filled_in_english_and_russian() {
        for t in catalog() {
            for (field, value) in [
                ("name_en", &t.name_en),
                ("name_ru", &t.name_ru),
                ("description_en", &t.description_en),
                ("description_ru", &t.description_ru),
                ("long_en", &t.long_en),
                ("long_ru", &t.long_ru),
                ("role_en", &t.role_en),
                ("system_prompt", &t.system_prompt),
                ("starter_en", &t.starter_en),
                ("starter_ru", &t.starter_ru),
            ] {
                assert!(!value.trim().is_empty(), "{}: {field} is empty", t.id);
            }
        }
    }

    #[test]
    fn every_template_has_all_seven_languages_and_matching_schedule_prompts() {
        for t in catalog() {
            let keys: HashSet<&str> = t.l10n.keys().map(String::as_str).collect();
            let expected: HashSet<&str> = LANGUAGES.into_iter().collect();
            assert_eq!(keys, expected, "{}: l10n languages", t.id);
            for (lang, l) in &t.l10n {
                for (field, value) in [
                    ("name", &l.name),
                    ("description", &l.description),
                    ("long", &l.long),
                    ("starter", &l.starter),
                ] {
                    assert!(!value.trim().is_empty(), "{}: {lang}.{field} is empty", t.id);
                }
                assert_eq!(
                    l.schedule_prompts.len(),
                    t.schedules.len(),
                    "{}: {lang}.schedule_prompts must match schedules",
                    t.id
                );
                assert!(
                    l.schedule_prompts.iter().all(|p| !p.trim().is_empty()),
                    "{}: {lang} has an empty schedule prompt",
                    t.id
                );
            }
        }
    }

    #[test]
    fn integrations_exist_in_the_catalog_and_are_not_repeated() {
        let known = integration_ids();
        for t in catalog() {
            let mut seen = HashSet::new();
            for i in &t.integrations {
                assert!(known.contains(&i.id), "{}: unknown integration {:?}", t.id, i.id);
                assert!(
                    seen.insert(i.id.as_str()),
                    "{}: integration {:?} listed twice",
                    t.id,
                    i.id
                );
            }
        }
    }

    #[test]
    fn capabilities_are_known_names_and_not_repeated() {
        for t in catalog() {
            let mut seen = HashSet::new();
            for name in &t.capabilities {
                assert!(
                    Capability::parse(name).is_some(),
                    "{}: unknown capability {:?}",
                    t.id,
                    name
                );
                assert!(
                    seen.insert(name.as_str()),
                    "{}: capability {:?} listed twice",
                    t.id,
                    name
                );
            }
            assert!(t.capabilities.len() <= ALL_CAPABILITIES.len());
        }
    }

    #[test]
    fn every_schedule_cron_is_read_by_the_scheduler() {
        for t in catalog() {
            for s in &t.schedules {
                if let Err(e) = crate::scheduler::next_run(&s.cron, "UTC", 0) {
                    panic!("{}: cron {:?} is not accepted by the scheduler: {e}", t.id, s.cron);
                }
                assert!(
                    !s.prompt_en.trim().is_empty() && !s.prompt_ru.trim().is_empty(),
                    "{}",
                    t.id
                );
            }
        }
    }

    #[test]
    fn every_system_prompt_asks_for_the_owners_language() {
        for t in catalog() {
            assert!(
                t.system_prompt.contains("Reply in the language the owner writes in."),
                "{}: system_prompt lacks the language line",
                t.id
            );
        }
    }

    #[test]
    fn icon_and_accent_are_set() {
        for t in catalog() {
            assert!(
                !t.icon.trim().is_empty() && !t.icon.contains(char::is_whitespace),
                "{}: icon",
                t.id
            );
            assert!(
                is_hex_color(&t.accent),
                "{}: accent {:?} is not #RRGGBB",
                t.id,
                t.accent
            );
        }
    }

    #[test]
    fn an_unknown_field_is_refused() {
        let mut first: serde_json::Value = serde_json::from_str(CATALOG_JSON).unwrap();
        first[0]["bogus_field"] = serde_json::json!(1);
        assert!(serde_json::from_value::<AgentTemplate>(first[0].clone()).is_err());
    }
}
