## What

<!-- The change, in one or two sentences. -->

## Why

<!-- The problem or the goal. Link the issue if there is one. -->

## How I checked it

<!-- Commands you ran and what you saw. -->

## Definition of Done

- [ ] The PR title is a Conventional Commit (`feat: …`, `fix: …`, `docs: …`, …). It becomes the changelog line.
- [ ] Tests added or updated for the behavior that changed.
- [ ] Daemon change: `.claude/verify.sh` is green. Apple change: `apps/mac/scripts/test.sh` is green.
- [ ] CI is green, including the required check `ci-ok` (see [CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests)).
- [ ] Review is done: one approval from `@banditohq/core` (see `.github/CODEOWNERS`).
- [ ] UI change: before and after screenshots from the isolated QA copy (`docs/qa/RUNBOOK.md`) are attached. The screen was looked at running, not only tested.
- [ ] Protocol, RPC, store or feature change: `docs/ARCHITECTURE.md` is updated in this PR.
- [ ] Approved design change: `docs/DESIGN_LANGUAGE.md` and the design system are updated in this PR.
- [ ] Every new user-facing string is in `i18n/` for all 9 languages, and `python3 i18n/build.py --check` is green. No literal UI text in code.
- [ ] The in-app guide (`guide/`) covers the change, and `python3 scripts/check_guide.py` is green.
- [ ] No secrets, personal paths or customer data in the diff, screenshots or logs.
