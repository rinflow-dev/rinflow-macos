#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Builds the Developer ID signed universal app from committed sources.
#
#   scripts/package-release.sh                                  signed only
#   NOTARY_PROFILE=rinflow-notary scripts/package-release.sh notarized too
#
# Only a notarized zip opens normally on other Macs. Other settings:
#   TEAM              overrides the project's DEVELOPMENT_TEAM
#   SIGNING_IDENTITY  defaults to "Developer ID Application"
#   RELEASE_DIR       defaults to releases/
#   ALLOW_DIRTY=1     builds uncommitted changes, for trying the script only
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE="${ROOT}/../rinflow-core"
signingIdentity=${SIGNING_IDENTITY:-Developer ID Application}
releaseDir=${RELEASE_DIR:-"${ROOT}/releases"}
derivedDir="${ROOT}/DerivedDataUniversal"
app="${derivedDir}/Build/Products/Release/Rinflow.app"

fail() {
    echo "error: $1" >&2
    exit 1
}

# A release that cannot be traced to commits cannot be reproduced. The app
# links the sibling Core, so its tree counts too.
for repo in "$ROOT" "$CORE"; do
    if [ -n "$(git -C "$repo" status --porcelain)" ] && [ -z "${ALLOW_DIRTY:-}" ]; then
        fail "$repo has uncommitted changes. Commit them first (ALLOW_DIRTY=1 only to try the script)."
    fi
done

# Always higher than the last release's, so testers can tell builds apart.
build=$(git -C "$ROOT" rev-list --count HEAD)

# shellcheck disable=SC2086 # the team setting is one word or none
xcodebuild -quiet -project "${ROOT}/Rinflow.xcodeproj" -scheme Rinflow \
    -configuration Release -derivedDataPath "$derivedDir" \
    -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$signingIdentity" ${TEAM:+DEVELOPMENT_TEAM="$TEAM"} \
    CURRENT_PROJECT_VERSION="$build" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp clean build

# What notarization requires, checked here so a mistake fails in seconds.
codesign --verify --deep --strict "$app"
for arch in arm64 x86_64; do
    lipo "$app/Contents/MacOS/Rinflow" -verify_arch "$arch"
done
signature=$(codesign -dvv --entitlements - "$app" 2>&1)
case "$signature" in
    *"Authority=Developer ID Application"*) ;;
    *) fail "not signed with a Developer ID Application certificate" ;;
esac
case "$signature" in
    *"(runtime)"*) ;;
    *) fail "hardened runtime is off" ;;
esac
case "$signature" in
    *"Timestamp="*) ;;
    *) fail "no secure timestamp" ;;
esac
case "$signature" in
    *get-task-allow*) fail "the debugging entitlement is present" ;;
esac

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
name="Rinflow-${version}-${build}-macOS-universal"
mkdir -p "$releaseDir"
candidate="$releaseDir/${name}-unnotarized.zip"
rm -f "$candidate" "$candidate.sha256"
ditto -c -k --sequesterRsrc --keepParent "$app" "$candidate"

if [ -z "${NOTARY_PROFILE:-}" ]; then
    shasum -a 256 "$candidate" > "$candidate.sha256"
    echo "Signed, not notarized: $candidate"
    echo 'Gatekeeper blocks this on other Macs. Set NOTARY_PROFILE to publish.'
    exit 0
fi

# notarytool can report a rejection without failing, so read the verdict.
result=$(xcrun notarytool submit "$candidate" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) \
    || fail "could not submit to the notary service: $result"
status=$(printf '%s' "$result" | plutil -extract status raw -o - -)
if [ "$status" != "Accepted" ]; then
    id=$(printf '%s' "$result" | plutil -extract id raw -o - -)
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "notarization ended as: $status"
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose "$app"
final="$releaseDir/${name}.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$final"
shasum -a 256 "$final" > "$final.sha256"
# Only the notarized zip stays, so the wrong one cannot be sent out.
rm -f "$candidate"
echo "Notarized release: $final"
