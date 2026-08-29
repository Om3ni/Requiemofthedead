#!/usr/bin/env python3
# check-versions - the version a mod REPORTS must be the version it SHIPS.
#
# WHY THIS EXISTS (2026-08-25), second recurrence. Five mods' registerMod
# strings said 1.0.0 while every mod.info said 1.2.0, and the drift was found
# by a release check happening to look - the HELLO handshake built precisely to
# expose version skew (RDLife.lua) was itself reporting the wrong number for
# five of thirteen mods. registerMod is a bare table write, so nothing warns;
# the whole enforcement mechanism was a handful of "keep in sync with mod.info"
# comments, present only on the mods that hardcode the literal. A rule everyone
# knows, written down nowhere a machine reads - the same shape check-kahlua
# closed for the Kahlua divergences.
#
# THREE CHECKS, two enforced and one advisory:
#
#   1. LOCKSTEP + BYTE-IDENTITY (fails). Both copies of each mod's mod.info
#      (<mod>/mod.info and <mod>/42/mod.info) must be byte-identical - the
#      CLAUDE.md sect. 15 rule, unchecked until now - and every modversion=
#      must be the same suite version (README: lockstep, one version for all).
#   2. REGISTERMOD DRIFT (fails). The version each mod hands
#      RDShared.registerMod - a literal in the call, or the X.VERSION constant
#      it names, resolved from the same mod's own tree - must equal that mod's
#      modversion=.
#   3. UNREGISTERED MODS (advisory). A shipped mod id that never calls
#      registerMod is invisible to the HELLO handshake in either direction -
#      not drifted, simply absent. Known today: BBLibrary, RFTDDungeonMaster,
#      RFTDLimes. Adding the call is one line each but changes what those mods
#      do at boot and what the handshake reports, so it is a DECISION (owner),
#      not a fix this gate may force. Reported every run so the decision stays
#      visible; never fails the build.
#
# Attribution is by PATH, not by the first argument of the call: the mod a
# registerMod call belongs to is the tree it lives in, which sidesteps
# file-local MODULE constants (RPServer.lua registers with a local). The id
# argument is still cross-checked when it is a plain literal.

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
MODS = ROOT / "RequiemOfTheDead" / "Contents" / "mods"

REGISTER = re.compile(r'registerMod\s*\(\s*([^,]+?)\s*,\s*([^)]+?)\s*\)')
LITERAL = re.compile(r'^"([^"]+)"$')
# X.VERSION = "1.2.1"  (the constant a registerMod call may name)
VERSION_CONST = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\.VERSION\s*=\s*"([^"]+)"', re.M)


def fail(msg):
    print("VERSIONS  " + msg)


def main():
    problems = 0
    advisories = []

    mods = sorted(p for p in MODS.iterdir() if p.is_dir())

    # -- 1. mod.info pairs: byte-identical, one lockstep version ------------
    versions = {}
    for mod in mods:
        top = mod / "mod.info"
        b42 = mod / "42" / "mod.info"
        missing = [str(p.relative_to(ROOT)) for p in (top, b42) if not p.is_file()]
        if missing:
            fail(f"{mod.name}: mod.info missing: {', '.join(missing)}")
            problems += 1
            continue
        if top.read_bytes() != b42.read_bytes():
            fail(f"{mod.name}: the two mod.info copies are NOT byte-identical "
                 "(CLAUDE.md sect. 15)")
            problems += 1
        m = re.search(r'^modversion=(.+)$', top.read_text(encoding="utf-8"), re.M)
        if not m:
            fail(f"{mod.name}: mod.info has no modversion= line")
            problems += 1
            continue
        versions[mod.name] = m.group(1).strip()

    lockstep = sorted(set(versions.values()))
    if len(lockstep) > 1:
        fail("lockstep broken - modversion values differ: "
             + ", ".join(f"{k}={v}" for k, v in sorted(versions.items())))
        problems += 1
    suite = lockstep[0] if lockstep else "?"

    # -- 2. registerMod drift ----------------------------------------------
    registered = set()
    for mod in mods:
        consts = {}   # constant name -> version literal, from this mod's tree
        calls = []    # (file, idexpr, verexpr)
        for lua in sorted(mod.rglob("*.lua")):
            text = lua.read_text(encoding="utf-8", errors="replace")
            for name, ver in VERSION_CONST.findall(text):
                consts[name] = ver
            for m in REGISTER.finditer(text):
                # skip the definition itself and commented lines
                line_start = text.rfind("\n", 0, m.start()) + 1
                line = text[line_start:m.start()]
                if "function" in line or line.lstrip().startswith("--"):
                    continue
                calls.append((lua, m.group(1).strip(), m.group(2).strip()))

        for lua, idexpr, verexpr in calls:
            registered.add(mod.name)
            where = str(lua.relative_to(ROOT))
            lit = LITERAL.match(verexpr)
            if lit:
                got = lit.group(1)
            else:
                # NAME.VERSION - resolve the constant from this mod's tree
                cname = verexpr.split(".")[0]
                got = consts.get(cname)
                if got is None:
                    fail(f"{where}: cannot resolve {verexpr} to a literal in "
                         f"{mod.name}'s own tree")
                    problems += 1
                    continue
            want = versions.get(mod.name)
            if want and got != want:
                fail(f"{where}: registers {got} but {mod.name}/mod.info says "
                     f"{want}")
                problems += 1
            idlit = LITERAL.match(idexpr)
            if idlit and idlit.group(1) != mod.name:
                fail(f"{where}: registers id \"{idlit.group(1)}\" from inside "
                     f"{mod.name}'s tree")
                problems += 1

    # -- 3. unregistered mods (advisory) -----------------------------------
    for mod in mods:
        if mod.name not in registered:
            advisories.append(mod.name)

    if advisories:
        print("advisory: never call registerMod, so the HELLO handshake cannot "
              "see them: " + ", ".join(advisories))
        print("          (adding the call is an owner decision - it changes "
              "boot behaviour; see TODO.md)")

    n = len(versions)
    if problems == 0:
        print(f"versions: {n} mods at {suite}, both mod.info copies identical, "
              f"{len(registered)} registrations match. Clean.")
        return 0
    print(f"versions: {problems} problem(s).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
