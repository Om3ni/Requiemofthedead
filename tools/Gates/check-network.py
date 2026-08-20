#!/usr/bin/env python3
# check-network - one token, one executable intake.
#
# WHY THIS EXISTS (2026-08-20): the pcall refactor closed with a linter that
# makes its rules unforgettable. The networking effort needs the same, and it
# needs it FIRST, because the two failures the 2026-08-20 survey found are both
# invisible to review and both were live on a production server:
#
#   * RFTDCore was adopted by RDNet (default-deny) while RDTripwire kept a
#     second executable listener on the same token. Every tripwireReport and
#     lifecycleReport was written to the forensic archive as RD.NET_REJECT and
#     then executed anyway by the other listener. Two live paths, and the one
#     stream an operator would search for intrusion was filling with false
#     rejections of legitimate traffic.
#   * RFTDHusbandry had its command surface split across HBCommands.lua and
#     HBSexCheck_Server.lua - two executable intakes on one token, so no single
#     file showed the whole trust boundary.
#
# Neither is visible in a diff. Both are trivially visible to a scanner. That
# asymmetry is the whole argument for this file.
#
# THE RULES
#
#   1. NO SECOND INTAKE ON AN ADOPTED TOKEN. Once a token appears in an
#      RDNet.adopt/register call, RDNet is its only executable dispatcher. A
#      raw OnClientCommand listener filtering on that token is the forbidden
#      "rejected but executed" state.
#
#   2. ONE EXECUTABLE INTAKE PER TOKEN. Even before adoption, a family token
#      gets exactly one dispatcher. Two files answering one token means no
#      single place states the trust boundary.
#
#   3. NO DUPLICATE REGISTRATION. RDNet.register overwrites silently
#      (RDNet.lua:76-92), so load order would pick the winner. Any (token,
#      command) registered twice in source is a configuration error.
#
#   4. LEGACY RATCHET. tools/network-baseline.json holds the number of
#      unadopted executable dispatchers. Fewer is always accepted and locks in
#      on --update; more fails. Adoption is meant to be a one-way street.
#
# OBSERVERS ARE NOT DISPATCHERS. A listener that watches traffic without
# answering it - RDGuardian's family-wide sensor, RCDamageAudit and RCJanitor on
# vanilla's "vehicle" token - is legitimate and exempt, but only by name in
# network-config.json with a reason. That file is the record of what "observe
# only" was allowed to mean, same role pcall-safe.json plays for "cannot throw".
#
# WHAT THIS CANNOT DO. It reads source, not behaviour. It cannot prove an
# allowlisted observer stays observe-only, cannot see a token assembled at
# runtime, and cannot judge whether a handler validates its input. Those need
# reading and a Mosaic session. This closes the structural half.
#
# Usage:
#   python tools\check-network.py            check; non-zero exit on violation
#   python tools\check-network.py --list     every intake and registration
#   python tools\check-network.py --update   accept current counts as baseline

import argparse
import json
import os
import re
import sys

import ratchet
from luascan import (REPO, blank_comments_and_strings, lua_files, mod_of,
                     read, rel as relpath)

# Data lives beside the tool that owns it. Derived from THIS FILE rather
# than from REPO + "tools", so moving the gate does not silently move
# where it looks for its own baseline.
HERE = os.path.dirname(os.path.abspath(__file__))

# Written into the baseline on every --update; see ratchet.save.
RATCHET_REASON = ("Unadopted executable dispatchers. Lower is free; raising it means a "
    "token grew a second intake or a new legacy dispatcher appeared - "
    "neither is accepted without a deliberate --update.")
CONFIG_FILE = os.path.join(HERE, "network-config.json")
BASE_FILE = os.path.join(HERE, "network-baseline.json")

# Events.OnClientCommand.Add( - the inbound intake.
INTAKE = re.compile(r"\bEvents\s*\.\s*OnClientCommand\s*\.\s*Add\s*\(")

# RDNet.adopt("token") / RDNet.register("token", "command", ...)
ADOPT = re.compile(r"\bRDNet\s*\.\s*adopt\s*\(\s*([^)]+?)\s*\)")
REGISTER = re.compile(r"\bRDNet\s*\.\s*register\s*\(\s*([^,]+?)\s*,\s*([^,]+?)\s*,")

# Constants that resolve a token name:  X.MODULE = "literal"  /  local MODULE = "literal"
QUALIFIED_CONST = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*MODULE\s*=\s*\"([^\"]+)\"")
LOCAL_CONST = re.compile(r"\blocal\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\"([^\"]+)\"")
# local M = RCShared.MODULE - a token reached through one alias. Reclamation's
# whole dispatcher hangs off this shape, so not chasing it means not seeing the
# largest legacy surface in the family.
LOCAL_ALIAS = re.compile(r"\blocal\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*\.MODULE)\b")

# How a listener says which token it serves. All four shapes appear in the tree.
FILTER_LITERAL = re.compile(r"\bmodule\s*(?:~=|==)\s*\"([^\"]+)\"")
FILTER_IDENT = re.compile(r"\bmodule\s*(?:~=|==)\s*([A-Za-z_][A-Za-z0-9_.]*)")
FILTER_ACCEPTS = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*acceptsModule\s*\(")


def literal_or_none(expr):
    """A quoted literal argument, unquoted; otherwise None."""
    expr = expr.strip()
    if len(expr) >= 2 and expr[0] == expr[-1] and expr[0] in "\"'":
        return expr[1:-1]
    return None


def build_constant_map():
    """token-bearing identifier -> literal, gathered from the whole tree.

    `DFCore.MODULE = "RFTDDragonfly"` teaches every file that filters on
    DFCore.MODULE which token it means. Resolving these from source rather than
    a hand-written table means a new mod needs no edit here.
    """
    qualified, ambiguous = {}, set()
    for path in lua_files():
        text = blank_comments_and_strings(read(path), keep_strings=True)
        for owner, token in QUALIFIED_CONST.findall(text):
            key = owner + ".MODULE"
            if key in qualified and qualified[key] != token:
                ambiguous.add(key)
            qualified[key] = token
    for key in ambiguous:
        qualified.pop(key, None)
    return qualified


def file_local_consts(text, consts):
    """local-name -> token, for one file.

    Two shapes: a direct literal (`local MODULE = "RFTDReaper"`) and an alias
    onto a shared constant (`local M = RCShared.MODULE`). A name bound twice to
    different values is dropped - an unprovable binding is exactly what the
    ambiguity rules exist to refuse.
    """
    out = {}

    def bind(name, value):
        if name in out and out[name] != value:
            out[name] = None
        else:
            out.setdefault(name, value)

    for name, value in LOCAL_CONST.findall(text):
        bind(name, value)
    for name, ref in LOCAL_ALIAS.findall(text):
        if ref in consts:
            bind(name, consts[ref])
    return {k: v for k, v in out.items() if v}


def tokens_in_file(text, consts):
    """Every wire token this file's listeners filter on.

    Whole-file resolution on purpose: a named handler
    (`Events.OnClientCommand.Add(onClientCommand)`) puts the filter in a
    function body far from the Add() call, and balancing function/end to find
    it would be a parser. Files hold one dispatcher in practice; a file that
    resolves to several tokens is reported as ambiguous rather than guessed.
    """
    local = file_local_consts(text, consts)
    found = set()
    for token in FILTER_LITERAL.findall(text):
        found.add(token)
    for ident in FILTER_IDENT.findall(text):
        if ident in local:
            found.add(local[ident])
        elif ident in consts:
            found.add(consts[ident])
        elif "." in ident and ident.split(".")[0] + ".MODULE" in consts:
            found.add(consts[ident.split(".")[0] + ".MODULE"])
    # RQCommon.acceptsModule(module) is `m == RQCommon.MODULE` behind a helper.
    for owner in FILTER_ACCEPTS.findall(text):
        key = owner + ".MODULE"
        if key in consts:
            found.add(consts[key])
    return found


def scan():
    consts = build_constant_map()
    intakes = []        # (relpath, mod, line, tokens)
    registrations = []  # (relpath, line, token, command)
    adopted = {}        # token -> [relpath]

    for path in lua_files():
        # Comments blanked, strings KEPT: a token is a string literal, so the
        # default view would blind every literal rule in this file.
        text = blank_comments_and_strings(read(path), keep_strings=True)
        rp, mod = relpath(path), mod_of(path)
        local = file_local_consts(text, consts)

        def resolve(expr):
            lit = literal_or_none(expr)
            if lit:
                return lit
            e = expr.strip()
            if e in local:
                return local[e]
            if e in consts:
                return consts[e]
            if "." in e and e.split(".")[0] + ".MODULE" in consts:
                return consts[e.split(".")[0] + ".MODULE"]
            return None

        for m in ADOPT.finditer(text):
            token = resolve(m.group(1))
            if token:
                adopted.setdefault(token, []).append(rp)
        for m in REGISTER.finditer(text):
            token, command = resolve(m.group(1)), resolve(m.group(2))
            if token:
                adopted.setdefault(token, []).append(rp)
                line = text.count("\n", 0, m.start()) + 1
                registrations.append((rp, line, token, command or "?"))

        for m in INTAKE.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            intakes.append((rp, mod, line, sorted(tokens_in_file(text, consts))))

    return intakes, registrations, adopted


def main():
    ap = argparse.ArgumentParser(description="wire intake discipline")
    ap.add_argument("--update", action="store_true", help="rewrite the legacy baseline")
    ap.add_argument("--list", action="store_true", help="print every intake and registration")
    args = ap.parse_args()

    config = {"observers": {}, "rdnet_dispatcher": [], "annotate": {}}
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, encoding="utf-8") as f:
            doc = json.load(f)
        for k in config:
            config[k] = doc.get(k, config[k])
    observers = {k: v for k, v in config["observers"].items() if not k.startswith("_")}
    rdnet_files = set(config["rdnet_dispatcher"])
    annotate = {k: v for k, v in config["annotate"].items() if not k.startswith("_")}

    baseline = ratchet.load_scalar(BASE_FILE, "legacy_dispatchers")

    intakes, registrations, adopted = scan()

    violations, notes = [], []

    # Executable intakes only: observers and RDNet's own dispatcher are not.
    executable = []
    for rp, mod, line, tokens in intakes:
        if rp in observers or rp in rdnet_files:
            continue
        if rp in annotate:
            tokens = annotate[rp]
        executable.append((rp, mod, line, tokens))

    if args.list:
        print("-- executable intakes --")
        for rp, mod, line, tokens in executable:
            print(f"{rp}:{line}  {', '.join(tokens) or '(token unresolved)'}")
        print("\n-- observers (allowlisted) --")
        for rp, why in sorted(observers.items()):
            print(f"{rp}  {why}")
        print("\n-- RDNet registrations --")
        for rp, line, token, command in sorted(registrations):
            print(f"{rp}:{line}  {token}.{command}")
        print(f"\n{len(executable)} executable intake(s), {len(observers)} observer(s), "
              f"{len(registrations)} registration(s), {len(adopted)} adopted token(s)")
        return 0

    # Rule 1 - an adopted token may not carry a second executable intake.
    for rp, mod, line, tokens in executable:
        for token in tokens:
            if token in adopted:
                violations.append(
                    f"{rp}:{line}  second executable intake on ADOPTED token '{token}' "
                    f"(RDNet owns it: {', '.join(sorted(set(adopted[token])))}) - "
                    f"register the commands with RDNet and delete this listener")

    # Rule 2 - one executable intake per token.
    by_token = {}
    for rp, mod, line, tokens in executable:
        for token in tokens:
            by_token.setdefault(token, []).append(f"{rp}:{line}")
    for token, sites in sorted(by_token.items()):
        if len(sites) > 1:
            violations.append(
                f"token '{token}' has {len(sites)} executable intakes "
                f"({'; '.join(sites)}) - one token, one dispatcher")

    # Rule 3 - a (token, command) pair may be registered once.
    seen = {}
    for rp, line, token, command in registrations:
        key = (token, command)
        if key in seen:
            violations.append(
                f"{rp}:{line}  duplicate registration of '{token}.{command}' "
                f"(also {seen[key]}) - RDNet.register overwrites silently, so load "
                f"order would choose the handler")
        else:
            seen[key] = f"{rp}:{line}"

    # An intake whose token could not be resolved is not a pass - it is a blind
    # spot, and the rules above skipped it. Annotate it in network-config.json.
    for rp, mod, line, tokens in executable:
        if not tokens:
            notes.append(
                f"{rp}:{line}  token unresolved - the rules above could not be applied. "
                f"Add it to \"annotate\" in network-config.json (or to \"observers\" "
                f"with a reason if it never executes a family command)")

    legacy = sorted({t for t in by_token if t not in adopted})

    if args.update:
        # SCALAR, not per-mod: this gate ratchets one suite-wide number
        # (unadopted dispatchers). Forcing it into ratchet's per-mod shape
        # would mean inventing a mod key that means nothing - so it shares
        # the file primitives and keeps its own comparison, one line below.
        # key=None: this baseline is read back from the ROOT, not from a
        # per-mod map. See ratchet.save on why wrapping it would silently
        # retire the ratchet instead of failing.
        ratchet.save(BASE_FILE, RATCHET_REASON,
                     {"legacy_dispatchers": len(legacy), "tokens": legacy},
                     key=None)
        print(f"baseline updated: {len(legacy)} unadopted dispatcher(s)")
        return 0

    crept = baseline is not None and len(legacy) > baseline

    for v in violations:
        print("VIOLATION  " + v)
    for n in notes:
        print("UNRESOLVED  " + n)
    if crept:
        print(f"\nCREEP      unadopted dispatchers {baseline} -> {len(legacy)} "
              f"({', '.join(legacy)})")
        print("           adoption is one-way; migrate the token, then --update")

    if violations or notes or crept:
        print(f"\nFAIL  {len(violations)} violation(s), {len(notes)} unresolved, "
              f"{len(legacy)} unadopted dispatcher(s)")
        return 1

    print(f"network check clean - {len(executable)} executable intake(s), one per token; "
          f"{len(adopted)} adopted token(s); {len(legacy)} still on a legacy dispatcher")
    if legacy:
        print("           legacy tokens (migration pending): " + ", ".join(legacy))
    return 0


if __name__ == "__main__":
    sys.exit(main())
