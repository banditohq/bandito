## What

<!-- The change, in one or two sentences. -->

## Why

<!-- The problem or the goal. Link the issue if there is one. -->

## How I checked it

<!-- Commands you ran and what you saw. Screenshots for UI changes go below. -->

## Checklist

- [ ] The PR title is a Conventional Commit (`feat: …`, `fix: …`, `docs: …`, …). It becomes the changelog entry.
- [ ] Tests added or updated for the behavior that changed.
- [ ] Daemon change: `.claude/verify.sh` is green. Apple change: `apps/mac/scripts/test.sh` (runs `swift test` and the i18n check) is green.
- [ ] `docs/ARCHITECTURE.md` is updated if behavior, RPC, store or the protocol changed.
- [ ] New user-facing strings are added to `i18n/en.json` only, and `python3 i18n/build.py` was run. No hard-coded UI text.
- [ ] Screenshots attached for UI changes (snapshot PNGs from `BanditoUITests`).
