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
#   5. PROBE GUARDS DECLARE THEMSELVES (2026-08-20). Rule 1 asks "can this
#      method's BODY throw?" - which is the wrong question in a file whose job
#      is to find out whether a method EXISTS. Calling a method that is not on
#      the class is `attempt to call a nil value`: Lua lane, real throw, and the
#      exact signal a capability probe is built to catch. A guard marked
#      `pcall-probe: <reason>` in its comment is therefore exempt from rule 1
#      and from rule 4's width requirement - but NOT from the ratchet, so it
#      stays counted and visible.
#
#      This replaces a whole-file exemption (luascan.EXEMPT_BASENAMES) that
#      covered HBDebugPanel, DFItemProbes and HBAPIProbe. That exemption was
#      true of the discovery helpers and false of everything else in the same
#      files, and it is how `setDirtyness` (a typo) and `setWetness` (wrong
#      class) reached a live server. Turning it off surfaced ten guards on
#      verified-safe calls and one undocumented broad guard, none of which was a
#      probe. Per-guard is the granularity the claim was always at.
#
#   4. A BROAD GUARD MUST SAY WHY (Phase Three close, 2026-08-20). A guard whose
#      closure spans BROAD_THRESHOLD or more DISTINCT method calls is the shape
#      that blanket containment regrows from: unrelated target families under one
#      fallback, where any one failing verdict hides the others. It is not banned
#      - RCSpawn's conditioning pass is broad and legitimate, one part of an
#      independent batch with genuinely nil-able chains - but like an opaque
#      guard it must carry its reason as a comment, or it fails the build.
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
import ratchet
from luascan import (REPO, blank_comments_and_strings, lua_files, mod_of,
                     rel as relpath)
# Data lives beside the tool that owns it. Derived from THIS FILE rather
# than from REPO + "tools", so moving the gate does not silently move
# where it looks for its own baseline.
HERE = os.path.dirname(os.path.abspath(__file__))

# Written into the baseline file on every --update, so the ceiling always
# carries its own justification where the next person will open it.
RATCHET_REASON = ("Per-mod pcall ceiling. Lower is free; raising it is a deliberate act - "
    "document the guard's reason in the code first. RAISED 2026-08-20 "
    "(Dragonfly 7->10, RFTDHusbandry 1->25): luascan.EXEMPT_BASENAMES was "
    "retired, so DFItemProbes, HBDebugPanel and HBAPIProbe are scanned for "
    "the first time - this admits guards the tooling could not previously "
    "see, not new ones. 13 inert guards found by the first scan were deleted "
    "the same day; what is counted here passed every rule.")
SAFE_FILE = os.path.join(HERE, "pcall-safe.json")
BASE_FILE = os.path.join(HERE, "pcall-baseline.json")

# A real method call: the name is followed by '(' . The ',' that used to be
# accepted here was meant to catch the function-REFERENCE form,
# `pcall(obj.method, obj)` - but it also swallowed every table constant passed
# as an argument, so `pcall(sendServerCommand, DFCore.MODULE, ...)` produced a
# phantom target named MODULE. A phantom is neither safe-listed nor stdlib, so
# it counted as "unjustified" and SUPPRESSED rule 1 on a guard whose only real
# call was already certified. The reference form is now read from the first
# argument only, where it actually lives - see callee_of().
METHOD_CALL = re.compile(r"[:.]([A-Za-z_][A-Za-z0-9_]*)\s*\(")

# `pcall(f, ...)` / `pcall(obj.method, ...)` - the callee is the FIRST argument,
# and only there. Trailing '(' is excluded: that is a call, caught above.
CALLEE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*(?:[.:][A-Za-z_][A-Za-z0-9_]*)*)\s*(?:,|$)")

# Receiver-bearing calls, so a handle's methods can be resolved to a real type.
RECV_CALL = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(")

# `local f = getFileWriter(...)` - binds a name to an engine factory.
HANDLE_BIND = re.compile(r"\blocal\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(")
# Any other assignment to a bare local; used to DROP an ambiguous name.
ANY_BIND = re.compile(r"\blocal\s+([A-Za-z_][A-Za-z0-9_]*)\s*=")

# Deterministic Lua standard library. These are NOT "safe" in the engine sense -
# math.floor(nil) throws, and that is exactly the LSTours defect a blanket hid.
# They are TRANSPARENT: a stdlib call can neither justify a guard nor launder
# one. Phase One's rule is that invalid arguments here are programming or input
# validation errors, so the fix is to validate the input, never to wrap the call.
# Before this, adding one string.format to a body of verified-safe calls was
# enough to make rule 1 fall silent.
# A bare global call - `writeLog(...)` - carries NO '.' or ':', so METHOD_CALL
# is blind to it. Rule 1 therefore never certifies a guard whose body contains
# an unresolved one: the guard's real subject may be invisible to every rule.
#
# MEASURED 2026-08-19, because this rule was suspected of over-shielding. Of the
# 26 distinct bare names inside guarded bodies today, TWENTY-FOUR are our own
# Lua locals - fellAndContinue, validateSnapshot, applyIdentity, basePerform and
# friends - and Lua is a lane that genuinely throws, so refusing to certify
# those is exactly right. Only getPlayer and getOnlinePlayers are engine
# globals, and both sit in guards that are non-certifiable on other grounds
# anyway. The rule is not over-shielding anything; the original worry named
# LMPersist's writeLog guards, and those were read and DELETED
# (LMPersist.lua:135 - "writeLog cannot raise into Lua").
#
# Names verified not to throw are transparent here. A handle factory qualifies
# because its own body is certified in pcall-safe.json, and so does anything
# listed under safe."globals" - which this consults, so that list means what it
# says instead of silently doing nothing.
BARE_CALL = re.compile(r"(?<![A-Za-z0-9_.:])([A-Za-z_][A-Za-z0-9_]*)\s*\(")
LUA_KEYWORDS = {
    "if", "elseif", "while", "until", "return", "and", "or", "not", "for", "in",
    "do", "then", "else", "end", "function", "local", "repeat", "break",
}
TRANSPARENT_GLOBALS = {
    "tostring", "tonumber", "type", "pairs", "ipairs", "select",
    "rawget", "rawset", "unpack", "assert", "pcall",
}

STDLIB = {
    "format", "rep", "sub", "gsub", "gmatch", "match", "find", "byte", "char",
    "lower", "upper", "reverse", "len",
    "floor", "ceil", "abs", "min", "max", "sqrt", "random", "fmod", "modf",
    "concat", "insert", "remove", "sort", "unpack",
    "date", "time", "clock", "difftime",
}


def callee_of(body):
    """The function reference in `pcall(f, ...)`, if the first argument is one.

    Returns the LAST name segment, matching how the safe-list is keyed:
    `pcall(RDNet.broadcast, x)` -> "broadcast". A closure - `pcall(function()`
    - yields nothing, because `function` is a keyword, not a reference.
    """
    m = CALLEE.match(body)
    if not m:
        return None
    name = m.group(1).replace(":", ".").split(".")[-1]
    return None if name in LUA_KEYWORDS else name


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

# Rule 5: the per-guard probe directive. Requires text after the colon - a bare
# marker is a claim with no reason behind it, which is the thing rule 3 exists to
# refuse.
PROBE_DIRECTIVE = re.compile(r"pcall-probe:\s*\S")

# Rule 4: distinct method calls at or above this count make a guard "broad".
# Chosen above every current survivor except RCSpawn's conditioning pass (which
# is documented); a future guard this wide without a reason is the blanket shape
# Phase One spent 33 slices deleting.
BROAD_THRESHOLD = 8


def handle_types(clean, handles):
    """Map local variable name -> engine factory, for names bound unambiguously.

    A name also assigned from anything else in the same file is dropped: reuse
    makes the receiver unprovable, and an unprovable receiver is exactly the
    shared-name problem this exists to avoid.
    """
    bound, ambiguous = {}, set()
    for var, factory in HANDLE_BIND.findall(clean):
        if factory in handles:
            if var in bound and bound[var] != factory:
                ambiguous.add(var)
            bound[var] = factory
        elif var in bound:
            ambiguous.add(var)
        else:
            ambiguous.add(var)
    return {v: f for v, f in bound.items() if v not in ambiguous}


def scan_file(path, safe, handles, safe_globals=frozenset()):
    """Yield (line_no, targets, verdict, documented) per pcall site.

    verdict: None (keep), "safe" or "stdlib" (removable).
    """
    with open(path, "rb") as f:
        text = f.read().decode("utf-8", "replace")
    clean = blank_comments_and_strings(text)
    # Comments are blanked in `clean`, so the reason is read off the RAW text.
    raw_lines = text.split(chr(10))
    hvars = handle_types(clean, handles)
    for m in re.finditer(r"\bpcall\s*\(", clean):
        end = pcall_extent(clean, m.end() - 1)
        body = clean[m.end():end]
        targets = METHOD_CALL.findall(body)
        # pcall(obj.method, obj) leaves 'method' via the ',' branch; the closure
        # form leaves every ':method(' inside it. Either way, targets is what
        # this guard is actually protecting.
        targets = [t for t in targets if t != "pcall"]
        callee = callee_of(body)
        if callee:
            targets.append(callee)

        # Resolve receiver-typed calls. A handle method VERIFIED TO THROW pins
        # the guard immediately - it is load-bearing, whatever shares the room.
        typed_total, throws_here = set(), False
        for recv, meth in RECV_CALL.findall(body):
            spec = handles.get(hvars.get(recv) or "")
            if not spec:
                continue
            if meth in spec.get("throws", ()):
                throws_here = True
            elif meth in spec.get("total", ()):
                typed_total.add(meth)

        # What remains once transparent and certified calls are set aside.
        unjustified = [t for t in targets
                       if t not in safe and t not in STDLIB and t not in typed_total]

        # An unresolvable bare global means this guard's real subject may be
        # invisible to every rule above. Never certify it removable.
        opaque_call = any(
            n not in LUA_KEYWORDS and n not in TRANSPARENT_GLOBALS
            and n not in STDLIB and n not in handles and n not in safe_globals
            for n in BARE_CALL.findall(body))

        verdict = None
        if not throws_here and not opaque_call and targets and not unjustified:
            verdict = "stdlib" if all(t in STDLIB for t in targets) else "safe"
        line = text.count(chr(10), 0, m.start()) + 1
        # A reason counts if it sits just above, or trails the guard itself.
        above = raw_lines[max(0, line - 1 - COMMENT_LOOKBACK):line - 1]
        window = above + [raw_lines[line - 1]]
        documented = any("--" in t for t in above) or "--" in raw_lines[line - 1]
        broad = len(set(targets)) >= BROAD_THRESHOLD
        # Rule 5. A declared probe is guarding the method's EXISTENCE, which no
        # reading of its body can rule out, so rule 1 has nothing to say about
        # it - and the declaration itself is the reason rules 3 and 4 want.
        if any(PROBE_DIRECTIVE.search(t) for t in window):
            verdict, documented, broad = None, True, False
        yield line, targets, verdict, documented, broad


def main():
    ap = argparse.ArgumentParser(description="pcall debt guard")
    ap.add_argument("--update", action="store_true", help="rewrite baselines to current counts")
    ap.add_argument("--list", action="store_true", help="print every pcall site and its targets")
    args = ap.parse_args()

    safe, handles, safe_globals = set(), {}, set()
    if os.path.exists(SAFE_FILE):
        with open(SAFE_FILE, encoding="utf-8") as f:
            doc = json.load(f)
        for methods in doc["safe"].values():
            safe.update(methods)
        # "globals" is keyed like a class but its entries are BARE names, so it
        # also feeds the bare-call exemption. Kept as its own set rather than
        # reusing `safe`: a class method named getName must not exempt a bare
        # getName() that happens to share the spelling.
        safe_globals = set(doc["safe"].get("globals", []))
        handles = {k: v for k, v in doc.get("handles", {}).items()
                   if not k.startswith("_")}

    baseline = ratchet.load(BASE_FILE)

    counts, violations, undocumented = {}, [], []
    for path in lua_files():
        mod = mod_of(path)
        rel = relpath(path)
        for line, targets, verdict, documented, broad in scan_file(path, safe, handles, safe_globals):
            counts[mod] = counts.get(mod, 0) + 1
            if args.list:
                print(f"{rel}:{line}  {','.join(targets) or '(no method call)'}")
            if verdict == "safe":
                violations.append(
                    f"{rel}:{line}  guards only calls that cannot throw "
                    f"({', '.join(sorted(set(targets)))}) - call directly")
            elif verdict == "stdlib":
                violations.append(
                    f"{rel}:{line}  guards only deterministic Lua stdlib "
                    f"({', '.join(sorted(set(targets)))}) - validate the input instead")
            elif not targets and not documented:
                undocumented.append(
                    f"{rel}:{line}  opaque guard - no engine call rule 1 can see, "
                    f"and no reason given: say why, or delete it")
            elif broad and not documented:
                undocumented.append(
                    f"{rel}:{line}  broad guard - {len(set(targets))} distinct calls "
                    f"under one fallback, and no reason given: say why, or narrow it")

    crept = ratchet.creep(counts, baseline)

    # --list is a pure inventory: sites and nothing else. It used to fall through
    # into the violation report below, so `--list | grep -c <mod>` counted every
    # flagged site twice and made a clean mod look like it had grown.
    if args.list:
        print(f"\n{sum(counts.values())} pcall site(s) across {len(counts)} mods")
        return 0

    if args.update:
        # The reason travels WITH the rewrite - ratchet.save refuses a
        # baseline change that does not carry one.
        ratchet.save(BASE_FILE, RATCHET_REASON, counts)
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
