#!/usr/bin/env python3
# check-citations - resolve every decompile citation to the line it names.
#
# WHY THIS EXISTS (2026-08-18): CLAUDE.md section 1 requires a `Class.java:line`
# beside any non-obvious engine conclusion, and section 2 requires a read failure
# mode behind every guard. Those citations are load-bearing - a later session
# READS them and defers to them. RDIdentity.lua carried "write/close can fail on
# a full or locked disk (KEEP)" for months; the decompile says otherwise, and the
# comment outlived two ledger entries that had already got it right.
#
# This does not judge whether a citation SUPPORTS its claim - that needs a human
# or a careful model reading both. It does the mechanical half: find the file,
# resolve the line, print what is actually there. A citation pointing at a blank
# line or a closing brace is wrong on its face; one pointing at plausible code
# still has to be read.
#
# Usage:
#   python tools\check-citations.py            problems only
#   python tools\check-citations.py --all      every citation with its line
#   python tools\check-citations.py --file X   only citations naming X
#
# Exit 0 always: this is a review aid, not a gate. It reports, you decide.

import argparse
import os
import re
import sys

from luascan import REPO, all_lua_files, lua_files, rel as relpath

# TWO java roots, in preference order. 42.20.3 is the current verification
# target and wins any name both trees carry. But its DECOMPILE-PROVENANCE.txt
# records `scope: PZ-authored only`, so it holds 3,625 classes against 42.20.2's
# 13,793 - everything PZ wrote, and nothing it merely bundles. Citations into
# bundled library code therefore resolve only in the older, fuller tree:
# org/luaj/kahluafork/ (the LuaJ fork Kahlua is built on, including
# FuncState.java) is the case that surfaced this. Falling back keeps those
# verifiable instead of reporting a correct citation as a missing file.
JAVA_ROOTS = [
    os.path.join(REPO, "PZ_Engine_Decompiled_42.20.3-70207f62e0"),
    os.path.join(REPO, "PZ_Engine_Decompiled_42.20.2-ffe7a8a4b1"),
]
LUA_ROOT = os.path.join(REPO, "PZ_Vanilla_Lua_42.20.3-70207f62e0")

# Names that cannot resolve anywhere and are not meant to.
#
# THIRD-PARTY MOD SOURCE. DFPatch_Spongies patches a crash in "Spongies
# Character Customisation" and cites the file it patches. That citation is
# correct and load-bearing - it is how a later session checks the patch still
# matches - but the file belongs to another author's mod and is in no tree here.
#
# PROSE EXAMPLES. DFErrorPoller explains the shape of an engine stack frame,
# and the example frame contains a filename. It is documentation of a format,
# not a claim about a file.
UNRESOLVABLE = {
    ("FaceManager_Server", "lua"): "third-party mod source (Spongies Character Customisation)",
    ("EM_Core", "lua"): "third-party mod source (Expanded Moodles - Triage attributes its stat writes)",
    ("DBD_NearbyAnimals", "lua"): "third-party mod source (reference mod HBDebugPanel's animal context menu follows)",
    ("File", "lua"): "illustrative stack-frame example, not a real citation",
    ("SomeFile", "lua"): "illustrative stack-frame example, not a real citation",
}

# Foo.java:12 / Foo.java:12-20 / Foo.java:12-20, 33, 40-41
CITE = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\.(java|lua):((?:\d+(?:-\d+)?)(?:\s*,\s*\d+(?:-\d+)?)*)")

_index = {}


def build_index():
    # JAVA_ROOTS is a PREFERENCE ORDER, not a union: a class present in 42.20.3
    # is taken from there and the older tree is never consulted for it. Merging
    # them would make every PZ class match twice and report the two decompile
    # versions of one file as an ambiguity, which is noise rather than signal.
    # The fallback exists only for names 42.20.3 does not carry at all.
    for root in JAVA_ROOTS:
        if not os.path.isdir(root):
            continue
        for dirpath, _, names in os.walk(root):
            for n in names:
                if n.endswith(".java"):
                    key = (n[:-5], "java")
                    if any(r != root and h.startswith(r) for r in JAVA_ROOTS
                           for h in _index.get(key, [])):
                        continue   # already answered by a preferred root
                    _index.setdefault(key, []).append(os.path.join(dirpath, n))

    if os.path.isdir(LUA_ROOT):
        for dirpath, _, names in os.walk(LUA_ROOT):
            for n in names:
                if n.endswith(".lua"):
                    _index.setdefault((n[:-4], "lua"), []).append(
                        os.path.join(dirpath, n))
    # Suite files are cited too - "RDTeleport.lua:31-49", "DFCore.lua:73". They
    # are not vanilla, but they are just as load-bearing and just as easy to get
    # wrong, so they resolve against our own tree.
    #
    # Historical note: until 2026-08-20 lua_files filtered the pcall scanner's
    # EXEMPT_BASENAMES and this loop had to use all_lua_files to see the whole
    # tree. The exemption is gone and the two names are one walk now; the alias
    # is kept so the distinction never has to be re-litigated here.
    for p in all_lua_files():
        n = os.path.basename(p)
        _index.setdefault((n[:-4], "lua"), []).append(p)


def spans(text):
    for part in text.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-", 1)
            yield int(a), int(b)
        else:
            yield int(part), int(part)


def sources():
    # The whole tree. Until 2026-08-20 this used the exemption-filtered walk,
    # which meant ten citations inside DFItemProbes, HBDebugPanel and HBAPIProbe
    # were never checked at all - the whole-file exemption hiding work in
    # exactly the shape that got it retired.
    for p in all_lua_files():
        yield relpath(p), p
    for name in ("REFACTOR.md", "CLAUDE.md", "TODO.md"):
        p = os.path.join(REPO, name)
        if os.path.exists(p):
            yield name, p


def main():
    ap = argparse.ArgumentParser(description="resolve decompile citations")
    ap.add_argument("--all", action="store_true", help="print every citation, not just problems")
    ap.add_argument("--file", help="only citations naming this class/file")
    args = ap.parse_args()

    build_index()
    if not _index:
        print("no decompile tree found - nothing to resolve")
        return 0

    problems = checked = 0
    for label, path in sources():
        with open(path, "rb") as f:
            lines = f.read().decode("utf-8", "replace").split("\n")
        for i, line in enumerate(lines, 1):
            for cls, kind, nums in CITE.findall(line):
                if args.file and args.file.lower() not in cls.lower():
                    continue
                checked += 1
                hits = _index.get((cls, kind))
                if not hits:
                    why = UNRESOLVABLE.get((cls, kind))
                    if why:
                        # Known-unresolvable and correct - see UNRESOLVABLE.
                        continue
                    problems += 1
                    print(f"MISSING   {label}:{i}  {cls}.{kind} is not in the {kind} tree")
                    continue
                # A name can exist twice - IsoSprite.java is both the real
                # class and a 27-line debug stub. Prefer a candidate that
                # actually CONTAINS the cited lines over the first one walked.
                wanted = max(b for _, b in spans(nums))
                bodies = []
                for h in hits:
                    with open(h, "rb") as f:
                        bodies.append((h, f.read().decode("utf-8", "replace").split("\n")))
                fits = [(h, bd) for h, bd in bodies if len(bd) >= wanted]
                if fits:
                    chosen, body = fits[0]
                    if len(fits) > 1:
                        print(f"AMBIGUOUS {label}:{i}  {cls}.{kind} matches {len(fits)} "
                              f"plausible files; using {os.path.relpath(chosen, REPO)}")
                else:
                    chosen, body = max(bodies, key=lambda hb: len(hb[1]))
                for a, b in spans(nums):
                    if a < 1 or b > len(body):
                        problems += 1
                        print(f"RANGE     {label}:{i}  {cls}.{kind}:{a}-{b} "
                              f"but the file has {len(body)} lines")
                        continue
                    text = "\n".join(body[a - 1:b])
                    if not text.strip():
                        problems += 1
                        print(f"BLANK     {label}:{i}  {cls}.{kind}:{a}"
                              f"{'-' + str(b) if b != a else ''} resolves to blank line(s)")
                    elif args.all:
                        head = body[a - 1].strip()
                        more = f"  (+{b - a} more line(s))" if b != a else ""
                        print(f"OK        {label}:{i}  {cls}.{kind}:{a} -> {head[:100]}{more}")

    print(f"\n{checked} citation(s) resolved, {problems} problem(s)")
    print("A resolved citation is NOT a verified one - read the body and decide "
          "whether it supports the claim beside it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
