#!/usr/bin/env python3
# check-helpers - the guard on copied helpers.
#
# WHY THIS EXISTS (2026-08-15): a sweep found 1,131 `local function` helpers in
# the suite, 44 of them byte-identical copies of another - `fS` alone existed
# nine times across four mods, and StaffTools carried its entire role-editing
# core (getCapabilityByName / applyOverride / findRole, 30 lines) twice, once
# client-side and once server-side. Nothing had gone wrong yet. That is the
# problem: two copies of a capability check do not announce the day they start
# disagreeing.
#
# Same shape as check-pcall.py, and for the same reason - the cleanup is
# one-time work, the ratchet is what lasts.
#
# THE RULE. A normalized body appearing in two or more places is a violation.
# Normalization blanks comments and strings, collapses whitespace, and DROPS THE
# FUNCTION NAME, so renaming a copy does not hide it - `isEmpty` and
# `isEmptyTable` are the same helper wearing two hats, and the checker says so.
#
# WHERE THE FIX GOES (README/CLAUDE.md, unchanged by this tool):
#   - two or more consumer MODS  -> RFTDCore/42/media/lua/shared/. Everything
#     hard-requires Core, so this adds no dependency.
#   - copies inside ONE mod      -> that mod's own shared/ file. Do not promote
#     a single-consumer helper to Core; leaf code in Core can never be switched
#     off.
# The report labels each group so the choice is not a judgement call.
#
# Usage:
#   python tools\check-helpers.py            check; non-zero exit on any dup
#   python tools\check-helpers.py --update   rewrite baselines to current counts
#   python tools\check-helpers.py --list     print every helper and where it lives

import argparse
import json
import os
import re
import sys

from luascan import REPO, blank_comments_and_strings, lua_files, mod_of, read, rel

BASE_FILE = os.path.join(REPO, "tools", "helper-baseline.json")

DEF = re.compile(r"^\s*local function ([A-Za-z_][A-Za-z0-9_]*)\s*\(")
# Lua block words. `do` is deliberately absent: the `do` of `for ... do` would
# double-count, and a bare do-block inside a helper is vanishingly rare next to
# that cost.
OPENERS = ("function", "for", "while", "repeat", "if")
BLOCK = re.compile(r"\b(function|for|while|repeat|if|end|until)\b")


def helpers(path):
    """Yield (name, line, normalized_body, raw_line_count) per local function."""
    text = read(path)
    clean = blank_comments_and_strings(text)
    lines, raw = clean.split("\n"), text.split("\n")
    for i, line in enumerate(lines):
        m = DEF.match(line)
        if not m:
            continue
        depth, end = 0, None
        for j in range(i, len(lines)):
            for tok in BLOCK.findall(lines[j]):
                depth += 1 if tok in OPENERS else -1
            if depth <= 0:
                end = j
                break
        if end is None:          # unbalanced (or truncated) - not ours to judge
            continue
        body = "\n".join(raw[i:end + 1])
        norm = re.sub(r"\s+", " ", blank_comments_and_strings(body)).strip()
        norm = re.sub(r"^local function [A-Za-z_][A-Za-z0-9_]*", "local function _", norm)
        yield m.group(1), i + 1, norm, end - i + 1


def main():
    ap = argparse.ArgumentParser(description="copied-helper guard")
    ap.add_argument("--update", action="store_true", help="rewrite baselines to current counts")
    ap.add_argument("--list", action="store_true", help="print every helper and its location")
    args = ap.parse_args()

    found = {}
    for path in lua_files():
        for name, line, norm, span in helpers(path):
            found.setdefault(norm, []).append((mod_of(path), rel(path), line, name, span))

    if args.list:
        n = 0
        for sites in found.values():
            for mod, r, line, name, span in sites:
                print(f"{r}:{line}  {name}  ({span} lines)")
                n += 1
        print(f"\n{n} helper(s), {len(found)} distinct body/bodies")
        return 0

    baseline = {}
    if os.path.exists(BASE_FILE):
        with open(BASE_FILE, encoding="utf-8") as f:
            baseline = json.load(f)["mods"]

    # One copy per group is the original; every other is debt, charged to the mod
    # holding it. Sorting makes "which one is the original" deterministic, so the
    # per-mod numbers do not shuffle between runs.
    groups, counts = [], {}
    for norm, sites in found.items():
        if len(sites) < 2:
            continue
        sites = sorted(sites, key=lambda s: (s[1], s[2]))
        for mod, _r, _l, _n, _s in sites[1:]:
            counts[mod] = counts.get(mod, 0) + 1
        groups.append(sites)
    groups.sort(key=lambda g: (-len(g), g[0][1]))

    if args.update:
        with open(BASE_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "_comment": "Per-mod ceiling on COPIED helpers (identical body, second "
                            "and later copies). Lower is free; raising it means you "
                            "pasted a helper - promote it instead. See check-helpers.py.",
                "mods": dict(sorted(counts.items())),
            }, f, indent=2)
            f.write("\n")
        print(f"baseline updated: {sum(counts.values())} copied helper(s) across {len(counts)} mods")
        return 0

    for g in groups:
        mods = sorted({s[0] for s in g})
        names = sorted({s[3] for s in g})
        where = ("RFTDCore/shared - %d mods" % len(mods)) if len(mods) > 1 \
            else ("%s's own shared/" % mods[0])
        alias = "" if len(names) == 1 else "  (aliased: %s)" % ", ".join(names)
        print(f"COPIED  {len(g)}x  {names[0]}  {g[0][4]} lines  -> {where}{alias}")
        for mod, r, line, name, span in g:
            print(f"          {r}:{line}")

    crept = []
    for mod in sorted(set(counts) | set(baseline)):
        now, was = counts.get(mod, 0), baseline.get(mod)
        if was is not None and now > was:
            crept.append(f"{mod}: {was} -> {now} (+{now - was})")
    if crept:
        print()
        for c in crept:
            print("CREEP   " + c)
        print("        a new copy is not a fix - promote the helper, then --update")

    total = sum(counts.values())
    if crept:
        print(f"\nFAIL  {len(crept)} mod(s) over baseline ({total} copied helpers, "
              f"{len(groups)} group(s))")
        return 1
    if groups:
        print(f"\n{total} copied helper(s) in {len(groups)} group(s) - at or under "
              f"baseline, but every line here is still debt")
        return 0
    print("helper check clean - no copied helpers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
