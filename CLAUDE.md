# Bandito — notes for agents

Public repo (FSL-1.1-ALv2). Everything here is visible to the world: no secrets, no personal paths, no customer data.

## Map

- `daemon/` — Rust 2024, one crate `bandito` (server, CLI, runtimes). Rules: `daemon/CLAUDE.md`.
- `apps/mac/` — SwiftUI app; code in `apps/mac/BanditoKit` (SwiftPM). Rules: `apps/mac/CLAUDE.md`.
- `docs/ARCHITECTURE.md` — design source of truth (protocol, store, features). Change it in the same PR as the code.
- `docs/DESIGN_LANGUAGE.md` — how the app looks and moves: tokens, components, motion, the quality bar.
- Before any UI work read `docs/DESIGN_LANGUAGE.md`; when a design change is approved, update it and the Design System artifact in the same change.
- `docs/APP_SPEC.md`, `docs/MAC_APP_UX.md` — what the app does and how it feels.
- `docs/qa/RUNBOOK.md` — isolated QA copies (QA daemon + QA app). Never QA against the installed Bandito.
- `i18n/*.json` — every UI string, 9 languages; `python3 i18n/build.py` generates the Swift side.
- `guide/*.md` — the in-app guide; `python3 scripts/check_guide.py` checks it covers every screen element.
- `docs/design/` — mirror of the design canvas (`.dc.html` mockups of every screen).

## Checks

- `.claude/verify.sh` — guide check, install script checks, fmt --check, clippy -D warnings, daemon tests. Must be green.
- `python3 i18n/build.py --check` — generated strings are up to date.
- Mac app: `cd apps/mac/BanditoKit && swift test` (two suites: BanditoKitTests, BanditoUITests).
- After any Swift build: `git checkout -- apps/mac/BanditoKit/Package.resolved` (the build rewrites it).

## Hard rules

- Never touch the person's own Bandito: `~/.bandito`, `~/.local/bin/bandito`, the launchd service `dev.bandito.daemon`,
  `/Applications/Bandito.app`, the `dev.bandito.mac` defaults. Tests and QA use their own homes (`BANDITO_HOME`,
  `--home`, `docs/qa/RUNBOOK.md`). A test that deletes a folder deletes only a temp folder it made itself.
- Branches + PRs to `main` (protected). Commit messages in English, imperative.
- Every UI string goes through i18n (all 9 languages), never a literal in Swift.
- A screen is done when it was looked at running, not when its tests pass.

## Conventions

- Errors: `anyhow::Result` inside the daemon; user-facing messages in English, short.
- Store: `impl Store` blocks in `daemon/src/store/<area>.rs`, SQL inline, `params![]`, tests in the same file with
  `Store::open_in_memory()`.
- Time: Unix milliseconds (`store::now_ms()`), ids: `store::new_id()` (UUID v7).
- No `unwrap()` outside tests except on invariants with a comment.
- Tests never need network or a logged-in CLI: runtime adapters are tested against fake CLIs replaying
  `daemon/tests/fixtures/`.

## Pitfalls that already cost us

- A daemon unit test removed `App.data_home`, which defaulted to the real `~/.bandito`, and wiped a person's
  database. Unit tests now resolve the data folder under `target/` (`home.rs`), but keep test homes explicit.
- The app decodes replies with `convertFromSnakeCase`: a Swift `CodingKeys` raw value like `"image_rev"` never
  matches. Use plain camelCase cases; test decoding with `RPCClient.decoder`, not `JSONDecoder()`.
- `LazyVStack` in the chat thread caused a measure ↔ hover update loop (100% CPU). The thread is a `VStack` window.
- Writing `@State` from geometry, scroll or hover callbacks on every call re-renders whole trees. Write on change.
- App releases need the server release of the same version (`release.yml` builds and signs the daemon binaries);
  without it "Add a server" fails.
