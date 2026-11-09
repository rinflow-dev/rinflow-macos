#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Builds the Developer ID signed app from committed sources, once for Apple
# silicon (arm64) and once for Intel (x64), each in a disk image to drag it
# into Applications from.
#
#   scripts/package-release.sh                                  signed only
#   NOTARY_PROFILE=rinflow-notary scripts/package-release.sh notarized too
#
# Only a notarized image opens normally on other Macs. Other settings:
#   TEAM              overrides the project's DEVELOPMENT_TEAM
#   SIGNING_IDENTITY  defaults to "Developer ID Application"
#   RELEASE_DIR       defaults to releases/
#   NOTARY_KEYCHAIN   the keychain holding NOTARY_PROFILE, if not the login one
#   SPARKLE_PRIVATE_KEY  the EdDSA key that signs updates, if not in the login
#                     keychain (Sparkle's generate_keys put it there)
#   ALLOW_DIRTY=1     builds uncommitted changes, for trying the script only
#
# A notarized build also writes the update feed of each architecture,
# appcast-arm64.xml and appcast-x64.xml, published with the release: the app
# reads it from the latest release (Rinflow/App/Updater.swift).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE="${ROOT}/../rinflow-core"
signingIdentity=${SIGNING_IDENTITY:-Developer ID Application}
releaseDir=${RELEASE_DIR:-"${ROOT}/releases"}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
    echo "error: $1" >&2
    exit 1
}

# Names the file only, so `shasum -c` works where it is downloaded.
checksum() {
    (cd "$releaseDir" && shasum -a 256 "${1##*/}" > "${1##*/}.sha256")
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
mkdir -p "$releaseDir"

# Builds $app for one architecture, and checks what notarization requires
# so a mistake fails in seconds.
build_app() {
    derivedDir="${ROOT}/DerivedDataRelease/$1"
    app="${derivedDir}/Build/Products/Release/Rinflow.app"
    # shellcheck disable=SC2086 # the team setting is one word or none
    xcodebuild -quiet -project "${ROOT}/Rinflow.xcodeproj" -scheme Rinflow \
        -configuration Release -derivedDataPath "$derivedDir" \
        -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO ARCHS="$1" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$signingIdentity" ${TEAM:+DEVELOPMENT_TEAM="$TEAM"} \
        CURRENT_PROJECT_VERSION="$build" \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp clean build

    sign_sparkle
    codesign --verify --deep --strict "$app"
    [ "$(lipo -archs "$app/Contents/MacOS/Rinflow")" = "$1" ] || fail "the $1 app holds other architectures"
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
    # The image is signed by whoever signed the app.
    identity=$(printf '%s\n' "$signature" | sed -n 's/^Authority=//p' | head -n 1)
}

# Xcode signs Sparkle.framework when it embeds it, but not the helpers
# inside, which stay ad hoc and fail notarization. Sign them inside out
# (Sparkle's documented order), then the framework and the app again, whose
# seals cover them.
sign_sparkle() {
    framework="$app/Contents/Frameworks/Sparkle.framework"
    for helper in Versions/B/XPCServices/Installer.xpc Versions/B/XPCServices/Downloader.xpc \
        Versions/B/Autoupdate Versions/B/Updater.app ""; do
        codesign --force --sign "$signingIdentity" --options runtime --timestamp \
            --preserve-metadata=entitlements "$framework/$helper"
    done
    codesign --force --sign "$signingIdentity" --options runtime --timestamp \
        --preserve-metadata=entitlements,requirements,flags "$app"
    for helper in "$framework" "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" \
        "$framework/Versions/B/XPCServices/Installer.xpc" "$framework/Versions/B/XPCServices/Downloader.xpc"; do
        case "$(codesign -dvv "$helper" 2>&1)" in
            *"Authority=Developer ID Application"*"Timestamp="*) ;;
            *) fail "${helper#"$app"/} is not signed with Developer ID and a timestamp" ;;
        esac
    done
}

# $1 from $app: the app and a link to Applications, the usual drag-to-install
# window.
image() {
    mkdir "$work/image"
    ditto "$app" "$work/image/Rinflow.app"
    ln -s /Applications "$work/image/Applications"
    rm -f "$1" "$1.sha256"
    hdiutil create -quiet -volname Rinflow -srcfolder "$work/image" -format ULFO "$1"
    rm -rf "$work/image"
    codesign --sign "$identity" --timestamp "$1"
}

# notarytool can report a rejection without failing, so read the verdict.
# shellcheck disable=SC2086 # the keychain setting is one word or none
notarize() {
    result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
        ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait --output-format json) \
        || fail "could not submit $1 to the notary service: $result"
    status=$(printf '%s' "$result" | plutil -extract status raw -o - -)
    if [ "$status" != "Accepted" ]; then
        id=$(printf '%s' "$result" | plutil -extract id raw -o - -)
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" \
            ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} >&2 || true
        fail "notarization of $1 ended as: $status"
    fi
}

# The app first, so it carries its own ticket once copied out of the image
# and opens offline; then the image that holds it.
publish() {
    ditto -c -k --keepParent "$app" "$work/Rinflow.zip"
    notarize "$work/Rinflow.zip"
    rm -f "$work/Rinflow.zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose "$app"

    image "$1"
    notarize "$1"
    xcrun stapler staple "$1"
    xcrun stapler validate "$1"
    spctl --assess --type open --context context:primary-signature --verbose "$1"
}

# The update feed of architecture $2 offering image $1, signed with the
# EdDSA key. Sparkle needs only the newest version in it.
feed() {
    feedImage=$1
    feedArch=$2
    feedFile="$releaseDir/appcast-$feedArch.xml"
    key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist" 2>/dev/null || true)
    [ -n "$key" ] || fail "no update key: set SPARKLE_PUBLIC_KEY in scripts/generate-xcodeproj.rb (docs/release-checklist.md)"
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
    releases=https://github.com/rinflow-dev/rinflow-macos/releases
    mkdir "$work/feed"
    cp "$feedImage" "$work/feed/"
    rm -f "$feedFile"
    set -- "${derivedDir}/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
        --download-url-prefix "$releases/download/v$version/" \
        --full-release-notes-url "$releases/tag/v$version" \
        -o "$feedFile" "$work/feed"
    if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
        printf '%s' "$SPARKLE_PRIVATE_KEY" | "$@" --ed-key-file -
    else
        "$@"
    fi
    rm -rf "$work/feed"
    grep -q 'sparkle:edSignature=' "$feedFile" || fail "$feedFile is not signed"
}

# Xcode's architecture, and the name downloads use, as on Windows.
for arch in arm64:arm64 x86_64:x64; do
    build_app "${arch%%:*}"
    name="$releaseDir/Rinflow-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$app/Contents/Info.plist")-${build}-macOS-${arch#*:}"
    if [ -z "${NOTARY_PROFILE:-}" ]; then
        image "$name-unnotarized.dmg"
        checksum "$name-unnotarized.dmg"
        echo "Signed, not notarized: $name-unnotarized.dmg"
        continue
    fi
    publish "$name.dmg"
    checksum "$name.dmg"
    feed "$name.dmg" "${arch#*:}"
    # Only the notarized image stays, so the wrong one cannot be sent out.
    rm -f "$name-unnotarized.dmg" "$name-unnotarized.dmg.sha256"
    echo "Notarized release: $name.dmg"
done

if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo 'Gatekeeper blocks these on other Macs. Set NOTARY_PROFILE to publish.'
fi
