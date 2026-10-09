# Bandito — notes for agents

Public repo (FSL-1.1-ALv2). Everything here is visible to the world: no secrets, no personal paths, no customer data.

- Design source of truth: `docs/ARCHITECTURE.md`. Change it in the same PR as the code.
- `daemon/` — Rust 2024, one crate `bandito`. tokio, axum (ws), rusqlite (bundled), serde, anyhow/thiserror, tracing.
- Checks: `.claude/verify.sh` (fmt --check, clippy -D warnings, tests). Must be green.
- Conventions:
  - Errors: `anyhow::Result` inside the daemon; user-facing messages in English, short.
  - Store: `impl Store` blocks in `daemon/src/store/<area>.rs`, SQL inline, `params![]`, tests in the same file with `Store::open_in_memory()`.
  - Time: Unix milliseconds (`store::now_ms()`), ids: `store::new_id()` (UUID v7).
  - No `unwrap()` outside tests except on invariants with a comment.
  - Tests never need network or a logged-in CLI: runtime adapters are tested against fake CLIs replaying `daemon/tests/fixtures/`.
- Branches + PRs to `main` (protected). Commit messages in English, imperative.
