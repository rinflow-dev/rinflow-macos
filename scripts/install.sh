#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Downloads the latest Rinflow disk image for this Mac and installs it.
#
#   curl -fsSL https://raw.githubusercontent.com/rinflow-dev/rinflow-macos/main/scripts/install.sh | sh
#
# It finds out whether this Mac has an Apple silicon (arm64) or an Intel (x64)
# processor, downloads the matching disk image from the latest GitHub release,
# checks its SHA-256 against the value GitHub publishes for it, and copies
# Rinflow.app into /Applications. The app is signed and notarized.
set -eu

repo=rinflow-dev/rinflow-macos

fail() {
    echo "error: $1" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] || fail 'this is for macOS.'
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "Rinflow needs macOS 14 or later (this is $(sw_vers -productVersion))."

# The Mac's processor, not the one this shell runs as: under Rosetta,
# `uname -m` says x86_64 on an Apple silicon Mac, and this setting stays 1.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
    arch=arm64
else
    arch=x64
fi
echo "This Mac: $arch"

if pgrep -x Rinflow > /dev/null; then
    fail 'Rinflow is running. Quit it, then run this again.'
fi

json=$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$repo/releases/latest") \
    || fail 'could not read the latest release from GitHub.'
tag=$(printf '%s' "$json" | plutil -extract tag_name raw -o - -)

# The release's files, one per processor: Rinflow-<version>-<build>-macOS-<arch>.dmg
url= digest=
i=0
while name=$(printf '%s' "$json" | plutil -extract "assets.$i.name" raw -o - - 2> /dev/null); do
    case "$name" in
        *-macOS-"$arch".dmg)
            url=$(printf '%s' "$json" | plutil -extract "assets.$i.browser_download_url" raw -o - -)
            digest=$(printf '%s' "$json" | plutil -extract "assets.$i.digest" raw -o - - 2> /dev/null || true)
            break
            ;;
    esac
    i=$((i + 1))
done
[ -n "$url" ] || fail "release $tag has no disk image for $arch."

work=$(mktemp -d)
mounted=
cleanup() {
    [ -z "$mounted" ] || hdiutil detach -quiet "$mounted" 2> /dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

dmg="$work/$name"
echo "Downloading $name"
curl -fL --progress-bar -o "$dmg" "$url" || fail 'the download failed.'

expected=${digest#sha256:}
if [ -n "$expected" ]; then
    actual=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
    [ "$actual" = "$expected" ] || fail "the download does not match its SHA-256 ($actual, expected $expected)."
    echo 'SHA-256 matches.'
else
    echo 'warning: GitHub published no SHA-256 for this file, so it was not checked.' >&2
fi

mkdir "$work/image"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$work/image" "$dmg" || fail 'could not open the disk image.'
mounted="$work/image"
[ -d "$mounted/Rinflow.app" ] || fail 'Rinflow.app is not in the disk image.'

echo 'Installing into /Applications'
rm -rf /Applications/Rinflow.app 2> /dev/null || fail 'could not replace /Applications/Rinflow.app. Run this again with sudo, or drag the app from the disk image yourself.'
ditto "$mounted/Rinflow.app" /Applications/Rinflow.app || fail 'could not copy Rinflow.app into /Applications.'

echo "Installed Rinflow $tag. Open it from Applications, and grant it the Accessibility permission."
