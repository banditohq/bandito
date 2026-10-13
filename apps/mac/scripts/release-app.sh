#!/usr/bin/env bash
# Release the Mac app: Release build signed with Developer ID, notarized and stapled, Bandito-<version>.zip and .dmg,
# the Sparkle signature of the zip, and an item in the appcast of the platform checkout.
# It uploads nothing and deploys nothing: the printed next steps are for the owner.
#
#   apps/mac/scripts/release-app.sh <version> [--dry-run] [--appcast-out <file>]
#   apps/mac/scripts/release-app.sh <version> --stage compile --arch arm64|x86_64
#   apps/mac/scripts/release-app.sh <version> --stage assemble --arm64-app <Bandito.app> --x86-app <Bandito.app>
#   apps/mac/scripts/release-app.sh <version> --stage appcast --appcast-out <file>
#
# <version> is X.Y.Z, or X.Y.Z-beta.N for the beta channel. The build number is the commit count of HEAD.
# The disk image is built by make-dmg.sh with dmgbuild: python3 -m pip install --user -r apps/mac/scripts/dmg-requirements.txt
# --dry-run does everything up to Apple's notary service: no submission, no stapling, no Gatekeeper check.
#
# --stage splits the release for CI (release-app.yml). Without it (`all`, the release Mac) one run does everything:
#   compile   one architecture (--arch), signed ad hoc, into build/release/compiled-<arch>/Bandito.app. Needs no
#             certificate and no key: the two architectures are built at the same time on two runners.
#   assemble  joins the two compiled apps into one universal app (lipo, file by file; the two bundles must hold the
#             same files), signs it with Developer ID, notarizes, staples, zip and dmg in build/release/.
#             Needs the signing identity and the notary key, never the Sparkle key.
#   appcast   takes the finished zip from build/release/: the Sparkle signature and the appcast item. Needs the
#             Sparkle key and the platform checkout, never the signing identity.
# --appcast-out writes the updated appcast to <file> instead of the platform checkout (CI). The existing items are
# still read from the platform checkout's public/appcast.xml, so that checkout must hold the current feed.
#
# Environment:
#   BANDITO_PLATFORM_DIR   platform checkout: public/appcast.xml is read (and written unless --appcast-out is given)
#                          (default: ../platform next to this repo)
#   BANDITO_DERIVED_DATA   Xcode derived data (default: ~/.cache/bandito-xcode/release, off the repo disk)
#   CARGO_TARGET_DIR       Rust target of the daemon build (default: ~/.cache/bandito-target-app)
#   SPARKLE_BIN            Sparkle's bin directory with sign_update (default: ~/.cache/sparkle/2.10.0/extracted/bin)
#   SPARKLE_KEY_FILE       EdDSA private key file for sign_update --ed-key-file (default: the key in the login Keychain)
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#                          App Store Connect API key for notarytool (CI). All three or none; none means the
#                          keychain profile bandito-notary.
set -euo pipefail

TEAM_ID="74Q24ZMD7A"
IDENTITY="Developer ID Application: Nikita Terekhin (74Q24ZMD7A)"
NOTARY_PROFILE="bandito-notary"
MIN_SYSTEM="14.0"
REPO_SLUG="banditohq/bandito"

usage() {
    echo "usage: $0 <version> [--dry-run] [--stage all|compile|assemble|appcast] [--arch arm64|x86_64]" >&2
    echo "          [--arm64-app <Bandito.app>] [--x86-app <Bandito.app>] [--appcast-out <file>]" >&2
    exit 2
}

[ $# -ge 1 ] || usage
version="$1"
shift
dry_run=0
appcast_out=""
stage="all"
arch=""
arm_app=""
x86_app=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --stage)
            [ $# -ge 2 ] || usage
            case "$2" in all|compile|assemble|appcast) stage="$2" ;; *) usage ;; esac
            shift
            ;;
        --arch)
            [ $# -ge 2 ] || usage
            case "$2" in arm64|x86_64) arch="$2" ;; *) usage ;; esac
            shift
            ;;
        --arm64-app) [ $# -ge 2 ] || usage; arm_app="$2"; shift ;;
        --x86-app) [ $# -ge 2 ] || usage; x86_app="$2"; shift ;;
        --appcast-out)
            [ $# -ge 2 ] || usage
            mkdir -p "$(dirname "$2")"
            appcast_out="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
            shift
            ;;
        *) usage ;;
    esac
    shift
done
if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$'; then
    echo "error: version must look like 0.1.0 or 0.2.0-beta.1 (got '$version')" >&2
    exit 2
fi
[ "$stage" != compile ] || [ -n "$arch" ] || { echo "error: --stage compile needs --arch" >&2; exit 2; }
if [ "$stage" = assemble ]; then
    [ -d "$arm_app" ] && [ -d "$x86_app" ] || { echo "error: --stage assemble needs --arm64-app and --x86-app (the two compiled Bandito.app folders)" >&2; exit 2; }
    arm_app="$(cd "$arm_app" && pwd)"
    x86_app="$(cd "$x86_app" && pwd)"
fi

here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
derived="${BANDITO_DERIVED_DATA:-$HOME/.cache/bandito-xcode/release}"
release="$here/build/release"
work="$here/build/work"
platform="${BANDITO_PLATFORM_DIR:-$repo/../platform}"
sparkle_bin="${SPARKLE_BIN:-$HOME/.cache/sparkle/2.10.0/extracted/bin}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/bandito-target-app}"
app_name="Bandito.app"
zip_name="Bandito-$version.zip"
zip_path="$release/$zip_name"
dmg_name="Bandito-$version.dmg"
dmg_path="$release/$dmg_name"

# Which parts this run does.
do_compile=0 # xcodebuild (one architecture, or both at once for `all`)
do_merge=0   # join the two compiled apps
do_finish=0  # sign, notarize, staple, zip, dmg
do_appcast=0 # Sparkle signature and appcast item
case "$stage" in
    all) do_compile=1; do_finish=1; do_appcast=1 ;;
    compile) do_compile=1 ;;
    assemble) do_merge=1; do_finish=1 ;;
    appcast) do_appcast=1 ;;
esac

started="$SECONDS"
step() { printf '\n==> [%dm%02ds] %s\n' $(((SECONDS - started) / 60)) $(((SECONDS - started) % 60)) "$*"; }

# --- preflight -------------------------------------------------------------------------------------------------------
need_tools() {
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found" >&2; exit 1; }
    done
}
if [ "$do_compile" -eq 1 ]; then
    need_tools xcodegen xcodebuild python3 git
    # A release is built from committed code. project.yml (the version) and Config/Info.plist (generated) may differ.
    dirty="$(git -C "$repo" status --porcelain | grep -v -e '^ M apps/mac/project.yml$' -e '^ M apps/mac/Config/Info.plist$' || true)"
    if [ -n "$dirty" ]; then
        echo "error: commit the changes first; the release must be built from a clean tree:" >&2
        echo "$dirty" >&2
        exit 1
    fi
fi
if [ "$do_finish" -eq 1 ]; then
    need_tools codesign ditto hdiutil xcrun python3 lipo plutil
    python3 -c 'import dmgbuild' >/dev/null 2>&1 || {
        echo "error: dmgbuild not installed: python3 -m pip install --user -r $here/scripts/dmg-requirements.txt" >&2
        exit 1
    }
    security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\"" || {
        echo "error: signing identity not in the Keychain: $IDENTITY" >&2
        exit 1
    }
    # Notary credentials: an App Store Connect API key (CI) or the keychain profile (the release Mac). Never a mix.
    if [ -n "${NOTARY_KEY_PATH:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER_ID:-}" ]; then
        for var in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
            [ -n "${!var:-}" ] || { echo "error: $var is required when the other notary API key variables are set" >&2; exit 1; }
        done
        [ -f "$NOTARY_KEY_PATH" ] || { echo "error: NOTARY_KEY_PATH is not a file" >&2; exit 1; }
        notary_auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    else
        notary_auth=(--keychain-profile "$NOTARY_PROFILE")
    fi
fi
if [ "$do_appcast" -eq 1 ]; then
    need_tools python3 xmllint unzip plutil shasum
    [ -x "$sparkle_bin/sign_update" ] || {
        echo "error: $sparkle_bin/sign_update not found; unpack Sparkle 2.10.0 there (see docs/ARCHITECTURE.md#mac-app-updates)" >&2
        exit 1
    }
    if [ -n "${SPARKLE_KEY_FILE:-}" ] && [ ! -f "$SPARKLE_KEY_FILE" ]; then
        echo "error: SPARKLE_KEY_FILE is not a file" >&2
        exit 1
    fi
    [ -d "$platform/public" ] || { echo "error: no public/ in platform checkout: $platform (set BANDITO_PLATFORM_DIR)" >&2; exit 1; }
fi

mkdir -p "$release" "$work"
# plist_value <Info.plist> <key>
plist_value() { plutil -extract "$2" raw -o - "$1"; }
if [ "$do_compile" -eq 1 ]; then
    # The build number (CFBundleVersion, which Sparkle compares) is the commit count of HEAD plus 1000. Releases are squashed
    # into main, so a build made from a release branch can count more commits than main does later (0.1.5 was 270, main had
    # 231 at 0.1.8); the offset keeps every build from main above any of those, so an update is always offered.
    build_number="$(( $(git -C "$repo" rev-list --count HEAD) + 1000 ))"
elif [ "$do_merge" -eq 1 ]; then
    # The build number is the one inside the compiled apps; both must carry this version and the same build.
    for compiled in "$arm_app" "$x86_app"; do
        [ "$(plist_value "$compiled/Contents/Info.plist" CFBundleShortVersionString)" = "$version" ] \
            || { echo "error: $compiled is not version $version" >&2; exit 1; }
    done
    build_number="$(plist_value "$arm_app/Contents/Info.plist" CFBundleVersion)"
    [ "$(plist_value "$x86_app/Contents/Info.plist" CFBundleVersion)" = "$build_number" ] \
        || { echo "error: the two compiled apps have different build numbers" >&2; exit 1; }
else
    # Stage appcast: the zip from the assemble stage holds the version and the build number.
    [ -f "$zip_path" ] || { echo "error: no $zip_path: run the assemble stage first" >&2; exit 1; }
    unzip -p "$zip_path" "$app_name/Contents/Info.plist" > "$work/zip-info.plist" \
        || { echo "error: $zip_name has no $app_name/Contents/Info.plist" >&2; exit 1; }
    [ "$(plist_value "$work/zip-info.plist" CFBundleShortVersionString)" = "$version" ] \
        || { echo "error: $zip_name is not version $version" >&2; exit 1; }
    build_number="$(plist_value "$work/zip-info.plist" CFBundleVersion)"
fi
printf '%s\n' "$build_number" | grep -Eq '^[0-9]+$' || { echo "error: bad build number '$build_number'" >&2; exit 1; }
echo "version $version, build $build_number, stage $stage, dry run: $dry_run"

if [ "$do_compile" -eq 1 ]; then
    # --- (a) version in project.yml --------------------------------------------------------------------------------------
    step "Set the version in project.yml"
    python3 - "$here/project.yml" "$version" "$build_number" <<'PY'
import re
import sys

path, version, build = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
text, marketing = re.subn(r"(?m)^(\s*MARKETING_VERSION:\s*).*$", lambda m: m.group(1) + version, text)
text, project = re.subn(r"(?m)^(\s*CURRENT_PROJECT_VERSION:\s*).*$", lambda m: m.group(1) + build, text)
if marketing != 1 or project != 1:
    sys.exit("error: project.yml must have one MARKETING_VERSION and one CURRENT_PROJECT_VERSION")
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY


    # --- (b) build -------------------------------------------------------------------------------------------------------
    if [ "$stage" = compile ]; then
        # One architecture, signed ad hoc with the app's entitlements (the assemble stage re-signs everything with
        # Developer ID and reads those entitlements from this build). No certificate is needed here.
        xcode_archs="$arch"
        sign_settings=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
        app_out="$release/compiled-$arch"
    else
        xcode_archs="arm64 x86_64"
        sign_settings=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" ENABLE_HARDENED_RUNTIME=YES
            CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp)
        app_out="$release"
    fi
    step "Generate the project and build Release ($xcode_archs)"
    (cd "$here" && xcodegen generate --quiet)
    # BUILD_DIR and OBJROOT are passed as build.sh does: a custom build location in Xcode's settings would otherwise
    # win over -derivedDataPath and put the product in the global DerivedData.
    xcodebuild -project "$here/Bandito.xcodeproj" -scheme Bandito -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$derived" -skipPackagePluginValidation \
        "BUILD_DIR=$derived/Build/Products" "OBJROOT=$derived/Build/Intermediates.noindex" \
        "${sign_settings[@]}" ARCHS="$xcode_archs" ONLY_ACTIVE_ARCH=NO \
        -quiet build > "$work/xcodebuild.log" 2>&1 || {
        echo "error: xcodebuild failed, the tail of $work/xcodebuild.log:" >&2
        tail -n 40 "$work/xcodebuild.log" >&2
        exit 1
    }
    built="$derived/Build/Products/Release/$app_name"
    [ -d "$built" ] || { echo "error: no product at $built" >&2; exit 1; }
    mkdir -p "$app_out"
    rm -rf "${app_out:?}/$app_name"
    ditto "$built" "$app_out/$app_name"
    if [ "$stage" = compile ]; then
        step "Check that the compiled app is $arch only"
        while IFS= read -r -d '' file; do
            case "$(file -b "$file")" in *Mach-O*) ;; *) continue ;; esac
            # A prebuilt framework (Sparkle) may be universal already; what matters is that the slice is there.
            case " $(lipo -archs "$file") " in *" $arch "*) ;; *) echo "error: ${file#"$app_out/$app_name"/} has no $arch slice" >&2; exit 1 ;; esac
        done < <(find "$app_out/$app_name" -type f -print0)
        echo "compiled $app_out/$app_name"
    fi
fi

if [ "$do_merge" -eq 1 ]; then
    # --- (b2) join the two compiled apps ---------------------------------------------------------------------------------
    # slice <Mach-O file> <arch> <out>: the one-architecture file of that arch (a prebuilt framework may be universal already).
    slice() {
        local archs
        archs="$(lipo -archs "$1")"
        if [ "$archs" = "$2" ]; then
            cp "$1" "$3"
        else
            case " $archs " in
                *" $2 "*) lipo -thin "$2" "$1" -output "$3" ;;
                *) echo "error: $1 has no $2 slice (has: $archs)" >&2; return 1 ;;
            esac
        fi
    }
    step "Join the arm64 and x86_64 apps into one universal app"
    app="$release/$app_name"
    rm -rf "${app:?}"
    ditto "$arm_app" "$app"
    # The code signature seals differ between the two builds; everything else must be there in both.
    list_files() { (cd "$1" && find . \( -type f -o -type l \) ! -path '*/_CodeSignature/*' | LC_ALL=C sort); }
    list_files "$arm_app" > "$work/files-arm64.txt"
    list_files "$x86_app" > "$work/files-x86_64.txt"
    if ! diff -u "$work/files-arm64.txt" "$work/files-x86_64.txt" > "$work/files.diff"; then
        echo "error: the two builds hold different files:" >&2
        cat "$work/files.diff" >&2
        exit 1
    fi
    merge_failures=0
    merged=0
    copied=0
    while IFS= read -r rel; do
        a="$arm_app/$rel"
        x="$x86_app/$rel"
        if [ -L "$a" ]; then
            [ "$(readlink "$a")" = "$(readlink "$x")" ] || { echo "error: symlink $rel differs between the builds" >&2; merge_failures=$((merge_failures + 1)); }
            continue
        fi
        if case "$(file -b "$a")" in *Mach-O*) true ;; *) false ;; esac; then
            slice "$a" arm64 "$work/slice-arm64" && slice "$x" x86_64 "$work/slice-x86_64" \
                && lipo -create "$work/slice-arm64" "$work/slice-x86_64" -output "$app/$rel" \
                && chmod "$(stat -f %Lp "$a")" "$app/$rel" || { echo "error: cannot join $rel" >&2; merge_failures=$((merge_failures + 1)); }
            merged=$((merged + 1))
        else
            if cmp -s "$a" "$x"; then copied=$((copied + 1)); else echo "error: $rel differs between the builds (not a binary)" >&2; merge_failures=$((merge_failures + 1)); fi
        fi
    done < "$work/files-arm64.txt"
    rm -f "$work/slice-arm64" "$work/slice-x86_64"
    [ "$merge_failures" -eq 0 ] || { echo "error: $merge_failures problem(s) joining the builds" >&2; exit 1; }
    echo "joined $merged binaries; $copied other files are identical in both builds"
fi

if [ "$do_finish" -eq 1 ]; then app="$release/$app_name"; fi

if [ "$do_finish" -eq 1 ]; then
    ent_root="$app"
    if [ "$stage" = assemble ]; then ent_root="$arm_app"; fi
    # The release is universal (Apple Silicon and Intel). Every Mach-O file of the bundle must carry both architectures:
    # the app, the daemon in Helpers, and the nested code such as Sparkle's framework and its XPC services.
    step "Check that every binary of the app is universal (arm64 and x86_64)"
    universal_failures=0
    checked=0
    while IFS= read -r -d '' file; do
        kind="$(file -b "$file")"
        case "$kind" in *Mach-O*) ;; *) continue ;; esac
        checked=$((checked + 1))
        archs="$(lipo -archs "$file" 2>/dev/null || true)"
        archs=" $archs "
        for arch in arm64 x86_64; do
            case "$archs" in
                *" $arch "*) ;;
                *) echo "error: ${file#"$app"/} has no $arch slice (has:${archs% })" >&2; universal_failures=$((universal_failures + 1)) ;;
            esac
        done
    done < <(find "$app" -type f -print0)
    [ "$checked" -gt 0 ] || { echo "error: no Mach-O binaries found in $app" >&2; exit 1; }
    [ "$universal_failures" -eq 0 ] || {
        echo "error: $universal_failures architecture slice(s) missing; the release must be arm64 and x86_64 (check ARCHS and the daemon build phase in apps/mac/project.yml)" >&2
        exit 1
    }
    for named in "Contents/MacOS/Bandito" "Contents/Helpers/bandito" \
        "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"; do
        [ -f "$app/$named" ] || { echo "error: expected binary missing: $named" >&2; exit 1; }
        echo "$named: $(lipo -archs "$app/$named")"
    done
    echo "checked $checked Mach-O files: all universal"

    # Signs one nested code item with the release identity, keeping its own entitlements. get-task-allow is a debug
    # entitlement: notarization refuses it, so it is dropped if a build still carries it. No --deep: each item is signed
    # on its own, inside out.
    # The entitlements are read from the same item of $ent_root: the app itself, or (assemble) the arm64 build, whose
    # signature is intact; the joined binaries have lost theirs.
    sign_item() {
        local path="$1" ent_path
        ent_path="${path/#"$app"/"$ent_root"}"
        if codesign -d --entitlements :- "$ent_path" > "$work/entitlements.plist" 2>/dev/null && [ -s "$work/entitlements.plist" ]; then
            plutil -remove com.apple.security.get-task-allow "$work/entitlements.plist" 2>/dev/null || true
            codesign --force --options runtime --timestamp --entitlements "$work/entitlements.plist" --sign "$IDENTITY" "$path"
        else
            codesign --force --options runtime --timestamp --sign "$IDENTITY" "$path"
        fi
    }

    step "Sign Sparkle's nested code, inside out, then the app"
    sparkle="$app/Contents/Frameworks/Sparkle.framework"
    for item in \
        "$sparkle/Versions/B/XPCServices/Installer.xpc" \
        "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
        "$sparkle/Versions/B/Autoupdate" \
        "$sparkle/Versions/B/Updater.app" \
        "$sparkle"; do
        [ -e "$item" ] || { echo "error: expected Sparkle item missing: $item" >&2; exit 1; }
        sign_item "$item"
    done
    sign_item "$app"
    if codesign -d --entitlements :- "$app" 2>/dev/null | grep -q "get-task-allow"; then
        echo "error: the app still carries com.apple.security.get-task-allow; notarization would refuse it" >&2
        exit 1
    fi
    codesign --verify --deep --strict "$app"
    codesign -dvv "$app" 2>&1 | grep -E '^(Authority=Developer ID|TeamIdentifier|CodeDirectory)' || true
    # --- (c) first archive, for notarization ------------------------------------------------------------------------------
    step "Zip the app for notarization"
    rm -f "$zip_path"
    (cd "$release" && ditto -c -k --keepParent "$app_name" "$zip_name")

    # retry <command...>: runs it up to 5 times for Apple network failures ("The network connection was lost" from stapler,
    # notarytool timeouts); waits 15, 30, 60 and 120 seconds between tries and prints why each try failed.
    retry() {
        local attempt=1 delay err
        local delays=(15 30 60 120)
        err="$work/retry-err.txt"
        while :; do
            if "$@" 2> "$err"; then
                cat "$err" >&2
                return 0
            fi
            echo "attempt $attempt/5 failed: $* -> $(tr '\n' ' ' < "$err")" >&2
            if [ "$attempt" -ge 5 ]; then
                echo "error: giving up after 5 attempts: $*" >&2
                return 1
            fi
            delay="${delays[$((attempt - 1))]}"
            echo "retrying in ${delay}s" >&2
            sleep "$delay"
            attempt=$((attempt + 1))
        done
    }

    # notarize <file>: submits it to Apple and waits. Anything but Accepted fails, with Apple's log.
    notarize() {
        local file="$1" out status id attempt=1 err delay
        local delays=(15 30 60 120)
        out="$work/notary-$(basename "$file").json"
        err="$work/notary-err.txt"
        echo "submitting $(basename "$file") to the notary service (this can take a few minutes)"
        while :; do
            : > "$out"
            xcrun notarytool submit "$file" "${notary_auth[@]}" --wait --output-format json > "$out" 2> "$err" || true
            status="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' < "$out" 2>/dev/null || true)"
            id="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' < "$out" 2>/dev/null || true)"
            # A verdict from Apple (Accepted, Invalid, Rejected) is final; no status at all means the call itself failed.
            [ -z "$status" ] || break
            echo "attempt $attempt/5: notarytool gave no verdict: $(tr '\n' ' ' < "$err")" >&2
            if [ "$attempt" -ge 5 ]; then break; fi
            delay="${delays[$((attempt - 1))]}"
            echo "retrying in ${delay}s" >&2
            sleep "$delay"
            attempt=$((attempt + 1))
        done
        if [ "$status" != "Accepted" ]; then
            echo "error: notarization of $(basename "$file") ended with status '${status:-unknown}' (submission ${id:-none})" >&2
            [ -n "$id" ] && xcrun notarytool log "$id" "${notary_auth[@]}" >&2 || true
            exit 1
        fi
        echo "notarized $(basename "$file"): Accepted (submission $id)"
    }

    # --- (d) notarize, staple, final archives -----------------------------------------------------------------------------
    if [ "$dry_run" -eq 1 ]; then
        step "Dry run: skipping notarization, stapling and the Gatekeeper check"
    else
        step "Notarize the app"
        notarize "$zip_path"
        retry xcrun stapler staple "$app"
        retry xcrun stapler validate "$app"
    fi

    step "Final zip (with the staple inside the app)"
    rm -f "$zip_path"
    (cd "$release" && ditto -c -k --keepParent "$app_name" "$zip_name")

    step "Disk image"
    rm -f "$dmg_path"
    "$here/scripts/make-dmg.sh" "$app" "$dmg_path"
    codesign --force --timestamp --sign "$IDENTITY" "$dmg_path"
    if [ "$dry_run" -eq 0 ]; then
        notarize "$dmg_path"
        retry xcrun stapler staple "$dmg_path"
        retry xcrun stapler validate "$dmg_path"
        step "Gatekeeper check"
        spctl_out="$(spctl -a -vvv -t exec "$app" 2>&1 || true)"
        echo "$spctl_out"
        if ! { grep -Fq "accepted" <<< "$spctl_out" && grep -Fq "source=Notarized Developer ID" <<< "$spctl_out"; }; then
            echo "error: Gatekeeper does not accept the app as Notarized Developer ID" >&2
            exit 1
        fi
    fi
fi

if [ "$do_appcast" -eq 1 ]; then
    # --- (e) Sparkle signature of the final zip ---------------------------------------------------------------------------
    step "Sparkle signature of $zip_name"
    if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
        sig_line="$("$sparkle_bin/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$zip_path")"
    else
        sig_line="$("$sparkle_bin/sign_update" "$zip_path")"
    fi
    signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$sig_line")"
    length="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<< "$sig_line")"
    [ -n "$signature" ] && [ -n "$length" ] || { echo "error: sign_update printed no signature or length" >&2; exit 1; }
    echo "length $length, signature $(printf '%s' "$signature" | cut -c1-12)…"

    # --- (f) appcast item -------------------------------------------------------------------------------------------------
    appcast_base="$platform/public/appcast.xml"
    appcast="${appcast_out:-$appcast_base}"
    url="https://github.com/$REPO_SLUG/releases/download/v$version/$zip_name"
    step "Add the item to $appcast"
    python3 - "$appcast_base" "$appcast" "$version" "$build_number" "$length" "$signature" "$url" "$MIN_SYSTEM" <<'PY'
import email.utils
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

path, out, version, build, length, signature, url, min_system = sys.argv[1:9]
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
EMPTY_FEED = f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="{SPARKLE_NS}" version="2.0">
  <channel>
    <title>Bandito</title>
    <link>https://bandito.dev/</link>
    <description>Bandito app updates</description>
    <language>en</language>
  </channel>
</rss>
"""
channel_line = "      <sparkle:channel>beta</sparkle:channel>\n" if "-beta" in version else ""
item = f"""    <item>
      <title>Bandito {version}</title>
      <pubDate>{email.utils.format_datetime(datetime.now(timezone.utc))}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>
{channel_line}      <enclosure url="{url}" sparkle:edSignature="{signature}" length="{length}" type="application/octet-stream"/>
    </item>
"""

text = EMPTY_FEED
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
# A re-run for the same version replaces its item; the other items stay as they are.
marker = f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
for found in list(re.finditer(r"[ \t]*<item>.*?</item>[ \t]*\n?", text, re.S)):
    if marker in found.group(0):
        text = text.replace(found.group(0), "", 1)
        break
# The newest item goes first, above the older ones.
first = re.search(r"^[ \t]*<item>", text, re.M)
if first:
    text = text[: first.start()] + item + text[first.start():]
else:
    closing = re.search(r"^[ \t]*</channel>", text, re.M)
    if not closing:
        sys.exit("error: appcast has no <channel>")
    text = text[: closing.start()] + item + text[closing.start():]

# Refuse to write anything that is not a well-formed feed with exactly one item for this version.
root = ET.fromstring(text)
if root.tag != "rss":
    sys.exit("error: appcast root is not <rss>")
versions = [el.text for el in root.iter(f"{{{SPARKLE_NS}}}shortVersionString")]
if versions.count(version) != 1:
    sys.exit(f"error: expected one item for {version}, found {versions.count(version)}")
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(text)
os.replace(tmp, out)
print(f"appcast: {len(versions)} item(s), {version} on top")
PY
    xmllint --noout "$appcast"
fi

# --- (g) summary and next steps ---------------------------------------------------------------------------------------
step "Done"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
case "$stage" in
    compile) exit 0 ;;
esac
if [ "$do_finish" -eq 1 ]; then
    echo "app      $app"
    echo "zip      $zip_path ($(sha "$zip_path"))"
    echo "dmg      $dmg_path ($(sha "$dmg_path"))"
fi
if [ "$do_appcast" -eq 1 ]; then
    if [ -n "$appcast_out" ]; then
        echo "appcast  $appcast (written to --appcast-out; the platform checkout is untouched)"
    else
        echo "appcast  $appcast (uncommitted)"
    fi
fi
[ "$stage" = all ] || exit 0
echo
echo "Not done by this script:"
if [ "$dry_run" -eq 1 ]; then
    echo "  - notarization (dry run): repeat without --dry-run before publishing"
fi
echo "  - commit apps/mac/project.yml and apps/mac/Config/Info.plist on the app branch"
echo "  - upload the release:  gh release upload v$version $zip_path $dmg_path --repo $REPO_SLUG"
# The app installs the daemon of its own version on servers: without the server release, "add a server" fails.
if ! gh release view "v$version" --repo "$REPO_SLUG" --json assets -q '.assets[].name' 2>/dev/null \
    | grep -q '^bandito-x86_64-unknown-linux-gnu.tar.gz$'; then
    echo
    echo "WARNING: release v$version has no server binaries. Servers cannot install $version until the GitHub"
    echo "         release v$version is published (the release workflow builds and signs them). Do not ship the"
    echo "         app before that."
fi
if [ -z "$appcast_out" ]; then
    echo "  - commit public/appcast.xml on the platform appcast branch; deploying the site is a separate decision"
fi

