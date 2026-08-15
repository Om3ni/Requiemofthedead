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

def _find_repo():
    d = os.path.dirname(os.path.abspath(__file__))
    while True:
        if os.path.isdir(os.path.join(d, "RequiemOfTheDead", "Contents")) \
                and os.path.isdir(os.path.join(d, "tools")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            sys.exit("cannot locate the repo root above " + os.path.abspath(__file__))
        d = parent

REPO = _find_repo()
MODS = os.path.join(REPO, "RequiemOfTheDead", "Contents", "mods")
SAFE_FILE = os.path.join(REPO, "tools", "pcall-safe.json")
BASE_FILE = os.path.join(REPO, "tools", "pcall-baseline.json")

# Files whose whole job is probing engine internals - guards there are the
# feature, not the debt.
EXEMPT_BASENAMES = {"HBDebugPanel.lua", "DFItemProbes.lua", "HBAPIProbe.lua"}

LONG_OPEN = re.compile(r"\[(=*)\[")
METHOD_CALL = re.compile(r"[:.]([A-Za-z_][A-Za-z0-9_]*)\s*[(,]")


def blank_comments_and_strings(text):
    """Return text with comment and string bodies replaced by spaces (newlines
    kept), so scanning never trips over a ':method(' inside either."""
    out = list(text)
    i, n = 0, len(text)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        c = text[i]
        if c in "'\"":
            start = i
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                elif text[i] == c or text[i] == "\n":
                    i += 1
                    break
                else:
                    i += 1
            blank(start, i)
        elif c == "[" and LONG_OPEN.match(text, i):
            m = LONG_OPEN.match(text, i)
            close = "]" + m.group(1) + "]"
            end = text.find(close, m.end())
            end = n if end == -1 else end + len(close)
            blank(i, end)
            i = end
        elif c == "-" and text.startswith("--", i):
            m = LONG_OPEN.match(text, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                end = text.find(close, m.end())
                end = n if end == -1 else end + len(close)
            else:
                end = text.find("\n", i)
                end = n if end == -1 else end
            blank(i, end)
            i = end
        else:
            i += 1
    return "".join(out)


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


def scan_file(path, safe):
    """Yield (line_no, targets, all_safe) for each pcall site."""
    with open(path, "rb") as f:
        text = f.read().decode("utf-8", "replace")
    clean = blank_comments_and_strings(text)
    for m in re.finditer(r"\bpcall\s*\(", clean):
        end = pcall_extent(clean, m.end() - 1)
        body = clean[m.end():end]
        targets = METHOD_CALL.findall(body)
        # pcall(obj.method, obj) leaves 'method' via the ',' branch; the closure
        # form leaves every ':method(' inside it. Either way, targets is what
        # this guard is actually protecting.
        targets = [t for t in targets if t != "pcall"]
        all_safe = bool(targets) and all(t in safe for t in targets)
        yield text.count("\n", 0, m.start()) + 1, targets, all_safe


def lua_files():
    for dirpath, _, filenames in os.walk(MODS):
        for name in sorted(filenames):
            if name.lower().endswith(".lua") and name not in EXEMPT_BASENAMES:
                yield os.path.join(dirpath, name)


def mod_of(path):
    rel = os.path.relpath(path, MODS)
    return rel.split(os.sep)[0]


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

    counts, violations = {}, []
    for path in lua_files():
        mod = mod_of(path)
        rel = os.path.relpath(path, REPO).replace(os.sep, "/")
        for line, targets, all_safe in scan_file(path, safe):
            counts[mod] = counts.get(mod, 0) + 1
            if args.list:
                print(f"{rel}:{line}  {','.join(targets) or '(no method call)'}")
            if all_safe:
                violations.append(
                    f"{rel}:{line}  guards only verified-safe calls "
                    f"({', '.join(sorted(set(targets)))}) - call directly")

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
    if crept:
        print()
        for c in crept:
            print("CREEP      " + c)
        print("           new guards need a reason in the code, then --update")

    total = sum(counts.values())
    if violations or crept:
        print(f"\nFAIL  {len(violations)} removable, {len(crept)} mod(s) over baseline "
              f"({total} pcalls total)")
        return 1
    print(f"pcall check clean - {total} guard(s), all justified, no mod over baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
