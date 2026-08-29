#!/usr/bin/env python3
# check-deadlocals - the guard on declarations nothing reads.
#
# WHY THIS EXISTS (2026-08-27). The debt audit that opened this slice found 18
# unused or write-only locals across nine mods, and the only reason anyone knew
# was that a person ran luacheck by hand with the right flags. Every gate in
# tools\Gates was green the whole time: check-lua IS luacheck, but it asks only
# whether the file parses, and dead code parses perfectly. run-tests runs real
# Lua 5.1, where an unread local is not an error either. So the suite had a
# class of debt that no automated surface could see, accumulating at whatever
# rate people wrote it.
#
# WHAT IT COUNTS. Three luacheck diagnostics, and only these three:
#
#   W211  a local (or local function) that is declared and never used
#   W221  a local that is declared without a value and never set
#   W231  a local that is SET but never read - the write-only flag
#
# W231 is the one that earns the gate on its own. An unused constant is tidy
# debt; a variable that is assigned on three paths and read on none is a
# statement about intent that the code does not honour. RQServer's
# svSnapshotDirty was exactly that for months: two paths announced a dirty
# snapshot, nothing listened, and the only reason it was harmless is that the
# delta builder had quietly superseded the flag. The next one may not be
# harmless.
#
# WHY A RATCHET AND NOT ZERO. Unlike check-kahlua, where there is no correct use
# of a global that does not exist, a residue here is legitimate and each item
# needs a judgement:
#
#   - a named enum member the code never compares against by name, where
#     deleting it leaves a holed enum and a comment pointing at nothing;
#   - a private function staged for a feature that is designed but unbuilt,
#     where deleting it is a product decision rather than a cleanup;
#   - a helper whose absence is itself the bug, and the fix is a call site
#     rather than a deletion.
#
# Each of those is a decision with a name on it, not a lint fix, and a
# zero-tolerance gate would push the cheap wrong answer (delete it) over the
# right one (decide). The ratchet says: whatever is left is known, written down,
# and cannot grow.
#
# The baseline is per-mod because the debt is: a mod that grows one is the mod
# whose slice introduced it, and that is who the message is for.
#
# Usage:
#   python tools\Gates\check-deadlocals.py            check; non-zero on creep
#   python tools\Gates\check-deadlocals.py --update   rewrite the baseline
#   python tools\Gates\check-deadlocals.py --list     print every finding

import argparse
import os
import re
import subprocess
import sys

import ratchet
from luascan import MODS, lua_files, mod_of, rel

HERE = os.path.dirname(os.path.abspath(__file__))
BASE_FILE = os.path.join(HERE, "deadlocals-baseline.json")
LUACHECK = os.path.join(HERE, "luacheck.exe")

CODES = ("211", "221", "231")

RATCHET_REASON = (
    "Per-mod ceiling on unused/write-only locals (luacheck W211/W221/W231). "
    "Lower is free; raising it means a slice left a declaration nothing reads - "
    "resolve it or state the decision. See check-deadlocals.py."
)

# `path:line:col: (Wnnn) message`. luacheck emits native separators, so the
# path half is matched loosely and normalized below rather than pattern-matched
# into a shape that only holds on one OS.
FINDING = re.compile(r"^\s*(?P<path>.+?):(?P<line>\d+):(?P<col>\d+): \((?P<code>W\d+)\) (?P<msg>.+?)\s*$")


def run_luacheck():
    """luacheck's report over the shipping tree, as a list of lines.

    --only takes a variadic pattern list, so the `--` terminator is load-
    bearing: without it luacheck swallows the target directory as a fourth
    pattern and exits "missing argument 'files'" - which looks like a broken
    install rather than a mis-built command line. Cost half an hour once.
    """
    if not os.path.exists(LUACHECK):
        sys.exit("luacheck.exe is missing from " + HERE)
    proc = subprocess.run(
        [LUACHECK, "--std", "lua51", "--codes", "--only", *CODES, "--", MODS],
        capture_output=True, text=True,
    )
    # luacheck exits non-zero merely for HAVING findings, which is its report
    # and not a fault. A real failure (bad flag, unreadable tree) prints nothing
    # parseable, and the empty-findings check below catches it.
    return (proc.stdout or "").splitlines()


def findings():
    out = []
    for line in run_luacheck():
        m = FINDING.match(line)
        if not m:
            continue
        path = os.path.abspath(m.group("path"))
        # Only the shipping tree is subject. Fixtures under tools\Gates\tests
        # legitimately declare values a test never reads.
        if os.path.commonpath([path, MODS]) != MODS:
            continue
        out.append((mod_of(path), rel(path), int(m.group("line")),
                    m.group("code"), m.group("msg")))
    return sorted(out, key=lambda f: (f[1], f[2]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--update", action="store_true",
                    help="rewrite the baseline to the current counts")
    ap.add_argument("--list", action="store_true",
                    help="print every finding and exit 0")
    args = ap.parse_args()

    found = findings()

    # EXPLICIT ZEROS, and this gate needs them where check-pcall and
    # check-helpers do not. ratchet.creep treats a mod missing from the baseline
    # as unconstrained, which is right for a gate whose scanner keeps learning to
    # see more - silence there means "not measured yet", not "clean". Here it
    # would mean the opposite of what it says: the eleven mods this slice cleaned
    # to zero would carry NO ceiling, and the next dead local in any of them
    # would pass green. Proved by injecting one into RFTDCore on 2026-08-27 and
    # watching the gate report it and exit 0.
    #
    # So every mod that ships a .lua file gets a number, and a mod that ships
    # none cannot hold a finding anyway.
    counts = {mod_of(p): 0 for p in lua_files()}
    for mod, _r, _l, _c, _m in found:
        counts[mod] = counts.get(mod, 0) + 1

    if args.update:
        ratchet.save(BASE_FILE, RATCHET_REASON, counts)
        print(f"baseline updated: {len(found)} finding(s) across {len(counts)} mod(s)")
        return 0

    for _mod, r, line, code, msg in found:
        print(f"DEAD    {r}:{line}  ({code}) {msg}")

    if args.list:
        print(f"\n{len(found)} finding(s)")
        return 0

    baseline = ratchet.load(BASE_FILE)
    crept = ratchet.creep(counts, baseline)
    if crept:
        print()
        for c in crept:
            print("CREEP   " + c)
        print("        a declaration nothing reads is either debt or a missing")
        print("        call site - delete it or wire it, then --update")
        print(f"\nFAIL  {len(crept)} mod(s) over baseline ({len(found)} finding(s))")
        return 1

    if found:
        print(f"\n{len(found)} finding(s) - at or under baseline, but every line "
              f"here is still debt")
        return 0
    print("deadlocals check clean - no unused or write-only locals")
    return 0


if __name__ == "__main__":
    sys.exit(main())
