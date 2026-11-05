#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Gives every string of the String Catalogs a translated entry in the source
language (Chinese), the key itself unless it has one already.

Xcode builds a language's table only from translated entries, and leaves the
source language's out when it has none. A string missing there falls back to
the development region, English, so a Chinese Mac would show English.

Usage: scripts/source-strings.py Rinflow/Resources/*.xcstrings
Writes the files as Xcode does, so a catalog already complete is unchanged.
"""

import json
import sys


def translate(localization):
    if "stringUnit" in localization:
        localization["stringUnit"]["state"] = "translated"
    for cases in localization.get("variations", {}).values():
        for case in cases.values():
            translate(case)


for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as file:
        catalog = json.load(file)
    source = catalog["sourceLanguage"]
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.setdefault("localizations", {})
        localizations.setdefault(source, {"stringUnit": {"state": "translated", "value": key}})
        translate(localizations[source])
        entry["localizations"] = dict(sorted(localizations.items()))
    with open(path, "w", encoding="utf-8") as file:
        file.write(json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : ")))
