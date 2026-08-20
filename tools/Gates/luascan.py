#!/usr/bin/env python3
# luascan - the bits every Lua checker in tools/ needs, in one place.
#
# Extracted 2026-08-15 when check-helpers.py was written. Copying the comment
# blanker into a tool whose whole job is finding copied code would have been a
# poor advertisement, and the repo walk had already drifted once.
#
# Nothing here knows what it is looking FOR - that stays in the checker.

import os
import re
import sys

LONG_OPEN = re.compile(r"\[(=*)\[")


def find_repo(start):
    d = os.path.dirname(os.path.abspath(start))
    while True:
        if os.path.isdir(os.path.join(d, "RequiemOfTheDead", "Contents")) \
                and os.path.isdir(os.path.join(d, "tools")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            sys.exit("cannot locate the repo root above " + os.path.abspath(start))
        d = parent


REPO = find_repo(__file__)
MODS = os.path.join(REPO, "RequiemOfTheDead", "Contents", "mods")


def blank_comments_and_strings(text, keep_strings=False):
    """Return text with comment and string bodies replaced by spaces (newlines
    kept), so scanning never trips over a ':method(' or an 'end' inside either.

    keep_strings=True blanks comments ONLY. check-network needs that view: a wire
    token IS a string literal, so a scanner that blanks strings cannot see the
    thing it is looking for, while one reading raw text would match a token named
    in a comment. Comments blanked, strings kept is the only view that answers
    "which token does this listener actually filter on".
    """
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
            if not keep_strings:
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


def lua_files():
    """Every suite .lua. There used to be two walks here: lua_files filtered an
    EXEMPT_BASENAMES set (probe files whose guards were declared "the feature")
    and all_lua_files did not. The exemption was retired 2026-08-20 - it was
    whole-file where the claim was per-guard, and it is how setDirtyness (a
    typo) and setWetness (wrong class) reached a live server unscanned. Probe
    guards now declare themselves per-site with a `pcall-probe:` comment
    (check-pcall.py rule 5). all_lua_files remains as an alias so no consumer
    has to care which era it was written in."""
    for dirpath, _, filenames in os.walk(MODS):
        for name in sorted(filenames):
            if name.lower().endswith(".lua"):
                yield os.path.join(dirpath, name)


all_lua_files = lua_files


def mod_of(path):
    return os.path.relpath(path, MODS).split(os.sep)[0]


def rel(path):
    return os.path.relpath(path, REPO).replace(os.sep, "/")


def read(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", "replace")
