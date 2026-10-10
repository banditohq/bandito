# Bandito daemon — notes for agents

Rust 2024, one crate `bandito`: the server (`bandito daemon`), the CLI (`bandito service|backup|info|…`), runtime
adapters for Claude Code / Codex / Grok, the store (SQLite, WAL), RPC over WebSocket and a Unix socket.

## Checks

`../.claude/verify.sh` (fmt --check, clippy -D warnings, tests). On a machine where someone uses Bandito, run tests
with a throwaway data folder: `BANDITO_HOME=$(mktemp -d) cargo test`.

## Data folder — the one rule that must never break

- The data folder is `--home`, else `BANDITO_HOME`, else `~/.bandito` (`home.rs`). In unit tests (`cfg(test)`) it
  resolves under `target/unit-home-<pid>`, never the real one.
- A test creates its own temp folder and removes only that. Never build `App` or a path from `data_home()` /
  `dirs::home_dir()` in a test that deletes or rewrites files.
- The daemon holds `<home>/run/daemon.lock` for its whole life; a second daemon on the same folder waits up to 20 s,
  then refuses.
- Backups (`backup.rs`): `VACUUM INTO` copies in `<home>/backups` at start (before migrations), on a version change and
  daily; 14 kept; `bandito backup list|restore`. Never write a database file any other way.

## Conventions

- RPC methods in `src/rpc/<area>.rs`; params and replies are snake_case JSON; new capability → a feature name in
  `daemon.info` so older apps can check it.
- Changing the protocol, the store schema or a feature: update `docs/ARCHITECTURE.md` in the same change.
- Store migrations are additive; a new column has a default; old rows keep working.
- User-facing errors: one short English sentence that says what to do.
- Integrations catalog: `src/integrations_catalog.json` — every entry checked against the service's official docs;
  no keys or tokens in it.
