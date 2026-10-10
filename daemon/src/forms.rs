//! Forms an agent asks the human for (`ask_form`): the spec as the agent writes it, its checks, and the
//! checks of the answer. See docs/ARCHITECTURE.md#forms.

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

/// Most fields in one form.
pub const MAX_FIELDS: usize = 20;
/// Most options of a choice or multichoice field.
pub const MAX_OPTIONS: usize = 20;
/// Longest field id, in bytes.
const MAX_ID_BYTES: usize = 64;
/// Longest comment with a rejection, in bytes.
pub const MAX_COMMENT_BYTES: usize = 4 * 1024;
/// Longest answer of a text or textarea field, in bytes.
pub const MAX_TEXT_BYTES: usize = 8 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FormKind {
    /// Questions for the human; the agent goes on with the answers.
    Question,
    /// A confirmation before an action that leaves the server (a letter, a post, a payment).
    /// The fields are shown as an editable summary.
    Confirm,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FieldType {
    Text,
    Textarea,
    Email,
    Number,
    Choice,
    Multichoice,
    Boolean,
    Date,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FormField {
    pub id: String,
    pub label: String,
    #[serde(rename = "type")]
    pub field_type: FieldType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub required: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub help: Option<String>,
}

/// A checked form. Built by [`parse_spec`]; the same shape goes into the `form_requested` event.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FormSpec {
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub intro: Option<String>,
    pub kind: FormKind,
    pub fields: Vec<FormField>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub submit_label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reject_label: Option<String>,
}

/// How a form ended. Stored as the form's answer and sent to the agent as its tool result.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FormAction {
    Submit,
    Reject,
    Expired,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// The checked values, by field id.
    Submit(Map<String, Value>),
    Reject(Option<String>),
    /// Nobody answered in time, or the turn was cancelled, paused or deleted first.
    Expired,
}

impl Outcome {
    pub fn action(&self) -> FormAction {
        match self {
            Outcome::Submit(_) => FormAction::Submit,
            Outcome::Reject(_) => FormAction::Reject,
            Outcome::Expired => FormAction::Expired,
        }
    }

    /// `{action, values?, comment?}`: `values` only on submit, `comment` only when given on reject.
    pub fn to_json(&self) -> Value {
        match self {
            Outcome::Submit(values) => json!({ "action": "submit", "values": values }),
            Outcome::Reject(Some(comment)) => json!({ "action": "reject", "comment": comment }),
            Outcome::Reject(None) => json!({ "action": "reject" }),
            Outcome::Expired => json!({ "action": "expired" }),
        }
    }
}

fn is_valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= MAX_ID_BYTES && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Checks the spec an agent sent to `ask_form`. The error text is for the agent, in English.
pub fn parse_spec(v: &Value) -> Result<FormSpec, String> {
    let mut spec: FormSpec = serde_json::from_value(v.clone()).map_err(|e| format!("ask_form: {e}"))?;
    if spec.title.trim().is_empty() {
        return Err("title is required".into());
    }
    if spec.fields.is_empty() || spec.fields.len() > MAX_FIELDS {
        return Err(format!(
            "fields needs 1 to {MAX_FIELDS} fields, got {}",
            spec.fields.len()
        ));
    }
    let mut seen: Vec<&str> = Vec::new();
    for field in &spec.fields {
        if !is_valid_id(&field.id) {
            return Err(format!(
                "field id \"{}\" must be 1 to {MAX_ID_BYTES} letters, digits, _ or -",
                field.id
            ));
        }
        if seen.contains(&field.id.as_str()) {
            return Err(format!("field id \"{}\" is used twice", field.id));
        }
        seen.push(&field.id);
        if field.label.trim().is_empty() {
            return Err(format!("field \"{}\" needs a label", field.id));
        }
    }
    for field in &mut spec.fields {
        let is_choice = matches!(field.field_type, FieldType::Choice | FieldType::Multichoice);
        if !is_choice {
            // Options mean nothing for the other types: they are dropped rather than refused.
            field.options = None;
            continue;
        }
        let options = field.options.clone().unwrap_or_default();
        if options.is_empty() || options.len() > MAX_OPTIONS {
            return Err(format!(
                "field \"{}\" needs 1 to {MAX_OPTIONS} options, got {}",
                field.id,
                options.len()
            ));
        }
        if options.iter().any(|o| o.trim().is_empty()) {
            return Err(format!("field \"{}\" has an empty option", field.id));
        }
        for (i, o) in options.iter().enumerate() {
            if options[..i].contains(o) {
                return Err(format!("field \"{}\" has the option \"{o}\" twice", field.id));
            }
        }
    }
    // A default must be a valid answer for its field, so the form never starts out of bounds.
    for field in &spec.fields {
        if let Some(default) = field.default.as_ref().filter(|d| !d.is_null()) {
            coerce(field, default).map_err(|e| format!("default of \"{}\": {e}", field.id))?;
        }
    }
    Ok(spec)
}

/// Checks the answer to a form and returns the values by field id. A field left out takes its default when
/// it has one. Unknown ids are refused.
pub fn check_values(spec: &FormSpec, values: &Value) -> Result<Map<String, Value>, String> {
    let given = match values {
        Value::Null => Map::new(),
        Value::Object(map) => map.clone(),
        _ => return Err("values must be an object".into()),
    };
    if let Some(unknown) = given.keys().find(|k| !spec.fields.iter().any(|f| &f.id == *k)) {
        return Err(format!("unknown field \"{unknown}\""));
    }
    let mut out = Map::new();
    for field in &spec.fields {
        let value = match given.get(&field.id) {
            Some(v) if !v.is_null() => Some(coerce(field, v).map_err(|e| format!("field \"{}\": {e}", field.id))?),
            _ => match field.default.as_ref().filter(|d| !d.is_null()) {
                Some(d) => Some(coerce(field, d)?),
                None => None,
            },
        };
        match value {
            Some(v) if !is_empty(&v) => {
                out.insert(field.id.clone(), v);
            }
            _ if field.required => return Err(format!("field \"{}\" is required", field.id)),
            _ => {}
        }
    }
    Ok(out)
}

/// Empty text and an empty list count as no answer.
fn is_empty(v: &Value) -> bool {
    match v {
        Value::String(s) => s.trim().is_empty(),
        Value::Array(a) => a.is_empty(),
        _ => false,
    }
}

/// One value of a field, in its canonical form: numbers come out as numbers, lists as lists.
fn coerce(field: &FormField, v: &Value) -> Result<Value, String> {
    let options = field.options.as_deref().unwrap_or(&[]);
    match field.field_type {
        FieldType::Text | FieldType::Textarea => {
            let s = v.as_str().ok_or("expected text")?;
            if s.len() > MAX_TEXT_BYTES {
                return Err("text is longer than 8 KB".into());
            }
            Ok(Value::String(s.to_string()))
        }
        FieldType::Email => {
            let s = v.as_str().ok_or("expected an email address")?;
            let valid = !s.chars().any(char::is_whitespace)
                && s.split_once('@')
                    .is_some_and(|(local, domain)| !local.is_empty() && !domain.is_empty());
            if valid {
                Ok(Value::String(s.to_string()))
            } else {
                Err(format!("\"{s}\" is not an email address"))
            }
        }
        FieldType::Number => {
            let n = match v {
                Value::Number(n) => n.as_f64(),
                Value::String(s) => s.trim().parse::<f64>().ok(),
                _ => None,
            }
            .filter(|n| n.is_finite())
            .ok_or("expected a number")?;
            if n.fract() == 0.0 && n.abs() < 9.0e15 {
                Ok(json!(n as i64))
            } else {
                Ok(json!(n))
            }
        }
        FieldType::Choice => {
            let s = v.as_str().ok_or("expected one of the options")?;
            if options.iter().any(|o| o == s) {
                Ok(Value::String(s.to_string()))
            } else {
                Err(format!("\"{s}\" is not one of the options"))
            }
        }
        FieldType::Multichoice => {
            let list = v.as_array().ok_or("expected a list of options")?;
            let mut picked: Vec<Value> = Vec::new();
            for item in list {
                let s = item.as_str().ok_or("expected a list of options")?;
                if !options.iter().any(|o| o == s) {
                    return Err(format!("\"{s}\" is not one of the options"));
                }
                if picked.iter().any(|p| p.as_str() == Some(s)) {
                    return Err(format!("\"{s}\" is picked twice"));
                }
                picked.push(Value::String(s.to_string()));
            }
            Ok(Value::Array(picked))
        }
        FieldType::Boolean => v
            .as_bool()
            .map(Value::Bool)
            .ok_or_else(|| "expected true or false".into()),
        FieldType::Date => {
            let s = v.as_str().ok_or("expected a date as YYYY-MM-DD")?;
            NaiveDate::parse_from_str(s, "%Y-%m-%d")
                .map(|_| Value::String(s.to_string()))
                .map_err(|_| format!("\"{s}\" is not a date as YYYY-MM-DD"))
        }
    }
}

/// The comment of a rejection: text of a sane size, or nothing.
pub fn check_comment(comment: Option<&Value>) -> Result<Option<String>, String> {
    match comment {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if s.trim().is_empty() => Ok(None),
        Some(Value::String(s)) if s.len() > MAX_COMMENT_BYTES => {
            Err(format!("comment is longer than {MAX_COMMENT_BYTES} bytes"))
        }
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(_) => Err("comment must be text".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(fields: Value) -> Value {
        json!({ "title": "Who are you?", "kind": "question", "fields": fields })
    }

    fn one(field: Value) -> Value {
        spec(json!([field]))
    }

    #[test]
    fn a_plain_question_passes_and_keeps_its_labels() {
        let s = parse_spec(&spec(json!([
            { "id": "name", "label": "Name", "type": "text", "required": true },
            { "id": "color", "label": "Color", "type": "choice", "options": ["red", "blue"] },
        ])))
        .unwrap();
        assert_eq!(s.kind, FormKind::Question);
        assert_eq!(s.fields.len(), 2);
        assert!(s.fields[0].required);
        assert_eq!(
            s.fields[1].options.as_deref(),
            Some(&["red".to_string(), "blue".to_string()][..])
        );
    }

    #[test]
    fn title_and_fields_are_required_and_capped() {
        assert_eq!(
            parse_spec(&json!({ "title": "  ", "kind": "question", "fields": [{"id":"a","label":"A","type":"text"}] }))
                .unwrap_err(),
            "title is required"
        );
        assert!(
            parse_spec(&spec(json!([])))
                .unwrap_err()
                .starts_with("fields needs 1 to 20")
        );
        let many: Vec<Value> = (0..21)
            .map(|i| json!({ "id": format!("f{i}"), "label": "x", "type": "text" }))
            .collect();
        assert!(parse_spec(&spec(json!(many))).unwrap_err().contains("got 21"));
    }

    #[test]
    fn field_ids_are_simple_and_unique() {
        let bad = one(json!({ "id": "has space", "label": "x", "type": "text" }));
        assert!(parse_spec(&bad).unwrap_err().contains("has space"));
        let long = "a".repeat(65);
        assert!(parse_spec(&one(json!({ "id": long, "label": "x", "type": "text" }))).is_err());
        let twice = spec(json!([
            { "id": "a", "label": "x", "type": "text" },
            { "id": "a", "label": "y", "type": "text" },
        ]));
        assert_eq!(parse_spec(&twice).unwrap_err(), "field id \"a\" is used twice");
    }

    #[test]
    fn a_label_is_required() {
        let e = parse_spec(&one(json!({ "id": "a", "label": " ", "type": "text" }))).unwrap_err();
        assert_eq!(e, "field \"a\" needs a label");
    }

    #[test]
    fn choice_and_multichoice_need_options() {
        let e = parse_spec(&one(json!({ "id": "c", "label": "C", "type": "choice" }))).unwrap_err();
        assert_eq!(e, "field \"c\" needs 1 to 20 options, got 0");
        let e = parse_spec(&one(
            json!({ "id": "c", "label": "C", "type": "multichoice", "options": [] }),
        ))
        .unwrap_err();
        assert!(e.contains("needs 1 to 20 options"));
        let many: Vec<String> = (0..21).map(|i| format!("o{i}")).collect();
        let e = parse_spec(&one(
            json!({ "id": "c", "label": "C", "type": "choice", "options": many }),
        ))
        .unwrap_err();
        assert!(e.contains("got 21"));
        let e = parse_spec(&one(
            json!({ "id": "c", "label": "C", "type": "choice", "options": ["a", "a"] }),
        ))
        .unwrap_err();
        assert!(e.contains("twice"));
    }

    #[test]
    fn options_are_dropped_on_other_types() {
        let s = parse_spec(&one(
            json!({ "id": "t", "label": "T", "type": "text", "options": ["x"] }),
        ))
        .unwrap();
        assert_eq!(s.fields[0].options, None);
    }

    #[test]
    fn an_unknown_type_is_a_clear_error() {
        let e = parse_spec(&one(json!({ "id": "t", "label": "T", "type": "photo" }))).unwrap_err();
        assert!(e.starts_with("ask_form:") && e.contains("photo"), "{e}");
    }

    #[test]
    fn a_default_must_fit_its_field() {
        let e = parse_spec(&one(
            json!({ "id": "d", "label": "D", "type": "date", "default": "31.12.2026" }),
        ))
        .unwrap_err();
        assert!(e.starts_with("default of \"d\""), "{e}");
        let ok = parse_spec(&one(
            json!({ "id": "d", "label": "D", "type": "date", "default": "2026-12-31" }),
        ));
        assert!(ok.is_ok());
    }

    #[test]
    fn confirm_kind_and_labels_pass_through() {
        let s = parse_spec(&json!({
            "title": "Send the letter?", "intro": "To the client", "kind": "confirm",
            "fields": [{ "id": "body", "label": "Text", "type": "textarea" }],
            "submit_label": "Send", "reject_label": "Not now",
        }))
        .unwrap();
        assert_eq!(s.kind, FormKind::Confirm);
        assert_eq!(s.submit_label.as_deref(), Some("Send"));
        assert_eq!(s.reject_label.as_deref(), Some("Not now"));
        assert_eq!(s.intro.as_deref(), Some("To the client"));
    }

    fn checked(fields: Value, values: Value) -> Result<Map<String, Value>, String> {
        check_values(&parse_spec(&spec(fields)).unwrap(), &values)
    }

    #[test]
    fn a_required_field_must_be_answered() {
        let fields = json!([{ "id": "name", "label": "Name", "type": "text", "required": true }]);
        assert_eq!(
            checked(fields.clone(), json!({})).unwrap_err(),
            "field \"name\" is required"
        );
        assert_eq!(
            checked(fields.clone(), json!({ "name": "  " })).unwrap_err(),
            "field \"name\" is required"
        );
        assert_eq!(checked(fields, json!({ "name": "Ann" })).unwrap()["name"], "Ann");
    }

    #[test]
    fn an_optional_field_may_be_left_out() {
        let fields = json!([{ "id": "note", "label": "Note", "type": "text" }]);
        assert!(checked(fields, json!({})).unwrap().is_empty());
    }

    #[test]
    fn email_needs_an_at_sign_with_text_on_both_sides() {
        let fields = json!([{ "id": "mail", "label": "Mail", "type": "email", "required": true }]);
        assert!(checked(fields.clone(), json!({ "mail": "ann@example.com" })).is_ok());
        for bad in ["ann.example.com", "@example.com", "ann@", "a nn@x.y"] {
            assert!(checked(fields.clone(), json!({ "mail": bad })).is_err(), "{bad}");
        }
    }

    #[test]
    fn number_accepts_numbers_and_numeric_text() {
        let fields = json!([{ "id": "n", "label": "N", "type": "number" }]);
        assert_eq!(checked(fields.clone(), json!({ "n": 7 })).unwrap()["n"], json!(7));
        assert_eq!(checked(fields.clone(), json!({ "n": "2.5" })).unwrap()["n"], json!(2.5));
        assert!(checked(fields.clone(), json!({ "n": "seven" })).is_err());
        assert!(checked(fields, json!({ "n": true })).is_err());
    }

    #[test]
    fn choice_must_be_one_of_the_options() {
        let fields = json!([{ "id": "c", "label": "C", "type": "choice", "options": ["red", "blue"] }]);
        assert_eq!(checked(fields.clone(), json!({ "c": "red" })).unwrap()["c"], "red");
        assert_eq!(
            checked(fields, json!({ "c": "green" })).unwrap_err(),
            "field \"c\": \"green\" is not one of the options"
        );
    }

    #[test]
    fn multichoice_is_a_list_of_distinct_options() {
        let fields = json!([{ "id": "m", "label": "M", "type": "multichoice", "options": ["a", "b", "c"] }]);
        assert_eq!(
            checked(fields.clone(), json!({ "m": ["a", "c"] })).unwrap()["m"],
            json!(["a", "c"])
        );
        assert!(checked(fields.clone(), json!({ "m": ["a", "a"] })).is_err());
        assert!(checked(fields.clone(), json!({ "m": ["z"] })).is_err());
        assert!(checked(fields.clone(), json!({ "m": "a" })).is_err());
        let required = json!([{ "id": "m", "label": "M", "type": "multichoice", "options": ["a"], "required": true }]);
        assert_eq!(
            checked(required, json!({ "m": [] })).unwrap_err(),
            "field \"m\" is required"
        );
        assert!(checked(fields, json!({})).unwrap().is_empty());
    }

    #[test]
    fn boolean_and_date() {
        let fields = json!([
            { "id": "ok", "label": "OK", "type": "boolean" },
            { "id": "day", "label": "Day", "type": "date" },
        ]);
        let v = checked(fields.clone(), json!({ "ok": true, "day": "2026-10-10" })).unwrap();
        assert_eq!(v["ok"], json!(true));
        assert_eq!(v["day"], "2026-10-10");
        assert!(checked(fields.clone(), json!({ "ok": "yes" })).is_err());
        assert!(checked(fields.clone(), json!({ "day": "2026-02-30" })).is_err());
        assert!(checked(fields, json!({ "day": "10.10.2026" })).is_err());
    }

    #[test]
    fn defaults_fill_in_what_was_left_out() {
        let fields =
            json!([{ "id": "tz", "label": "Zone", "type": "choice", "options": ["UTC", "MSK"], "default": "MSK" }]);
        assert_eq!(checked(fields.clone(), json!({})).unwrap()["tz"], "MSK");
        assert_eq!(checked(fields, json!({ "tz": "UTC" })).unwrap()["tz"], "UTC");
    }

    #[test]
    fn unknown_fields_and_bad_shapes_are_refused() {
        let fields = json!([{ "id": "a", "label": "A", "type": "text" }]);
        assert_eq!(
            checked(fields.clone(), json!({ "b": "x" })).unwrap_err(),
            "unknown field \"b\""
        );
        assert_eq!(checked(fields, json!("x")).unwrap_err(), "values must be an object");
    }

    #[test]
    fn outcome_json_has_the_wire_shape() {
        let mut values = Map::new();
        values.insert("name".into(), json!("Ann"));
        assert_eq!(
            Outcome::Submit(values).to_json(),
            json!({ "action": "submit", "values": { "name": "Ann" } })
        );
        assert_eq!(
            Outcome::Reject(Some("no".into())).to_json(),
            json!({ "action": "reject", "comment": "no" })
        );
        assert_eq!(Outcome::Reject(None).to_json(), json!({ "action": "reject" }));
        assert_eq!(Outcome::Expired.action(), FormAction::Expired);
    }

    #[test]
    fn text_answers_are_capped_at_8_kb() {
        let fields = json!([{ "id": "t", "label": "T", "type": "textarea" }]);
        let ok = "a".repeat(MAX_TEXT_BYTES);
        assert!(checked(fields.clone(), json!({ "t": ok })).is_ok());
        let long = "a".repeat(MAX_TEXT_BYTES + 1);
        assert_eq!(
            checked(fields, json!({ "t": long })).unwrap_err(),
            "field \"t\": text is longer than 8 KB"
        );
    }

    #[test]
    fn comment_is_text_of_sane_size() {
        assert_eq!(check_comment(None).unwrap(), None);
        assert_eq!(check_comment(Some(&json!("  "))).unwrap(), None);
        assert_eq!(check_comment(Some(&json!("later"))).unwrap().as_deref(), Some("later"));
        assert!(check_comment(Some(&json!(5))).is_err());
        let long = "x".repeat(MAX_COMMENT_BYTES + 1);
        assert!(check_comment(Some(&json!(long))).is_err());
    }
}
