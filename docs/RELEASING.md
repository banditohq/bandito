# Releasing

A release has two parts that must match by version: the **server** (the `bandito` daemon binaries and `install.sh`)
and the **Mac app** (Bandito.app, zip and dmg, and the Sparkle appcast item). The app needs the server release of the
same version: without it, "Add a server" fails.

Both parts are built by GitHub Actions. Nobody builds a release on a laptop.

## The release in three moves

1. `scripts/release.sh X.Y.Z` (add `--dry-run` first to see the diff and the notes). It bumps the version in
   `apps/mac/project.yml`, `daemon/Cargo.toml` and `daemon/Cargo.lock`, pushes `release/X.Y.Z` and opens the PR
   `release: Bandito X.Y.Z`. Edit the PR description: it becomes the release notes. When CI is green, squash-merge.
2. Nothing to do: `release-flow` tags the merge commit, builds the server into a draft release (`release.yml`),
   publishes it (latest) and starts `release-app`.
3. Nothing to do yet: `release-app` starts at once and builds, signs and notarizes the app (about 15 minutes, both
   architectures at the same time) **before** it asks for anything. Then **Approve** it: Actions → release-app →
   Review deployments → `stable`. The Approve only publishes (2–3 minutes): the signed files are checked again, the
   update is signed with the Sparkle key, the zip and dmg go to the release, and the run opens the appcast PR in
   `banditohq/platform`, which merges it itself when its ci passes (`appcast-merge.yml` there), and waits for that merge.
   A Telegram message says when it is done (`notify.yml`). Betas (`X.Y.Z-beta.N`) use the `beta` environment, no approval.

The iPhone app's version (`MARKETING_VERSION` in `apps/ios/project.yml`) changes with the same bump; its TestFlight build is `apps/ios/scripts/testflight.sh`.

`scripts/test_bump_version.sh` tests the version bump. The check "appcast == newest release with a zip" lives in
`uptime.yml`, not here.

## When a step fails

Every step can be run again. First fix the cause (the run log says what), then:

| Failed | Do |
|---|---|
| `release.sh` stops | It prints why (dirty tree, tag exists, version not newer). Rerun after fixing; an open PR is just printed again. |
| `release-flow` → tag and draft (version files disagree) | Fix the three files in a new PR to `main` (`scripts/bump-version.sh X.Y.Z`), merge, then run `release-flow` by hand with the version. Never move a tag. |
| `release-flow` → server binaries or publish | Actions → release-flow → Run workflow, `version=X.Y.Z`: it reuses the tag and the draft and builds again. Manual fallback: `gh workflow run release.yml -f tag=vX.Y.Z`, wait, then `gh release edit vX.Y.Z --draft=false --latest`. |
| `release-flow` never started (title or branch changed) | Same: run `release-flow` by hand with the version. By hand entirely: `git tag -a vX.Y.Z -m "Bandito X.Y.Z" <merge commit> && git push origin vX.Y.Z`, `gh release create vX.Y.Z --draft --notes-file notes.md`, then the line above. |
| `release-app` not started | `gh workflow run release-app.yml -f version=X.Y.Z -f channel=stable` (or beta). |
| `release-app` compile, assemble or notarization fails | Fix, then run it again with the same inputs (it uploads with `--clobber`). Nothing is on the release until the publish job runs, so a failure before the Approve costs nothing. Re-run only the failed jobs from the run page when the cause is Apple's service. |
| Appcast PR not merged (checks red, no checks, App lacks rights) | The run is red but the zip is already on the release. Download artifact `appcast-X.Y.Z`, put it in `banditohq/platform` as `public/appcast.xml`, PR, merge. Until that is merged the apps do not see the update. |

# Details

## 1. Version and tag

- Versions are `X.Y.Z` or `X.Y.Z-beta.N`. The beta channel takes beta versions only; the stable channel takes
  versions without a suffix. `release-app.yml` refuses a mismatch.
- The tag is `v<version>` and sits on the release (merge) commit. `release-flow` creates it. (release-please is not
  used for releases; its PRs are not merged.) To tag by hand:

  ```sh
  git tag -a v0.1.6 -m "Bandito 0.1.6" <commit>
  git push origin v0.1.6
  ```

- The app's build number is the commit count of the tagged commit (`git rev-list --count HEAD`). The tag must be
  checked out with full history; the workflow does this.

## 2. Server release (`release.yml`)

`release.yml` is called by `release-flow` on the draft release (and also runs when a release is published by hand, or
from the Actions tab with a tag). It builds `bandito` for Linux (x86_64, aarch64) and macOS
(x86_64, aarch64), uploads the tarballs, `install.sh`, `SHA256SUMS` and `SHA256SUMS.sig` to the release.

`release-flow` publishes the release only after `SHA256SUMS.sig` and all four binaries are on it. By hand: Actions →
`release` → Run workflow → tag `v<version>`.

## 3. Mac app (`release-app.yml`)

`release-flow` starts it. By hand: Actions → `release-app` → Run workflow. Inputs:

- `version`: `X.Y.Z` or `X.Y.Z-beta.N`. The tag `v<version>` must exist.
- `channel`: `stable` or `beta`. It selects the environment of the `publish` job (`stable` or `beta`).

Dispatch it from the default branch: the workflow file is read from the branch you run it on.

Entitlements: `apps/mac/Config/Bandito.entitlements` (`audio-input`, for dictation) comes from `project.yml`; `release-app.sh` re-signs with the entitlements of the built app, so it is kept.

- `dry_run`: builds, signs and notarizes, verifies, signs the appcast item, and stops: nothing goes to the release, no
  appcast PR. Use it to try a change to the workflow.
- `ref` (dry run only): build this branch, tag or commit instead of the tag `v<version>`, which then need not exist.
  Example: `gh workflow run release-app.yml --ref my-branch -f version=0.1.99-beta.1 -f channel=beta -f dry_run=true -f ref=my-branch`.

Entitlements: `apps/mac/Config/Bandito.entitlements` (`audio-input`, for dictation) comes from `project.yml`; `release-app.sh` re-signs with the entitlements of the built app, so it is kept.

Four jobs (macOS 15 runners), so that the slow work comes before the owner's approval:

1. `check` (Linux, seconds): the inputs, that the tag exists, that the release is published and has the server assets.
   It stops with a message if any is missing, and passes the tagged commit to the others.
2. `compile` (two runners at once, `arm64` and `x86_64`, no secrets, no environment): checks out the commit with full
   history, installs XcodeGen and Rust, restores the caches, runs `release-app.sh --stage compile --arch <arch>` (Release
   build of that architecture, signed ad hoc with the app's entitlements) and hands the app over as an artifact. The
   x86_64 daemon is cross-compiled (`apps/mac/project.yml`, build phase of the daemon).
3. `assemble` (environment `beta`: the Developer ID certificate and the App Store Connect key, no reviewers; never the
   Sparkle key): `release-app.sh --stage assemble` joins the two apps file by file with `lipo` (both must hold the same
   files; non-binary files must be identical), checks that every Mach-O is arm64 + x86_64, signs inside out with the
   hardened runtime, notarizes with the API key, staples, builds the zip and the dmg (notarized and stapled too), and
   checks Gatekeeper. The files and a manifest (version, build, commit, SHA-256) go to an artifact kept for 2 days.
   The temporary keychain and the key files are deleted at the end, always.
4. `publish` (environment `stable` or `beta` by `channel`; `stable` waits for the Approve): verifies the manifest, that
   the tag still points at the built commit, the version and build number, `codesign --verify --deep --strict`,
   `stapler validate` and `spctl` of the app and the dmg, and that all binaries are universal; signs the zip with the
   Sparkle key (`release-app.sh --stage appcast`; the key exists only in this job); uploads the zip and dmg to the
   release `v<version>` (clobbering older files); keeps the appcast as artifact `appcast-<version>`; makes a second App
   token (the first expires after an hour), pushes branch `appcast-<version>` to `banditohq/platform`, opens a PR and
   waits until that repo's `appcast-merge.yml` merges it (up to 45 minutes; it never pushes to `main`). The key files
   are deleted at the end, always.

Caches (per architecture; keyed by the Xcode version, the Rust version and `daemon/Cargo.lock` or `Package.resolved`,
with prefix fallbacks): the Rust registry and target folder, and the Swift packages (`SourcePackages`). Xcode's build
products are not cached on purpose: a checkout gives every file a new modification time, so Xcode would recompile
them anyway, and a stale product must never reach a signed release. A cache entry is never trusted for the result:
cargo and SwiftPM check their inputs, and the app itself is always compiled from the checkout.

## 4. Approval (stable)

The `stable` environment must have the owner as a required reviewer (set in the repository settings, Environments).
Only the `publish` job uses it, so a stable run waits for the approval after the build is done (Review deployments)
and the Approve takes minutes. The `beta` environment has no approval gate; it also holds the Developer ID certificate
and the App Store Connect key that `assemble` uses for both channels, so keep those two secrets identical in `beta`
and `stable` when they are rotated. `SPARKLE_ED_KEY` must be set in `stable` and `beta` (publish) and is not needed by
`assemble`. Only users with write access can start a run.

## 5. Appcast

The run merges the `appcast-<version>` PR in `banditohq/platform` itself. The site serves `public/appcast.xml` at
`https://bandito.dev/appcast.xml`; deploying the site is a separate step in that repo.

Check a release after it: download the zip, then `spctl -a -vvv -t exec Bandito.app` must print
`accepted` and `source=Notarized Developer ID`.

## Secrets

Set them in the repository (Settings → Secrets and variables → Actions). Never paste a value into a file, a commit,
an issue or a chat. Use `gh secret set <NAME> < file` or `gh secret set <NAME>` and type the value.

| Name | Used by | What it is | How to create it |
|---|---|---|---|
| `MACOS_CERT_P12_BASE64` | release-app | Developer ID Application certificate with its private key, base64 | In Keychain Access (login), My Certificates: select "Developer ID Application: … (74Q24ZMD7A)", expand it so the key is included, File → Export Items → Personal Information Exchange (.p12), set a password. Then `base64 -i cert.p12 \| gh secret set MACOS_CERT_P12_BASE64`. Delete `cert.p12` afterwards. |
| `MACOS_CERT_PASSWORD` | release-app | The password of that .p12 | The password you set on export. |
| `ASC_KEY_P8_BASE64` | release-app | App Store Connect API private key (.p8), base64 | App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → Generate API Key with role **Developer**. Download the `.p8` (Apple shows it once). Then `base64 -i AuthKey_<KEYID>.p8 \| gh secret set ASC_KEY_P8_BASE64`. |
| `ASC_KEY_ID` | release-app | The key ID of that API key (10 characters) | Shown in the Team Keys list. |
| `ASC_ISSUER_ID` | release-app | The issuer ID of the team (a UUID) | Shown at the top of the Team Keys page. |
| `SPARKLE_ED_KEY` | release-app | Sparkle EdDSA private key, one line | Export it from the release Mac: `generate_keys -x <file>` with Sparkle's `generate_keys` (the copy unpacked under `~/.cache/sparkle/2.10.0/extracted/bin`). It is in that Mac's login Keychain now, from the original `generate_keys`. Then `gh secret set SPARKLE_ED_KEY < <file>` and remove the file. Keep one offline backup in the owner's password manager. The public key is `SUPublicEDKey` in `apps/mac/project.yml`; it must match this key. |
| `BANDITO_BOT_APP_ID`, `BANDITO_BOT_PRIVATE_KEY` | release-app, renovate, gallery | The Bandito Bot GitHub App (installed on the whole organization). release-app makes tokens for `banditohq/platform` | The App needs **Contents: read and write** and **Pull requests: read and write** (Settings → Developer settings → GitHub Apps → Bandito Bot → Permissions; accept the new request in the organization). If the run says "Resource not accessible by integration", this is the missing piece. `PLATFORM_TOKEN` is no longer used and can be deleted. |
| `RELEASE_SIGNING_KEY` | release (server) | Ed25519 private key that signs `SHA256SUMS` | Made by `sh scripts/release-key.sh`, run once by the owner. Not used by release-app. |

Rules that matter:

- The Developer ID certificate and the App Store Connect key are the keys to the app's signature and notarization.
  Rotate them if a machine or a token may have leaked; a rotated Developer ID certificate needs the new .p12 secret.
- A new Sparkle key breaks updates for every installed app: the apps carry the old public key. Do not replace
  `SPARKLE_ED_KEY` unless you also ship a build with a new `SUPublicEDKey`.
- Secret values are masked in logs, but do not echo them in workflow changes.

## Local release (fallback)

The release Mac can still run `apps/mac/scripts/release-app.sh <version>` with the keychain profile `bandito-notary`
and the Sparkle key in its login Keychain. Without `--appcast-out` it writes the appcast into the platform checkout
(`BANDITO_PLATFORM_DIR`, default `../platform`). The CI run is the normal path.
