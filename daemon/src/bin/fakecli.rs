//! Test double for agent CLIs. Replays a script so runtime adapters can be
//! tested without network or logins. Not shipped in releases.
//!
//! Env:
//! - `FAKECLI_SCRIPT`   path to a JSONL script (required)
//! - `FAKECLI_ARGS_OUT` if set, argv (without argv[0]) is written there as a JSON array
//!
//! Script steps, one JSON object per line (blank lines and lines starting
//! with `//` are skipped):
//! - `{"expect": <json>}`  read stdin lines until one *contains* `<json>`
//!   (objects: every given key must match recursively; other values: equal).
//!   Non-matching lines are skipped. Stdin EOF while expecting → exit 3.
//! - `{"send": <json>}`    write `<json>` as one line to stdout. Any string
//!   value `"$last:<json-pointer>"` is replaced by the value at that pointer
//!   in the last matched input (e.g. `"$last:/id"`).
//! - `{"stderr": "text"}`  write a line to stderr.
//! - `{"sleep_ms": n}`
//! - `{"exit": code}`      exit now.
//! - `{"expect_eof": true}` read until stdin closes.
//!
//! When the script ends, the process waits for stdin EOF and exits 0.

use serde_json::Value;
use std::io::{BufRead, Write};

fn contains(have: &Value, want: &Value) -> bool {
    match (have, want) {
        (Value::Object(h), Value::Object(w)) => w.iter().all(|(k, wv)| h.get(k).is_some_and(|hv| contains(hv, wv))),
        _ => have == want,
    }
}

fn substitute(v: &Value, last: &Value) -> Value {
    match v {
        Value::String(s) => match s.strip_prefix("$last:") {
            Some(ptr) => last.pointer(ptr).cloned().unwrap_or(Value::Null),
            None => v.clone(),
        },
        Value::Array(a) => Value::Array(a.iter().map(|x| substitute(x, last)).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.clone(), substitute(x, last))).collect()),
        _ => v.clone(),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Ok(p) = std::env::var("FAKECLI_ARGS_OUT") {
        std::fs::write(p, serde_json::to_string(&args).unwrap_or_default()).expect("write args");
    }
    let script =
        std::fs::read_to_string(std::env::var("FAKECLI_SCRIPT").expect("FAKECLI_SCRIPT")).expect("read script");
    let stdin = std::io::stdin();
    let mut lines = stdin.lock().lines();
    let mut out = std::io::stdout().lock();
    let mut last = Value::Null;

    for raw in script.lines() {
        let raw = raw.trim();
        if raw.is_empty() || raw.starts_with("//") {
            continue;
        }
        let step: Value = serde_json::from_str(raw).unwrap_or_else(|e| panic!("bad step {raw}: {e}"));
        if let Some(want) = step.get("expect") {
            loop {
                let Some(Ok(line)) = lines.next() else {
                    std::process::exit(3)
                };
                let Ok(have) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                if contains(&have, want) {
                    last = have;
                    break;
                }
            }
        } else if let Some(v) = step.get("send") {
            writeln!(out, "{}", substitute(v, &last)).expect("stdout");
            out.flush().expect("flush");
        } else if let Some(s) = step.get("stderr").and_then(Value::as_str) {
            eprintln!("{s}");
        } else if let Some(ms) = step.get("sleep_ms").and_then(Value::as_u64) {
            std::thread::sleep(std::time::Duration::from_millis(ms));
        } else if let Some(code) = step.get("exit").and_then(Value::as_i64) {
            std::process::exit(code as i32);
        } else if step.get("expect_eof").is_some() {
            for _ in lines.by_ref() {}
        } else {
            panic!("unknown step {raw}");
        }
    }
    for _ in lines.by_ref() {}
}
