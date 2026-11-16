#!/usr/bin/env python3
"""Print the crashed thread of each .ips crash report (Apple's JSON crash format).

usage: crash-summary.py report.ips [...]
"""
import json
import sys

for path in sys.argv[1:]:
    try:
        with open(path) as f:
            header = json.loads(f.readline())
            body = json.loads(f.read())
    except Exception as e:
        print(f"== {path}: unreadable ({e})")
        continue
    print(f"== {path}")
    print(f"   process: {body.get('procName', header.get('app_name'))}  bug_type: {header.get('bug_type')}")
    exc = body.get("exception", {})
    print(f"   exception: {exc.get('type')} {exc.get('signal')} {exc.get('subtype', '')}")
    images = body.get("usedImages", [])
    for idx, thread in enumerate(body.get("threads", [])):
        if not thread.get("triggered"):
            continue
        print(f"   crashed thread {idx}: {thread.get('name') or thread.get('queue', '')}")
        for n, fr in enumerate(thread.get("frames", [])[:40]):
            img = images[fr["imageIndex"]].get("name", "?") if fr.get("imageIndex", -1) < len(images) else "?"
            print(f"     {n:2d} {img:32s} {fr.get('symbol', hex(fr.get('imageOffset', 0)))}")
