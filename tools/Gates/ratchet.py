#!/usr/bin/env python3
# ratchet - the downward-only per-mod ceiling, once.
#
# WHY THIS EXISTS (2026-08-20). check-pcall, check-helpers and check-network
# each hand-rolled the same three operations: load a baseline JSON, compare the
# current per-mod counts against it, and rewrite it under --update. pcall and
# helpers used a byte-identical file shape - {"_comment": ..., "mods": {...}} -
# and identical creep arithmetic. That is a duplicated MECHANISM in the very
# tooling that fails the build for duplicated mechanisms, and check-helpers.py
# would have said so years ago if it scanned Python.
#
# WHAT IS SHARED AND WHAT IS NOT. The ratchet is: a number per mod, lower is
# free, higher fails, --update rewrites with the reason recorded in the file.
# That is mechanism, and it lives here. What each gate COUNTS, what it prints
# when a mod creeps, and what its numbers mean are policy and stay at the call
# site - a pcall guard and a copied helper creep for different reasons and the
# operator needs to be told different things. This module never prints a verdict
# it does not own.
#
# check-network keeps its own scalar baseline deliberately: it ratchets ONE
# number (unadopted dispatchers suite-wide), not a per-mod map, and forcing that
# into a per-mod shape would have meant inventing a mod key that means nothing.
# Its load/save go through the primitives below; its comparison stays its own.

import json
import os


def load(path, key="mods"):
    """Per-mod baseline as a dict, or {} when the file has never been written.

    A missing baseline is NOT an error: a new gate legitimately starts without
    one, and every count then reads as "no ceiling declared" rather than as a
    failure. The first --update is what establishes the floor.
    """
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f).get(key) or {}


def load_scalar(path, key):
    """One number, or None when unset. None means "no ceiling declared yet"
    and must never be confused with 0, which is a ceiling of zero."""
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f).get(key)


def save(path, comment, payload, key="mods"):
    """Rewrite a baseline. The comment is REQUIRED and goes in the file.

    key="mods" wraps payload under that key (the per-mod gates); key=None
    merges it at the top level, for a gate whose baseline is not a per-mod map.

    Raising a ceiling is the deliberate act CLAUDE.md names, and the reason has
    to survive in the place the next person opens - not in a commit message
    nobody reads at the moment they are wondering why the number moved.
    """
    if not comment:
        raise ValueError("a baseline rewrite must carry its reason")
    body = {"_comment": comment}
    if key is None:
        # Merge at the TOP LEVEL. Not cosmetic: check-network reads
        # "legacy_dispatchers" back from the root, so wrapping it under a key
        # makes the next load see no ceiling at all - which reads as "no
        # baseline declared" and silently RETIRES the ratchet rather than
        # failing. Found exactly that way on the first round-trip after the
        # 2026-08-20 consolidation.
        if not isinstance(payload, dict):
            raise ValueError("a top-level baseline payload must be a dict")
        body.update(payload)
    elif isinstance(payload, dict):
        body[key] = dict(sorted(payload.items()))
    else:
        body[key] = payload
    with open(path, "w", encoding="utf-8") as f:
        json.dump(body, f, indent=2)
        f.write("\n")


def creep(counts, baseline):
    """Mods that grew, as ["mod: was -> now (+n)"], sorted.

    A mod absent from the baseline is UNCONSTRAINED, not zero-ceilinged: gates
    gain coverage (a new mod, a scanner that learned to see more) and treating
    silence as zero would fail the build for work nobody did.
    """
    out = []
    for mod in sorted(set(counts) | set(baseline)):
        now, was = counts.get(mod, 0), baseline.get(mod)
        if was is not None and now > was:
            out.append(f"{mod}: {was} -> {now} (+{now - was})")
    return out
