#!/usr/bin/env python3
"""Copy exported xcresult attachments to readable names using manifest.json.

usage: rename-screenshots.py <exported-dir> <out-dir>
"save-1-launched_0_E3C5…png" → "save-1-launched.png"
"""
import json
import os
import re
import shutil
import sys

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
with open(os.path.join(src, "manifest.json")) as f:
    manifest = json.load(f)
for test in manifest:
    for att in test.get("attachments", []):
        exported = att.get("exportedFileName")
        name = att.get("suggestedHumanReadableName") or exported
        if not exported or not exported.endswith(".png"):
            continue
        clean = re.sub(r"_\d+_[0-9A-F-]{36}(?=\.png$)", "", name)
        shutil.copy(os.path.join(src, exported), os.path.join(dst, clean))
        print(clean)
