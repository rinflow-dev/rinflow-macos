#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Takes the README screenshots, docs/images/devices-<language>-<light|dark>.png:
# the main window of a Debug build started with `-RinflowScreenshot`, which
# shows made-up devices and starts nothing (AppModel.init(screenshot:)).
#
# The terminal needs the Screen Recording permission. Each window comes to
# the front for a moment; a Rinflow already running is left alone.

set -eu
cd "$(dirname "$0")/.."

APP=DerivedData/Build/Products/Debug/Rinflow.app
OUT=docs/images
TOOL=$(mktemp -d)/screenshot-window
trap 'pkill -f -- "-RinflowScreenshot" || true; rm -rf "$(dirname "$TOOL")"' EXIT

make --no-print-directory build CONFIG=Debug
xcrun swiftc -O -o "$TOOL" scripts/screenshot-window.swift
mkdir -p "$OUT"

for language in en-US:en zh-CN:zh-Hans ja-JP:ja; do
    for look in light dark; do
        file="$OUT/devices-${language%%:*}-$look.png"
        # Blue is the system's default accent, whatever this Mac uses.
        open -n "$APP" --args -RinflowScreenshot "$look" \
            -AppleLanguages "(${language#*:})" -AppleAccentColor 4
        pid=
        while [ -z "$pid" ]; do pid=$(pgrep -n -f -- "-RinflowScreenshot $look") || sleep 0.1; done
        window=$("$TOOL" id "$pid")
        sleep 1 # let the window finish drawing
        screencapture -x -l"$window" "$file"
        "$TOOL" fit "$file"
        kill "$pid"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
        echo "$file"
    done
done
