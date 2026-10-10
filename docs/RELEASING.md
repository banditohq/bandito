# Releasing

A release has two parts that must match by version: the **server** (the `bandito` daemon binaries and `install.sh`)
and the **Mac app** (Bandito.app, zip and dmg, and the Sparkle appcast item). The app needs the server release of the
same version: without it, "Add a server" fails.

Both parts are built by GitHub Actions. Nobody builds a release on a laptop.

| Step | What | Where |
|---|---|---|
| 1 | Pick the version: `X.Y.Z` (stable) or `X.Y.Z-beta.N` (beta) | — |
| 2 | Tag the release commit `v<version>` | release-please or by hand |
| 3 | Server release: binaries, `install.sh`, `SHA256SUMS` and its signature | `release.yml` |
| 4 | Mac app: build, sign, notarize, staple, zip, dmg, Sparkle signature | `release-app.yml` |
| 5 | Approve the run in the `stable` environment (stable only) | GitHub Actions UI |
| 6 | Review and merge the appcast PR in `banditohq/platform` | platform repo |

## 1. Version and tag

- Versions are `X.Y.Z` or `X.Y.Z-beta.N`. The beta channel takes beta versions only; the stable channel takes
  versions without a suffix. `release-app.yml` refuses a mismatch.
- The tag is `v<version>` and sits on the release commit. release-please creates the tag and the GitHub release when
  its release PR is merged. To tag by hand:

  ```sh
  git tag -a v0.1.6 -m "Bandito 0.1.6" <commit>
  git push origin v0.1.6
  ```

- The app's build number is the commit count of the tagged commit (`git rev-list --count HEAD`). The tag must be
  checked out with full history; the workflow does this.

## 2. Server release (`release.yml`)

`release.yml` runs when a GitHub release is published. It builds `bandito` for Linux (x86_64, aarch64) and macOS
(x86_64, aarch64), uploads the tarballs, `install.sh`, `SHA256SUMS` and `SHA256SUMS.sig` to the release.

GitHub does not start workflows from events made with the `GITHUB_TOKEN`, so a release created by release-please may
not start it. Then start it by hand: Actions → `release` → Run workflow → tag `v<version>`.

Wait until `SHA256SUMS.sig` is on the release before starting the app release.

## 3. Mac app (`release-app.yml`)

Actions → `release-app` → Run workflow. Inputs:

- `version`: `X.Y.Z` or `X.Y.Z-beta.N`. The tag `v<version>` must exist.
- `channel`: `stable` or `beta`. It selects the environment of the run (`stable` or `beta`).

Dispatch it from the default branch: the workflow file is read from the branch you run it on.

Entitlements: `apps/mac/Config/Bandito.entitlements` (`audio-input`, for dictation) comes from `project.yml`; `release-app.sh` re-signs with the entitlements of the built app, so it is kept.

The single job (macOS 15 runner) does this:

1. Checks the inputs, that the tag exists, that the release is published and has the server assets, and that the
   secrets are set. It stops with a message if any is missing.
2. Checks out the tag with full history.
3. Installs XcodeGen and Rust, and Sparkle 2.10.0 from the official release (SHA-256 checked).
4. Gets the base appcast: from the `banditohq/platform` checkout when `PLATFORM_TOKEN` is set, otherwise from
   `https://bandito.dev/appcast.xml` (no PR is opened then).
5. Imports the Developer ID certificate into a temporary keychain with a random password, and writes the App Store
   Connect key and the Sparkle key to temporary files.
6. Runs `apps/mac/scripts/release-app.sh <version> --appcast-out <file>`: Release build, Developer ID signing with the
   hardened runtime, notarization with the API key, staple, dmg, Sparkle signature of the zip.
7. Uploads `Bandito-<version>.zip` and `Bandito-<version>.dmg` to the release `v<version>` (clobbering older files).
8. Uploads the new `appcast.xml` as a run artifact `appcast-<version>`.
9. If `PLATFORM_TOKEN` is set, pushes branch `appcast-<version>` to `banditohq/platform` with the new item and opens a
   PR against its default branch. It never pushes to `main`.
10. Deletes the temporary keychain and key files (always, even on failure).

## 4. Approval (stable)

The `stable` environment must have the owner as a required reviewer (set in the repository settings, Environments).
A stable run then waits for approval in the run page (Review deployments). The `beta` environment has no approval
gate. Only users with write access can start a run.

## 5. Appcast

Merge the `appcast-<version>` PR in `banditohq/platform` once the release is checked. The site serves
`public/appcast.xml` at `https://bandito.dev/appcast.xml`; deploying the site is a separate step in that repo.

Check the release before merging: download the zip, then `spctl -a -vvv -t exec Bandito.app` must print
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
| `PLATFORM_TOKEN` | release-app (optional) | Token that can push a branch and open a PR in `banditohq/platform` | A fine-grained personal access token limited to `banditohq/platform`: Contents read and write, Pull requests read and write. Without it the run still produces the appcast as an artifact, and no PR is opened. |
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
