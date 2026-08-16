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

# Files whose whole job is probing engine internals. Guards and throwaway
# helpers there are the feature, not the debt.
EXEMPT_BASENAMES = {"HBDebugPanel.lua", "DFItemProbes.lua", "HBAPIProbe.lua"}


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


def blank_comments_and_strings(text):
    """Return text with comment and string bodies replaced by spaces (newlines
    kept), so scanning never trips over a ':method(' or an 'end' inside either."""
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


def lua_files():
    for dirpath, _, filenames in os.walk(MODS):
        for name in sorted(filenames):
            if name.lower().endswith(".lua") and name not in EXEMPT_BASENAMES:
                yield os.path.join(dirpath, name)


def mod_of(path):
    return os.path.relpath(path, MODS).split(os.sep)[0]


def rel(path):
    return os.path.relpath(path, REPO).replace(os.sep, "/")


def read(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", "replace")
