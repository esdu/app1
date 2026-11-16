#!/usr/bin/env python3
"""Turn xcresulttool JSON into a short Markdown summary.

usage: summarize-xcresult.py summary.json tests.json > summary.md
"""
import json
import sys


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:  # missing/invalid result bundle
        return {"_error": str(e)}


summary = load(sys.argv[1])
tests = load(sys.argv[2])

out = []
result = summary.get("result", "Unknown")
icon = {"Passed": "✅", "Failed": "❌"}.get(result, "⚠️")
out.append(f"## {icon} RewindCam tests: {result}")
if "_error" in summary:
    out.append(f"\nNo result bundle could be read: `{summary['_error']}`")
else:
    out.append("")
    out.append("| Total | Passed | Failed | Skipped |")
    out.append("|---|---|---|---|")
    out.append(
        f"| {summary.get('totalTestCount', '?')} | {summary.get('passedTests', '?')} "
        f"| {summary.get('failedTests', '?')} | {summary.get('skippedTests', '?')} |"
    )
    for dev in summary.get("devicesAndConfigurations", [])[:1]:
        d = dev.get("device", {})
        out.append(f"\nDevice: {d.get('deviceName', '?')} — {d.get('platform', '')} {d.get('osVersion', '')}")

cases = []


def walk(node, path):
    kind = node.get("nodeType", "")
    name = node.get("name", "")
    if kind == "Test Case":
        msgs = [c.get("name", "") for c in node.get("children", []) if c.get("nodeType") == "Failure Message"]
        cases.append((path, name, node.get("result", "?"), node.get("duration", ""), msgs))
        return
    nxt = path + [name] if kind in ("Unit test bundle", "UI test bundle", "Test Suite") else path
    for c in node.get("children", []):
        walk(c, nxt)


for n in tests.get("testNodes", []):
    walk(n, [])

if cases:
    out.append("\n| Test | Result | Duration |")
    out.append("|---|---|---|")
    for path, name, res, dur, _ in cases:
        mark = {"Passed": "✅", "Failed": "❌", "Skipped": "⏭️"}.get(res, res)
        out.append(f"| `{'/'.join(path[1:] or path)}/{name}` | {mark} | {dur} |")

failures = [(p, n, m) for p, n, r, _, m in cases if r == "Failed"]
if failures:
    out.append("\n### Failures")
    for p, n, msgs in failures:
        out.append(f"\n**{'/'.join(p)}/{n}**")
        for m in msgs[:5]:
            out.append(f"```\n{m[:1500]}\n```")

print("\n".join(out))
