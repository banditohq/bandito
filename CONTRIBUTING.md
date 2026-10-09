# Contributing

Thanks for wanting to help. Bandito is early, so the best contributions right now are issues: bugs, ideas, and what annoys you in other agent tools.

- One change per pull request. Describe what and why.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:` …). They drive the changelog and version numbers.
- `main` is protected: changes land through pull requests after checks pass.
- Security issues go to security@bandito.dev, not to public issues.

## Translations

All user-facing strings live in `i18n/`. `i18n/en.json` is the reference; every language is one file next to it, listed in `i18n/languages.json`. Generated platform files are committed with the source: run `python3 i18n/build.py` after every change and commit the result.

**Fix a string.** Edit the value in `i18n/<code>.json`, run `python3 i18n/build.py`, and commit the JSON together with the regenerated files under `apps/mac/BanditoKit/Sources/BanditoL10n/`.

**Add a language.**
1. Copy `i18n/en.json` to `i18n/<code>.json`, where `<code>` is a BCP 47 tag such as `it` or `pt-BR`, and translate the values.
2. Add an entry with `code`, `name` (English name) and `native` (the language's own name) to `i18n/languages.json`.
3. Run `python3 i18n/build.py`.
4. Open a pull request with these changes.

**Rules.**
- Translate values only. Keys are fixed and must exist in `en.json`; a key that does not exist there fails the check.
- Placeholders such as `{name}` must be kept exactly as in English, with the same names and the same set. Do not translate them. A placeholder named `count` is a number; any other placeholder is text.
- Text in backticks (commands such as `bandito pair`) is not translated. Product and protocol names (Bandito, Claude Code, Codex, Grok, Tailscale, SSH, TLS, URL, ID) stay as they are.
- A literal `%` is written as is; the build escapes it for the platform.
- Plurals are objects keyed by CLDR categories: `zero`, `one`, `two`, `few`, `many`, `other`. `other` is required. Use only the categories your language needs. Placeholders are checked across all forms together.
- A missing key is not an error. The build prints a warning with the number of missing keys, and the app shows English for those strings.
- Run `python3 i18n/build.py --check` before pushing. CI runs the same check on changes to `i18n/` and to the generated sources.

By contributing you agree that your contribution is licensed under the repository license.
