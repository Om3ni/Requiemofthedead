#!/usr/bin/env python3
# check-pcall - the guard on the guards.
#
# WHY THIS EXISTS (2026-08-13): the suite reached 1,299 pcall sites, roughly two
# thirds of them wrapping plain Java getters that cannot throw - getX, getSquare,
# items:get(i) - none of which had ever produced an error to justify them. They
# cost real budget (Reaper's scan budget was set to pay for them) and they cost
# far more in debugging: a swallowed failure computes garbage silently, and
# pcall does not even buy quiet, because the engine logs the caught error anyway.
#
# The cleanup is one-time work. THIS is the part that lasts: a pcall added back
# around a verified-safe call fails the check, and a mod's total can never creep
# upward without someone consciously raising its baseline.
#
# TWO RULES
#
#   1. NO GUARD ON VERIFIED-SAFE CALLS. tools/pcall-safe.json lists engine
#      methods whose 42.20.2 bodies were READ and found to be trivial field
#      returns (or fully null-checked). A pcall whose every engine call is on
#      that list is flagged: call it directly. Mixed guards are left alone - the
#      unverified call in there may be the one that matters.
#
#   2. RATCHET. tools/pcall-baseline.json holds a per-mod count. Fewer is always
#      accepted (and rewritten on --update, so progress locks in). MORE fails,
#      and the fix is a deliberate act: add the guard's reason to the code, then
#      run --update to move the baseline with your eyes open.
#
#   3. AN OPAQUE GUARD MUST SAY WHY. Rule 1 matches on the engine methods inside
#      the guard, so a pcall containing NO method call - pcall(someLocal), or a
#      closure that only touches fields - can never be flagged by it, whatever it
#      wraps. That was 22% of the suite sitting in a region rule 1 structurally
#      cannot reach. Those guards now have to carry a comment (a line above, or
#      trailing on the same line). Cheap for a real guard, which already has a
#      reason worth writing; the ones that cannot produce a reason are the ones
#      worth deleting.
#
# WHAT A GUARD IS FOR (read out of the 42.20.2 decompile, 2026-08-15): the engine
# ALREADY contains a throw at every dispatch boundary - Event.trigger runs each
# listener through protectedCallVoid inside a per-listener try/catch
# (Event.java:53-63), and UIManager.render does the same per element. It also logs
# at throw time (KahluaThread:865/:1100) BEFORE any Lua pcall sees the error, so a
# guard buys no silence either. A guard therefore earns its place by GRANULARITY -
# letting one bad row fail without costing the whole pass - never by containment.
# Sixteen guards whose comments claimed otherwise were deleted the day this was
# verified; do not write the seventeenth.
#
# Adding to the safe list is a decompile job, not a guess: read the Java body in
# PZ_Engine_Decompiled_*/ and record where you read it. "It looks like a getter"
# is how the 1,299 happened.
#
# Usage:
#   python tools\check-pcall.py            check; non-zero exit on any violation
#   python tools\check-pcall.py --update   rewrite baselines to current counts
#   python tools\check-pcall.py --list     print every pcall site with its target

import argparse
import json
import os
import re
import sys

# The repo walk, the comment blanker and the mod-exempt list are shared with
# check-helpers.py - see tools/luascan.py.
from luascan import (REPO, blank_comments_and_strings, lua_files, mod_of,
                     rel as relpath)
SAFE_FILE = os.path.join(REPO, "tools", "pcall-safe.json")
BASE_FILE = os.path.join(REPO, "tools", "pcall-baseline.json")

METHOD_CALL = re.compile(r"[:.]([A-Za-z_][A-Za-z0-9_]*)\s*[(,]")


def pcall_extent(text, open_paren):
    """Index just past the ')' that closes the pcall argument list."""
    depth, i, n = 0, open_paren, len(text)
    while i < n:
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


# How far above a guard we look for its reason. Four lines covers a short prose
# comment without reaching back into the previous statement's.
COMMENT_LOOKBACK = 4


def scan_file(path, safe):
    """Yield (line_no, targets, all_safe, documented) for each pcall site."""
    with open(path, "rb") as f:
        text = f.read().decode("utf-8", "replace")
    clean = blank_comments_and_strings(text)
    # Comments are blanked in `clean`, so the reason is read off the RAW text.
    raw_lines = text.split(chr(10))
    for m in re.finditer(r"\bpcall\s*\(", clean):
        end = pcall_extent(clean, m.end() - 1)
        body = clean[m.end():end]
        targets = METHOD_CALL.findall(body)
        # pcall(obj.method, obj) leaves 'method' via the ',' branch; the closure
        # form leaves every ':method(' inside it. Either way, targets is what
        # this guard is actually protecting.
        targets = [t for t in targets if t != "pcall"]
        all_safe = bool(targets) and all(t in safe for t in targets)
        line = text.count(chr(10), 0, m.start()) + 1
        # A reason counts if it sits just above, or trails the guard itself.
        above = raw_lines[max(0, line - 1 - COMMENT_LOOKBACK):line - 1]
        documented = any("--" in t for t in above) or "--" in raw_lines[line - 1]
        yield line, targets, all_safe, documented


def main():
    ap = argparse.ArgumentParser(description="pcall debt guard")
    ap.add_argument("--update", action="store_true", help="rewrite baselines to current counts")
    ap.add_argument("--list", action="store_true", help="print every pcall site and its targets")
    args = ap.parse_args()

    safe = set()
    if os.path.exists(SAFE_FILE):
        with open(SAFE_FILE, encoding="utf-8") as f:
            for methods in json.load(f)["safe"].values():
                safe.update(methods)

    baseline = {}
    if os.path.exists(BASE_FILE):
        with open(BASE_FILE, encoding="utf-8") as f:
            baseline = json.load(f)["mods"]

    counts, violations, undocumented = {}, [], []
    for path in lua_files():
        mod = mod_of(path)
        rel = relpath(path)
        for line, targets, all_safe, documented in scan_file(path, safe):
            counts[mod] = counts.get(mod, 0) + 1
            if args.list:
                print(f"{rel}:{line}  {','.join(targets) or '(no method call)'}")
            if all_safe:
                violations.append(
                    f"{rel}:{line}  guards only verified-safe calls "
                    f"({', '.join(sorted(set(targets)))}) - call directly")
            elif not targets and not documented:
                undocumented.append(
                    f"{rel}:{line}  opaque guard - no engine call rule 1 can see, "
                    f"and no reason given: say why, or delete it")

    crept = []
    for mod in sorted(set(counts) | set(baseline)):
        now, was = counts.get(mod, 0), baseline.get(mod)
        if was is not None and now > was:
            crept.append(f"{mod}: {was} -> {now} (+{now - was})")

    # --list is a pure inventory: sites and nothing else. It used to fall through
    # into the violation report below, so `--list | grep -c <mod>` counted every
    # flagged site twice and made a clean mod look like it had grown.
    if args.list:
        print(f"\n{sum(counts.values())} pcall site(s) across {len(counts)} mods")
        return 0

    if args.update:
        with open(BASE_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "_comment": "Per-mod pcall ceiling. Lower is free; raising it is a "
                            "deliberate act - document the guard's reason in the code first.",
                "mods": dict(sorted(counts.items())),
            }, f, indent=2)
            f.write("\n")
        print(f"baseline updated: {sum(counts.values())} pcall(s) across {len(counts)} mods")
        return 0

    for v in violations:
        print("REMOVABLE  " + v)
    for u in undocumented:
        print("UNDOCUMENTED  " + u)
    if crept:
        print()
        for c in crept:
            print("CREEP      " + c)
        print("           new guards need a reason in the code, then --update")

    total = sum(counts.values())
    if violations or crept or undocumented:
        print(f"{chr(10)}FAIL  {len(violations)} removable, {len(undocumented)} undocumented, "
              f"{len(crept)} mod(s) over baseline ({total} pcalls total)")
        return 1
    print(f"pcall check clean - {total} guard(s), all justified, no mod over baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
