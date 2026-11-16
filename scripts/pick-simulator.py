#!/usr/bin/env python3
"""Print the UDID of an available iPhone simulator on the newest iOS runtime.

Reads `xcrun simctl list devices available -j` on stdin. Nothing is hard-coded:
the newest iOS runtime wins, and within it the first iPhone (sorted by name)
that is available. Prints "<udid> <name> <runtime>" to stdout.
"""
import json
import re
import sys

data = json.load(sys.stdin)
candidates = []
for runtime, devices in data.get("devices", {}).items():
    m = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    if not m:
        continue
    version = tuple(int(x or 0) for x in m.groups())
    for d in devices:
        if d.get("isAvailable", True) and d.get("name", "").startswith("iPhone"):
            candidates.append((version, d["name"], d["udid"], runtime))

if not candidates:
    sys.exit("no available iPhone simulator found")

newest = max(c[0] for c in candidates)
pool = sorted((c for c in candidates if c[0] == newest), key=lambda c: c[1])
# Prefer a plain current-generation model if present (fast to boot), else first by name.
preferred = [c for c in pool if re.fullmatch(r"iPhone \d+", c[1])]
choice = (preferred or pool)[0]
print(choice[2], choice[1].replace(" ", "_"), ".".join(map(str, newest)))
