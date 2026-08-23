#!/usr/bin/env python3
# check-kahlua - the Lua 5.1 features Kahlua does not have.
#
# WHY THIS EXISTS (2026-08-23), and why no other gate can do its job.
#
# B42 runs Kahlua, which is a SUBSET of Lua 5.1 (CLAUDE.md section 3). Every
# item in that section is something real Lua 5.1 HAS and Kahlua does not - and
# that is precisely what makes the divergence invisible here:
#
#   check-lua  is luacheck: syntax only. `next(t)` is perfectly good syntax.
#   run-tests  runs REAL Lua 5.1, deliberately - a 5.3+ interpreter would give
#              confident wrong answers about RDJson.fmtNum's integer handling
#              (run-tests.bat's own header). So the global EXISTS in the test
#              interpreter, every assertion over it passes, and the fixture is
#              green.
#   the rest   are about guards, helpers and wire tokens.
#
# So a violation passes every gate and throws on a live server. There is no
# arrangement of the previous five that sees it. That is not a gap anyone left;
# it falls out of run-tests being correct.
#
# THE CASE THAT PROMPTED IT. RDVarDefs.isPermanent shipped as
# `next(def.revokers) == nil` - the test its own fixture called "the test every
# consumer asks" - under 78 green assertions. It was caught by the maintainer
# reading the file. Before this, the entire enforcement mechanism was nine
# separate source comments warning against the same thing, which is the
# version-lockstep problem again: a rule everybody knows, written down nowhere a
# machine reads.
#
# ZERO TOLERANCE, NO BASELINE, and that is the whole design. check-pcall and
# check-helpers ratchet because their subject is a judgement call with a
# legitimate residue. This one is not: there is no correct use of a global that
# does not exist. A baseline file here would say "some of these are fine", and
# none of them are. The suite was already clean when this was written, so it
# starts at zero and stays there.
#
# WHAT IT DOES NOT CHECK, stated so nobody reads green as "section 3 is
# enforced":
#
#   * THE ~200-LOCAL CEILING. More than about 200 locals in one function kills
#     the whole file silently. Detecting it needs real scoping - counting
#     `local` per function body, following nested closures - and a crude version
#     would produce false positives on the suite's larger UI files, get muted,
#     and then be worth nothing. Left undone on purpose rather than done badly.
#   * BASELIB'S GLOBAL SET. "Check BaseLib's registered globals before using any
#     stdlib global" needs the registered list read out of the Kahlua source and
#     kept in step with it. That is a decompile job of its own; until someone
#     does it, a denylist here would be guesswork wearing a gate's clothes.
#
# Usage:
#   python tools\Gates\check-kahlua.py          violations only
#   python tools\Gates\check-kahlua.py --audit  also show every near-miss and
#                                               why it was allowed
#
# Exit 0 clean, 1 on any violation.

import argparse
import re
import sys

from luascan import blank_comments_and_strings, lua_files, mod_of, read, rel

# ---------------------------------------------------------------------------
# CHECK 1 - the global `next`
#
# Kahlua's BaseLib registers print/tostring/type/pairs/ipairs and the bytecode
# loader, and no `next`. `next(t) == nil` therefore throws "Object tried to call
# nil" on a live server. pairs() is the replacement and reads no worse:
#
#     for _ in pairs(t) do return false end
#     return true
#
# The lookbehind is what keeps the real uses out. Three shapes are legitimate
# and all of them have something in front of the name:
#
#     it:next()          a Java iterator, an exposed METHOD, nothing to do with
#                        the Lua global (RCFleet, RCParking, RCLoadedVehicles,
#                        RCVehicleTab all walk vehicle iterators this way)
#     LSRoute.next()     our own function that happens to be called next
#     function X.next()  its definition
#
# A bare `next(` has no qualifier, which is exactly the thing that resolves
# against the missing global.
# ---------------------------------------------------------------------------
NEXT_CALL = re.compile(r"(?<![A-Za-z0-9_.:])next\s*\(")

# Any `next` at all, qualified or not - only used by --audit, so the exclusions
# can be inspected rather than trusted.
NEXT_ANY = re.compile(r"[A-Za-z0-9_.:]*next\s*\(")

# ---------------------------------------------------------------------------
# CHECK 2 - iterating a Java collection view
#
# An exposed method returning a java.util collection hands Lua a Java object,
# not a Lua table: pairs()/ipairs() cannot walk it. The set below is CLOSED and
# every entry carries the decompile read that put it there, on the same rule as
# pcall-safe.json - adding one is a decompile job, not a guess.
#
# Kept deliberately small. A speculative list would fire on methods that DO
# return something iterable and teach everyone to ignore the gate.
# ---------------------------------------------------------------------------
COLLECTION_METHODS = {
    # InventoryItem.java:2661 - `public Set<ItemTag> getTags()`. CLAUDE.md
    # sect. 3 names this one specifically: resolve the tag and use hasTag.
    "getTags": "InventoryItem.java:2661 returns Set<ItemTag> - use hasTag(tag)",
}

ITER_CALL = re.compile(r"\b(i?pairs)\s*\(([^()]*?[:.](" + "|".join(COLLECTION_METHODS) + r")\s*\([^()]*\))")


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def source_line(text, pos):
    start = text.rfind("\n", 0, pos) + 1
    end = text.find("\n", pos)
    end = len(text) if end == -1 else end
    return text[start:end].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audit", action="store_true",
                    help="also list every qualified `next` and why it is allowed")
    args = ap.parse_args()

    violations, allowed, scanned = [], [], 0

    for path in lua_files():
        scanned += 1
        raw = read(path)
        # Comments and strings blanked: nine files in this suite carry a comment
        # WARNING against next(), and a scanner that matched prose would report
        # every one of them as the bug they exist to prevent.
        code = blank_comments_and_strings(raw)

        for m in NEXT_CALL.finditer(code):
            violations.append((path, line_of(code, m.start()),
                               "bare next(): Kahlua registers no global `next` - "
                               "use `for _ in pairs(t) do ... end`",
                               source_line(raw, m.start())))

        if args.audit:
            for m in NEXT_ANY.finditer(code):
                token = m.group(0)
                if not NEXT_CALL.match(code, m.start()):
                    allowed.append((path, line_of(code, m.start()), token.strip()))

        for m in ITER_CALL.finditer(code):
            method = m.group(3)
            violations.append((path, line_of(code, m.start()),
                               "%s() over %s(): %s"
                               % (m.group(1), method, COLLECTION_METHODS[method]),
                               source_line(raw, m.start())))

    if args.audit and allowed:
        print("QUALIFIED - a method call or our own function, not the missing global:")
        for path, line, token in allowed:
            print("  %s:%d  %s" % (rel(path), line, token))
        print()

    if not violations:
        print("%d file(s) scanned, no Kahlua-subset violations." % scanned)
        print("Checks bare next() and pairs() over a Java collection. It does NOT "
              "check the ~200-local ceiling or BaseLib's global set - see the header.")
        return 0

    by_mod = {}
    for v in violations:
        by_mod.setdefault(mod_of(v[0]), []).append(v)

    for mod in sorted(by_mod):
        print(mod)
        for path, line, why, src in by_mod[mod]:
            print("  %s:%d" % (rel(path), line))
            print("      %s" % why)
            print("      | %s" % src)
    print()
    print("FAIL  %d violation(s) in %d mod(s). These pass check-lua and pass "
          "run-tests" % (len(violations), len(by_mod)))
    print("      (real Lua 5.1 has them); they throw on a live server.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
