#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# The notes of a release: the commits since the previous release, by kind.
#
#   scripts/release-notes.sh v0.0.2
#
# The previous release is the nearest earlier tag that is not a prerelease
# (v0.0.2-rc1 is one), so a release lists everything its prereleases did.
# Merge commits are left out. Needs the full history and the tags.
set -eu

tag=${1:?usage: release-notes.sh <tag>}
previous=$(git describe --tags --abbrev=0 --match 'v*' --exclude 'v*-*' "$tag^" 2>/dev/null || true)
range=${previous:+$previous..}$tag

git log --no-merges --format=%s "$range" | awk '
    { kind = $0; sub(/[(:!].*/, "", kind) }
    kind == "feat" { added[++a] = $0; next }
    kind == "fix"  { fixed[++f] = $0; next }
                   { other[++o] = $0 }
    function list(title, n, items,    i) {
        if (n == 0) return
        printf "%s### %s\n\n", (shown++ ? "\n" : ""), title
        for (i = n; i >= 1; i--) print "- " items[i]
    }
    END {
        list("Added", a, added)
        list("Fixed", f, fixed)
        list("Other", o, other)
    }
'
