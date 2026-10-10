# Contributing to Bandito

Thanks for wanting to help. Bandito is early, so the most useful contributions right now are issues: bugs, ideas, and what annoys you in other agent tools. Pull requests are welcome too, as long as they stay small and focused.

- One change per pull request. Say what changed and why.
- The PR title is a [Conventional Commit](https://www.conventionalcommits.org/) (`feat: …`, `fix: …`, `docs: …`). It becomes the changelog line.
- `main` is protected. Changes land through pull requests after the checks pass.
- Security issues go to security@bandito.dev, not to public issues. See [SECURITY.md](SECURITY.md).

## Quick start

### Requirements

- Rust stable (edition 2024), with `rustfmt` and `clippy`
- Xcode 26 or newer, for the Mac app
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Python 3, for the i18n build

### Run the daemon

```sh
cd daemon
cargo run -- daemon
```

The daemon runs in the foreground and listens on `127.0.0.1:7878` by default. Use `--listen <addr>` to change it. Keep it on loopback unless it sits behind TLS or a private network.

### Build the Mac app

```sh
apps/mac/scripts/build.sh
```

The script generates the Xcode project with XcodeGen, builds the Debug app without signing, and prints the path of `Bandito.app`. Set `BANDITO_DERIVED_DATA` to put build products somewhere else.

### Run the tests

| Area | Command | What it checks |
|---|---|---|
| Daemon | `.claude/verify.sh` | `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test` |
| Apple packages | `apps/mac/scripts/test.sh` | `swift test` for BanditoKit (models, reducer, L10n, UI snapshots) and the i18n check |
| Strings | `python3 i18n/build.py --check` | keys, placeholders, generated files are up to date |

Tests never need network access or a logged-in CLI. Runtime adapters are tested against fake CLIs that replay recorded transcripts in `daemon/tests/fixtures/`. The `apps/mac/scripts/test.sh` script keeps SwiftPM build products in `${BANDITO_SWIFT_SCRATCH:-$HOME/.cache/bandito-swift}`.

## How the code is organized

**Daemon** (`daemon/`, one Rust crate `bandito`):

- `src/main.rs`: CLI entry (`bandito daemon`, `status`, `pair`, `mcp`, …)
- `src/rpc/`: JSON-RPC dispatch (`mod.rs`, including the `FEATURES` list), transports (`unix.rs`, `ws.rs`), auth and pairing
- `src/store/`: SQLite, one file per area (`agents.rs`, `approvals.rs`, …); migrations in `migrations/`
- `src/runtime/`: `claude.rs`, `codex.rs`, `grok.rs`; `process.rs` holds the shared child-process plumbing
- `src/policy.rs`, `scheduler.rs`, `crew.rs`, `supervisor.rs`, `event.rs`: approval rules, cron, crew MCP, runtime supervision, event types
- `tests/`: integration tests; `tests/fixtures/` holds recorded protocol transcripts

**Apple** (`apps/mac/`):

- `BanditoKit/Sources/BanditoKit`: wire models, RPC client, transports, thread reducer, server model
- `BanditoKit/Sources/BanditoDesign`: colors and tokens generated from `brand/tokens`
- `BanditoKit/Sources/BanditoL10n`: strings generated from `i18n/`
- `BanditoKit/Sources/BanditoUI`: SwiftUI screens shared by the Mac app and the future iPhone app
- `BanditoKit/Tests`: `BanditoKitTests` and `BanditoUITests` (snapshots)
- `Bandito/`: the Mac app target. It holds only app-level code.

**Other:**

- `i18n/`: every user-facing string. `build.py` generates the platform files.
- `brand/`: logos, press kit, and design tokens (`brand/tokens/build.py`).
- `docs/ARCHITECTURE.md`: the design source of truth. Read it before a change to behavior.

## Recipes

### Add a language

1. Copy `i18n/en.json` to `i18n/<code>.json`, where `<code>` is a BCP 47 tag such as `it` or `pt-BR`, and translate the values.
2. Add `code`, `name` (English name) and `native` (the language's own name) to `i18n/languages.json`.
3. Run `python3 i18n/build.py`.
4. Open a pull request with the new file, the `languages.json` entry and the regenerated files.

The rules for translators are in [Translations](#translations).

### Change or add a UI string

1. Add the key to `i18n/en.json`. Keys are flat and dotted (`thread.send`). Use `{name}` for placeholders; a placeholder named `count` is a number, any other is text.
2. Run `python3 i18n/build.py`. It regenerates the per-language `Localizable.strings` and `Localizable.stringsdict` files under `apps/mac/BanditoKit/Sources/BanditoL10n/Resources/<code>.lproj/` and the typed accessors in `apps/mac/BanditoKit/Sources/BanditoL10n/L10n.swift`.
3. Use the accessor in SwiftUI code. The key `agent.menu.copyId` is `L10n.Agent.Menu.copyId`.
4. Commit `en.json` and the regenerated files together. Other languages are optional: a missing key falls back to English.

Never hard-code UI text in views.

### Add an RPC method

The daemon's RPC types are the contract. The same method works on every transport.

1. **Daemon.** Add a match arm in `dispatch` in `daemon/src/rpc/mod.rs`. Put the logic in the module that owns it (`store/<area>.rs`, `policy.rs`, …) and test it there.
2. **Types.** Add the request and response types to `apps/mac/BanditoKit/Sources/BanditoKit/Models.swift`, with `Codable` conformance, and the client call to `RPC.swift` if the app needs it.
3. **Feature flag.** If this is a new capability, add its name to `FEATURES` in `daemon/src/rpc/mod.rs`. Clients show a feature only when `daemon.info` lists it, so new apps keep working with old daemons.
4. **Docs.** Add the method to the RPC section of `docs/ARCHITECTURE.md` in the same pull request.

### Add a runtime

A runtime drives an official CLI through its own structured protocol. No screen scraping.

1. Write the tests first: contract tests in `daemon/tests/<name>_runtime.rs`, run against the fake CLI with `env!("CARGO_BIN_EXE_fakecli")`. Watch them fail.
2. Record the protocol transcripts into `daemon/tests/fixtures/<name>/*.jsonl`. The script format is described at the top of `daemon/src/bin/fakecli.rs`: `expect`, `send`, `raw`, `stderr`, `spawn_sleep`.
3. Implement `Runtime` (`kind`, `status`, `spawn`) and `Session` (`send`, `interrupt`, `resolve`, `shutdown`) in `daemon/src/runtime/<name>.rs`. Use `runtime/process.rs` for the child process.
4. Add the kind to `RuntimeKind` in `daemon/src/runtime/mod.rs` (`as_str` and `parse`).
5. Update the runtimes table in `docs/ARCHITECTURE.md`.

Tests that need a real, logged-in CLI are marked `#[ignore]` and run by hand, as in `daemon/tests/claude_live.rs`.

### Add a screen

1. Write the SwiftUI view in `apps/mac/BanditoKit/Sources/BanditoUI/`. Views get their data from `AppModel` and send intents to the daemon over RPC. They never compute server state.
2. Take colors and sizes from `BanditoDesign`. Take strings from `L10n` (see [Change or add a UI string](#change-or-add-a-ui-string)).
3. Add a snapshot test in `apps/mac/BanditoKit/Tests/BanditoUITests/Snapshots.swift`. It renders the screen to PNG in `$BANDITO_SNAPSHOTS`, so run it with that variable set to a folder you can open.
4. Attach the PNG files to the pull request.

## Pull requests

- Keep the title a Conventional Commit. Scopes are optional.
- Keep PRs small and focused. Split a refactor from a behavior change.
- If behavior, RPC, store or protocol changes, update `docs/ARCHITECTURE.md` in the same PR.
- CI must be green. The required check is **`ci-ok`** (`.github/workflows/ci.yml`). It runs on every pull request and passes when every job that applies to your change passed. A job for a part of the repo you did not touch is skipped, and a skipped job counts as passed. The jobs behind it are `apple` (Mac app, guide), `i18n`, `daemon` (fmt, clippy, tests) and `audit` (cargo audit and cargo deny, when dependencies change). The PR-title check runs next to it.
- One approval from a member of `@banditohq/core` (see `.github/CODEOWNERS`).
- You don't need to sign off commits (no DCO).

## Code style

**Rust.** Run `cargo fmt` (`max_width = 120` in `daemon/rustfmt.toml`) and `cargo clippy --all-targets -- -D warnings`. Errors are `anyhow::Result` inside the daemon, with short English messages. No `unwrap()` outside tests, except on an invariant with a comment that says why it holds.

**Swift.** Format with `swift-format` and its default configuration, as shipped with Xcode. No force unwrap (`!`) in production code.

**Everywhere.** Code, comments and docs are in English. The `.editorconfig` sets UTF-8, LF line endings, a final newline, no trailing spaces, 4 spaces for Rust and Swift, and 2 for YAML, JSON and Markdown.

## Translations

All user-facing strings live in `i18n/`. `i18n/en.json` is the reference; every language is one file next to it, listed in `i18n/languages.json`. Generated platform files are committed with the source: run `python3 i18n/build.py` after every change and commit the result.

**Fix a string.** Edit the value in `i18n/<code>.json`, run `python3 i18n/build.py`, and commit the JSON together with the regenerated files under `apps/mac/BanditoKit/Sources/BanditoL10n/`.

**Rules.**
- Translate values only. Keys are fixed and must exist in `en.json`; a key that does not exist there fails the check.
- Placeholders such as `{name}` must be kept exactly as in English, with the same names and the same set. Do not translate them. A placeholder named `count` is a number; any other placeholder is text.
- Text in backticks (commands such as `bandito pair`) is not translated. Product and protocol names (Bandito, Claude Code, Codex, Grok, Tailscale, SSH, TLS, URL, ID) stay as they are.
- A literal `%` is written as is; the build escapes it for the platform.
- Plurals are objects keyed by CLDR categories: `zero`, `one`, `two`, `few`, `many`, `other`. `other` is required. Use only the categories your language needs. Placeholders are checked across all forms together. A plural must use the `{count}` placeholder, because it selects the form.
- A missing key is not an error. The build prints a warning with the number of missing keys, and the app shows English for those strings.
- Run `python3 i18n/build.py --check` before pushing. CI runs the same check on changes to `i18n/` and to the generated sources.

## Security

Please don't open a public issue for a vulnerability. Email security@bandito.dev. See [SECURITY.md](SECURITY.md).

## License

Bandito is licensed under the [Functional Source License 1.1, ALv2 Future License](LICENSE.md). By contributing you agree that your contribution is licensed under the repository license.
