#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Requires librsvg (rsvg-convert). The source reuses the Windows logo.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
iconTemp=$(mktemp -d)
trap 'rm -rf "$iconTemp"' EXIT HUP INT TERM
mkdir -p "$iconTemp/AppIcon.iconset"
rsvg-convert -w 1024 -h 1024 "$ROOT/Rinflow/Resources/AppIcon.svg" -o "$iconTemp/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$iconTemp/icon.png" --out "$iconTemp/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$iconTemp/icon.png" --out "$iconTemp/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconTemp/AppIcon.iconset" -o "$ROOT/Rinflow/Resources/AppIcon.icns"
