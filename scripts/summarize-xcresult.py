#!/usr/bin/env python3
"""Turn xcresulttool JSON into a short Markdown summary.

usage: summarize-xcresult.py summary.json tests.json [--title TITLE] [--failures-only] > summary.md

`--failures-only` leaves out the per-test table (the stress run repeats every test) and lists only the
failing tests. Failure messages are collected from anywhere below a test case, including parameterized
arguments and repetitions, which is where Swift Testing `arguments:` and `-test-iterations` put them.
"""
import json
import sys


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:  # missing/invalid result bundle
        return {"_error": str(e)}


args = sys.argv[1:]
failures_only = "--failures-only" in args
args = [a for a in args if a != "--failures-only"]
title = "RewindCam tests"
if "--title" in args:
    i = args.index("--title")
    title = args[i + 1]
    del args[i:i + 2]

summary = load(args[0])
tests = load(args[1])

out = []
result = summary.get("result", "Unknown")
icon = {"Passed": "✅", "Failed": "❌"}.get(result, "⚠️")
out.append(f"## {icon} {title}: {result}")
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


def failure_messages(node, where):
    """Every Failure Message below `node`, labelled with the arguments/repetition it belongs to."""
    msgs = []
    for c in node.get("children", []):
        kind = c.get("nodeType", "")
        if kind == "Failure Message":
            label = " / ".join(where)
            msgs.append(f"[{label}] {c.get('name', '')}" if label else c.get("name", ""))
        elif kind != "Test Case":
            msgs.extend(failure_messages(c, where + [c.get("name", kind)]))
    return msgs


def walk(node, path):
    kind = node.get("nodeType", "")
    name = node.get("name", "")
    if kind == "Test Case":
        cases.append((path, name, node.get("result", "?"), node.get("duration", ""), failure_messages(node, [])))
        return
    nxt = path + [name] if kind in ("Unit test bundle", "UI test bundle", "Test Suite") else path
    for c in node.get("children", []):
        walk(c, nxt)


for n in tests.get("testNodes", []):
    walk(n, [])

if cases and not failures_only:
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
        for m in msgs[:5] or ["(no failure message in the result bundle)"]:
            out.append(f"```\n{m[:1500]}\n```")
elif failures_only and "_error" not in summary:
    out.append("\nNo failing tests.")

print("\n".join(out))
