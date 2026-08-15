#!/usr/bin/env python3
# deploy-workshop.py - stage the payload for the in-game Workshop uploader.
#
# Copies RequiemOfTheDead\ (the whole Workshop item: workshop.txt, preview.png,
# Contents\mods\...) into %USERPROFILE%\Zomboid\Workshop\RequiemOfTheDead,
# stripping every Lua comment except the licence notices, then PROVES the strip
# changed nothing before the copy is allowed to land:
#
#   1. luacheck  --only 011 --std lua51   (the same syntax gate as check-lua)
#   2. bytecode  - every stripped file is compiled by tools\lua5.1.exe and its
#      string.dump compared byte-for-byte against the repo original's. Comments
#      are whitespace to the compiler, and the strip preserves line numbers, so
#      the dumps must be IDENTICAL - any diff means the strip altered code, and
#      the deploy aborts with the staging left in place for inspection.
#
# What survives the strip (the GPL notice the licence requires shipped):
#   * any comment containing "SPDX-License-Identifier"
#   * a contiguous full-line comment block containing "Copyright (C)", from the
#     Copyright line to the end of the block (the standard 8-line tail notice)
#
# LINE NUMBERS ARE PRESERVED: a stripped comment leaves its newlines behind, so
# an error line from the published build matches the repo file exactly. The
# working notes still leave the ship build; only blank lines remain.
#
# The repo payload is never touched, and the destination is never a junction:
# the copy is staged beside the target and only swapped in after both gates
# pass. If the existing target contains ANY reparse point the script refuses -
# deleting through a link that points back at the repo would eat the source
# (see deploy.bat's header for how linked trees end).
#
# Usage:
#   python tools\deploy-workshop.py            stage, strip, validate, swap
#   python tools\deploy-workshop.py --dry-run  everything except the swap
#   python tools\deploy-workshop.py --dest D:\elsewhere\RequiemOfTheDead

import argparse
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

# The repo root is found by walking up from wherever this script lives, so the
# script survives being moved between tools\ and its subfolders.
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
PAYLOAD = os.path.join(REPO, "RequiemOfTheDead")
DEFAULT_DEST = os.path.join(os.path.expanduser("~"), "Zomboid", "Workshop", "RequiemOfTheDead")
LUACHECK = os.path.join(REPO, "tools", "luacheck.exe")
LUA51 = os.path.join(REPO, "tools", "lua5.1.exe")

LONG_OPEN = re.compile(r"\[(=*)\[")


def find_comments(text):
    """Lex Lua 5.1 source; return [(start, end)] spans of every comment.
    end is exclusive and never includes the terminating newline of a line
    comment. Strings (quoted and long-bracket) are skipped, so a '--' inside
    one is never mistaken for a comment."""
    spans = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "'" or c == '"':
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                elif text[i] == c or text[i] == "\n":  # \n = unterminated; luacheck's problem
                    i += 1
                    break
                else:
                    i += 1
        elif c == "[":
            m = LONG_OPEN.match(text, i)
            i = skip_long(text, m) if m else i + 1
        elif c == "-" and text.startswith("--", i):
            start = i
            m = LONG_OPEN.match(text, i + 2)
            if m:
                end = skip_long(text, m)
            else:
                end = text.find("\n", i)
                if end == -1:
                    end = n
            spans.append((start, end))
            i = end
        else:
            i += 1
    return spans


def skip_long(text, m):
    """Advance past a long bracket [=*[ ... ]=*] opened by match m."""
    close = "]" + m.group(1) + "]"
    end = text.find(close, m.end())
    return len(text) if end == -1 else end + len(close)


def keep_set(text, spans):
    """Indices of comment spans that must survive: SPDX lines, and Copyright
    blocks from the Copyright line to the end of their contiguous run."""
    keep = set()
    infos = []  # (index, line_no, full_line, body)
    for idx, (s, e) in enumerate(spans):
        body = text[s:e]
        if "SPDX-License-Identifier" in body:
            keep.add(idx)
        ls = text.rfind("\n", 0, s) + 1
        infos.append((idx, text.count("\n", 0, s), text[ls:s].strip() == "", body))

    block = []  # consecutive full-line comments
    def flush(block):
        first = next((k for k, (_, _, _, b) in enumerate(block) if "Copyright (C)" in b), None)
        if first is not None:
            for idx, _, _, _ in block[first:]:
                keep.add(idx)

    prev_line = None
    for info in infos:
        idx, line, full, body = info
        if full and prev_line is not None and line == prev_line + 1 and block:
            block.append(info)
        else:
            flush(block)
            block = [info] if full else []
        prev_line = line if full else None
    flush(block)
    return keep


def strip_file(path):
    """Strip comments in place. Returns (removed_count, bytes_saved)."""
    with open(path, "rb") as f:
        raw = f.read()
    text = raw.decode("utf-8")
    spans = find_comments(text)
    keep = keep_set(text, spans)

    out, last, removed, touched = [], 0, 0, set()
    for idx, (s, e) in enumerate(spans):
        if idx in keep:
            continue
        out.append(text[last:s])
        nl = text.count("\n", s, e)
        # newlines keep line parity; a single space keeps inline comments from
        # ever joining the tokens around them (e.g. "a- --[[c]]-b")
        out.append("\n" * nl if nl else " ")
        first = text.count("\n", 0, s)
        touched.update(range(first, first + nl + 1))
        removed += 1
        last = e
    if not removed:
        return 0, 0
    out.append(text[last:])

    lines = "".join(out).split("\n")
    for ln in touched:  # trailing whitespace left where a comment was cut
        if ln < len(lines):
            lines[ln] = lines[ln].rstrip()
    new = "\n".join(lines).encode("utf-8")
    with open(path, "wb") as f:
        f.write(new)
    return removed, len(raw) - len(new)


def refuse_reparse_points(root):
    """Walk root; die if anything is a junction/symlink. rmtree through a link
    that points at the repo would delete the source of truth."""
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            p = os.path.join(dirpath, name)
            attrs = os.lstat(p).st_file_attributes
            if attrs & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                sys.exit(f"REFUSING: {p} is a junction/symlink - remove it by hand first.")
    attrs = os.lstat(root).st_file_attributes
    if attrs & stat.FILE_ATTRIBUTE_REPARSE_POINT:
        sys.exit(f"REFUSING: {root} is a junction/symlink - remove it by hand first.")


# Compare original vs stripped compiled with an identical chunk name; comments
# are whitespace and lines are preserved, so string.dump must match exactly.
BYTECODE_LUA = r"""
local fails = 0
for line in io.lines(arg[1]) do
    local a, b = line:match('^(.-)\t(.+)$')
    local function chunk(p)
        local f = assert(io.open(p, 'rb'))
        local s = f:read('*a'); f:close()
        s = s:gsub('^\239\187\191', '')
        return loadstring(s, '@x')
    end
    local fa, ea = chunk(a)
    local fb, eb = chunk(b)
    if not fa then print('ORIG-FAIL\t' .. a .. '\t' .. tostring(ea)); fails = fails + 1
    elseif not fb then print('STRIP-FAIL\t' .. b .. '\t' .. tostring(eb)); fails = fails + 1
    elseif string.dump(fa) ~= string.dump(fb) then print('BYTECODE-DIFF\t' .. b); fails = fails + 1
    end
end
os.exit(fails == 0 and 0 or 1)
"""


def main():
    ap = argparse.ArgumentParser(description="Deploy comment-stripped payload to Zomboid\\Workshop")
    ap.add_argument("--dest", default=DEFAULT_DEST)
    ap.add_argument("--dry-run", action="store_true", help="stage, strip and validate, but do not swap in")
    args = ap.parse_args()

    for p, what in ((PAYLOAD, "payload"), (LUACHECK, "luacheck.exe"), (LUA51, "lua5.1.exe")):
        if not os.path.exists(p):
            sys.exit(f"missing {what}: {p}")

    dest = os.path.abspath(args.dest)
    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    staging = os.path.join(parent, ".staging-" + os.path.basename(dest))

    if os.path.exists(staging):
        refuse_reparse_points(staging)
        shutil.rmtree(staging)

    print(f"staging   {PAYLOAD}")
    shutil.copytree(PAYLOAD, staging)

    lua_files = []
    for dirpath, _, filenames in os.walk(staging):
        for name in filenames:
            if name.lower().endswith(".lua"):
                lua_files.append(os.path.join(dirpath, name))

    removed_total, saved_total = 0, 0
    for path in lua_files:
        removed, saved = strip_file(path)
        removed_total += removed
        saved_total += saved
    print(f"stripped  {removed_total} comments from {len(lua_files)} files ({saved_total / 1024:.0f} KB of notes stay home)")

    print("validate  luacheck --only 011 --std lua51")
    r = subprocess.run([LUACHECK, "--only", "011", "--std", "lua51", "--formatter", "plain", staging],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout.strip() or r.stderr.strip())
        sys.exit(f"ABORT: stripped tree fails the syntax gate - staging kept at {staging}")

    print("validate  bytecode identity vs repo originals")
    with tempfile.TemporaryDirectory() as tmp:
        pairs = os.path.join(tmp, "pairs.txt")
        helper = os.path.join(tmp, "bcmp.lua")
        with open(pairs, "w", encoding="utf-8") as f:
            for path in lua_files:
                rel = os.path.relpath(path, staging)
                f.write(os.path.join(PAYLOAD, rel) + "\t" + path + "\n")
        with open(helper, "w", encoding="utf-8") as f:
            f.write(BYTECODE_LUA)
        r = subprocess.run([LUA51, helper, pairs], capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout.strip() or r.stderr.strip())
            sys.exit(f"ABORT: stripped code is not byte-identical to the source - staging kept at {staging}")

    if args.dry_run:
        shutil.rmtree(staging)
        print(f"dry run   OK - would deploy to {dest}")
        return

    if os.path.exists(dest):
        refuse_reparse_points(dest)
        shutil.rmtree(dest)
    os.rename(staging, dest)
    print(f"deployed  {dest}")
    print("          (repo untouched; upload from the in-game Workshop menu)")


if __name__ == "__main__":
    main()
