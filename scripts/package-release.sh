#!/bin/sh
# Builds a signed universal candidate. Set NOTARY_PROFILE to notarize it.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
releaseTeam=${TEAM:?Set TEAM to the Developer ID team identifier}
signingIdentity=${SIGNING_IDENTITY:-Developer ID Application}
releaseDir=${RELEASE_DIR:-"${ROOT}/releases"}
derivedDir="${ROOT}/DerivedDataUniversal"
app="${derivedDir}/Build/Products/Release/LinkCursor.app"

xcodebuild -quiet -project "${ROOT}/LinkCursor.xcodeproj" -scheme LinkCursor \
    -configuration Release -derivedDataPath "$derivedDir" \
    -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$signingIdentity" DEVELOPMENT_TEAM="$releaseTeam" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp build

codesign --verify --deep --strict "$app"
for arch in arm64 x86_64; do
    lipo "$app/Contents/MacOS/LinkCursor" -verify_arch "$arch"
done
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
mkdir -p "$releaseDir"
candidate="$releaseDir/LinkCursor-${version}-macOS-universal-unnotarized.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$candidate"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$candidate" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose "$app"
    final="$releaseDir/LinkCursor-${version}-macOS-universal.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$final"
    shasum -a 256 "$final" > "$final.sha256"
    echo "Notarized release: $final"
else
    shasum -a 256 "$candidate" > "$candidate.sha256"
    echo "Signed candidate (not notarized): $candidate"
    echo 'Set NOTARY_PROFILE to an existing notarytool Keychain profile before public distribution.'
fi
