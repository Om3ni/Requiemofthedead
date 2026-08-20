#!/usr/bin/env python3
# deploy-workshop.py - stage the payload for the in-game Workshop uploader.
#
# Copies RequiemOfTheDead\ (the whole Workshop item: workshop.txt, preview.png,
# Contents\mods\...) into %USERPROFILE%\Zomboid\Workshop\RequiemOfTheDead,
# applying one deterministic ship-source pipeline before the copy can land:
#
#   1. strip every Lua comment, including the repository licence blocks
#   2. collapse blank runs outside literals to one blank line
#   3. stamp the canonical SPDX header and GPL footer back onto every Lua file
#
# The exact final artifact then passes:
#
#   1. luacheck  --only 011 --std lua51   (the same syntax gate as check-lua)
#   2. Lua 5.1   - every final file is compiled by tools\Gates\lua5.1.exe
#   3. tokens    - every identifier, number, string and operator is compared in
#      order with the repo original. Any join, split or changed literal aborts.
#   4. payload   - non-Lua files remain byte-identical and only the approved GPL
#      comments survive in Lua.
#
# No source comment is special during stripping. The shipped licence comes from
# tools\license_notice.py, the same canonical definition used by
# tools\stamp-license.py, so the two paths cannot drift.
#
# LINE NUMBERS DELIBERATELY DIFFER: each run of whitespace left by working notes
# becomes one blank line. Production errors must be checked against the staged
# Workshop snapshot, which is the exact artifact the game loads.
#
# The repo payload is never touched, and the destination is never a junction:
# the copy is staged beside the target and only swapped in after both gates
# pass. If the existing target contains ANY reparse point the script refuses -
# deleting through a link that points back at the repo would eat the source.
# That is not hypothetical: the linked-tree deploy scripts this replaced cost
# 286 files on 2026-08-02 doing exactly that, and were deleted 2026-08-20.
#
# EXACTLY ONE STAGED ITEM. This script and deploy-workshop-testing.py write two
# different folders into the same Workshop directory, and both contain the same
# 13 mod ids. Whichever one runs last deletes the other, because two staged
# copies of the same ids let the engine choose by enumeration order instead of
# by intent - see remove_rival below.
#
# Usage:
#   python "tools\Deploy Tools\deploy-workshop.py"            format, prove, swap
#   python "tools\Deploy Tools\deploy-workshop.py" --dry-run  everything except the swap
#   python "tools\Deploy Tools\deploy-workshop.py" --dest D:\elsewhere\RequiemOfTheDead

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
# Both binaries live with the gates - they ARE the gates' tools, and this script
# runs the same two checks as check-lua and run-tests do (2026-08-20: they moved
# from tools/ into tools/Gates/ with everything else that uses them).
GATES = os.path.join(REPO, "tools", "Gates")
LUACHECK = os.path.join(GATES, "luacheck.exe")
LUA51 = os.path.join(GATES, "lua5.1.exe")
# license_notice.py is a SIBLING now (moved 2026-08-20 to sit with its two
# consumers, this file and stamp-license.py), so the path hop is gone.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from license_notice import FOOT, SPDX

LONG_OPEN = re.compile(r"\[(=*)\[")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
NUMBER = re.compile(
    r"(?:0[xX][0-9A-Fa-f]+|"
    r"(?:[0-9]+\.(?!\.)[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|"
    r"[0-9]+[eE][+-]?[0-9]+|[0-9]+)"
)
MULTI_OPS = ("...", "..", "==", "~=", "<=", ">=")
SINGLE_OPS = set("+-*/%^#=<>;:,.(){}[]")


def scan_lua(text):
    """Return (tokens, comments, protected spans) from Lua 5.1 source.

    Tokens exclude comments and whitespace. Protected spans are strings and
    comments whose internal blank lines the ship formatter must never touch.
    """
    tokens, comments, protected = [], [], []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif c == "-" and text.startswith("--", i):
            start = i
            m = LONG_OPEN.match(text, i + 2)
            if m:
                end = skip_long(text, m)
            else:
                end = text.find("\n", i)
                if end == -1:
                    end = n
                elif end > i and text[end - 1] == "\r":
                    end -= 1
            comments.append((start, end))
            protected.append((start, end))
            i = end
        elif c == "'" or c == '"':
            start = i
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                elif text[i] == c or text[i] == "\n":  # \n = unterminated; luacheck's problem
                    i += 1
                    break
                else:
                    i += 1
            tokens.append(("string", text[start:i]))
            protected.append((start, i))
        elif c == "[":
            m = LONG_OPEN.match(text, i)
            if m:
                end = skip_long(text, m)
                tokens.append(("string", text[i:end]))
                protected.append((i, end))
                i = end
            else:
                tokens.append(("op", c))
                i += 1
        else:
            m = IDENT.match(text, i)
            if m:
                tokens.append(("word", m.group(0)))
                i = m.end()
                continue
            m = NUMBER.match(text, i)
            if m:
                tokens.append(("number", m.group(0)))
                i = m.end()
                continue
            op = next((candidate for candidate in MULTI_OPS if text.startswith(candidate, i)), None)
            if op:
                tokens.append(("op", op))
                i += len(op)
            else:
                # luacheck owns the syntax verdict. Keeping an unknown byte as a
                # token still makes any formatter-created change observable.
                tokens.append(("op" if c in SINGLE_OPS else "byte", c))
                i += 1
    return tokens, comments, protected


def find_comments(text):
    """Return [(start, end)] spans of every Lua comment."""
    return scan_lua(text)[1]


def skip_long(text, m):
    """Advance past a long bracket [=*[ ... ]=*] opened by match m."""
    close = "]" + m.group(1) + "]"
    end = text.find(close, m.end())
    return len(text) if end == -1 else end + len(close)


def collapse_blank_runs(text):
    """Collapse blank runs outside strings/comments to one line."""
    protected = scan_lua(text)[2]
    out, offset, span_at, blank_open, collapsed = [], 0, 0, False, 0
    for line in text.splitlines(keepends=True):
        end = offset + len(line)
        while span_at < len(protected) and protected[span_at][1] <= offset:
            span_at += 1
        inside = span_at < len(protected) \
            and protected[span_at][0] < end and protected[span_at][1] > offset

        if line.endswith("\r\n"):
            body, newline = line[:-2], "\r\n"
        elif line.endswith("\n") or line.endswith("\r"):
            body, newline = line[:-1], line[-1:]
        else:
            body, newline = line, ""

        blank = not inside and body.strip(" \t") == ""
        if blank and blank_open:
            collapsed += 1
        elif blank:
            out.append(newline)
            blank_open = True
        else:
            out.append(line)
            blank_open = False
        offset = end
    return "".join(out), collapsed


def stamp_ship_license(text):
    """Wrap ship source in the one canonical Lua licence notice."""
    bom = "\ufeff" if text.startswith("\ufeff") else ""
    body = text[len(bom):].strip(" \t\r\n")
    crlf = text.count("\r\n")
    bare_lf = text.count("\n") - crlf
    eol = "\r\n" if crlf > bare_lf else "\n"
    middle = body + eol + eol if body else ""
    return bom + SPDX + eol + eol + middle + eol.join(FOOT) + eol


def prepare_lua(text):
    """Strip, collapse and re-license one Lua source string."""
    spans = find_comments(text)

    edits = []
    for s, e in spans:
        line_start = text.rfind("\n", 0, s) + 1
        next_lf = text.find("\n", e)
        line_end = len(text) if next_lf == -1 else next_lf
        if line_end > e and text[line_end - 1] == "\r":
            line_end -= 1
        full_line = not text[line_start:s].strip() and not text[e:line_end].strip()
        long_comment = LONG_OPEN.match(text, s + 2) is not None
        code_after = bool(text[e:line_end].strip())

        if full_line:
            edits.append((line_start, line_end, ""))
        elif not long_comment or not code_after:
            start = s
            while start > line_start and text[start - 1] in " \t":
                start -= 1
            edits.append((start, line_end, ""))
        else:
            # An inline long comment can sit between two live tokens. One space
            # preserves their boundary without preserving the working note.
            edits.append((s, e, " "))

    out, last = [], 0
    for s, e, replacement in edits:
        out.append(text[last:s])
        out.append(replacement)
        last = e
    out.append(text[last:])
    collapsed_text, collapsed = collapse_blank_runs("".join(out))
    return stamp_ship_license(collapsed_text), len(spans), collapsed


def strip_file(path):
    """Prepare Lua ship source in place. Returns counts and bytes saved."""
    with open(path, "rb") as f:
        raw = f.read()
    text = raw.decode("utf-8")
    prepared, removed, collapsed = prepare_lua(text)
    new = prepared.encode("utf-8")
    if new == raw:
        return removed, collapsed, 0
    with open(path, "wb") as f:
        f.write(new)
    return removed, collapsed, len(raw) - len(new)


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


# The two staged items this repo can produce. Both land in the same Workshop
# folder and both contain the SAME 13 mod ids, which is what makes them mutually
# exclusive rather than merely redundant.
PRODUCTION_ITEM = "RequiemOfTheDead"
TESTING_ITEM = "RoTD-Testing"


def rival_of(dest):
    """The other staged item beside `dest`, or None if dest is neither of ours.

    A custom --dest has no rival: the concept only means anything for the two
    names above, sitting in one Workshop folder.
    """
    dest = os.path.abspath(dest)
    base = os.path.basename(dest)
    other = {PRODUCTION_ITEM: TESTING_ITEM, TESTING_ITEM: PRODUCTION_ITEM}.get(base)
    if other is None:
        return None
    return os.path.join(os.path.dirname(dest), other)


def remove_rival(dest, dry_run):
    """Delete the OTHER staged item, so exactly one is ever on disk.

    WHY THIS IS NOT TIDINESS. getAllModFolders searches "workshop,steam,mods"
    and enumerates every staged Workshop item in the first pass; readModInfo
    breaks duplicate-id ties by LOWEST INDEX. Both of our items carry the same
    13 mod ids, so leaving both staged means the engine picks by enumeration
    order rather than by intent - and the one it picks is usually the stale one
    you were not testing. The symptom is the worst kind: your code appears to
    deploy fine and the server runs something else, silently.

    Runs AFTER a successful swap, never before: a failed deploy should cost you
    nothing, and deleting the rival first would leave you with neither item if
    the build then aborted.
    """
    rival = rival_of(dest)
    if not rival or not os.path.exists(rival):
        return
    if dry_run:
        print(f"would remove  {rival} (stale sibling item - only one may be staged)")
        return
    # Same refusal as the destination itself. Nothing this repo builds creates a
    # junction, but a hand-made one here would send rmtree into the repo.
    refuse_reparse_points(rival)
    shutil.rmtree(rival)
    print(f"removed   {rival}")
    print("          (the other staged item - both carry the same mod ids, and")
    print("           the engine would have picked between them by enumeration order)")


# Compile the exact final files with the same Lua generation the game embeds.
COMPILE_LUA = r"""
local fails = 0
for line in io.lines(arg[1]) do
    local f = assert(io.open(line, 'rb'))
    local source = f:read('*a'); f:close()
    source = source:gsub('^\239\187\191', '')
    local chunk, err = loadstring(source, '@' .. line)
    if not chunk then
        print('COMPILE-FAIL\t' .. line .. '\t' .. tostring(err))
        fails = fails + 1
    end
end
os.exit(fails == 0 and 0 or 1)
"""


def validate_payload(staging):
    """Prove the final payload differs only by approved Lua presentation."""
    def inventory(root):
        found = {}
        for dirpath, _, filenames in os.walk(root):
            for name in filenames:
                path = os.path.join(dirpath, name)
                found[os.path.relpath(path, root)] = path
        return found

    originals, shipped = inventory(PAYLOAD), inventory(staging)
    failures = []
    missing = sorted(set(originals) - set(shipped))
    extra = sorted(set(shipped) - set(originals))
    failures.extend("MISSING\t" + rel for rel in missing)
    failures.extend("EXTRA\t" + rel for rel in extra)

    for rel in sorted(set(originals) & set(shipped)):
        with open(originals[rel], "rb") as f:
            original_raw = f.read()
        with open(shipped[rel], "rb") as f:
            shipped_raw = f.read()

        if not rel.lower().endswith(".lua"):
            if original_raw != shipped_raw:
                failures.append("NONLUA-DIFF\t" + rel)
            continue

        try:
            original = original_raw.decode("utf-8-sig")
            final = shipped_raw.decode("utf-8-sig")
        except UnicodeDecodeError as err:
            failures.append(f"UTF8-FAIL\t{rel}\t{err}")
            continue

        original_tokens = scan_lua(original)[0]
        final_tokens, comments, _ = scan_lua(final)
        if original_tokens != final_tokens:
            shared = min(len(original_tokens), len(final_tokens))
            first = next((i for i in range(shared)
                          if original_tokens[i] != final_tokens[i]), shared)
            failures.append(
                f"TOKEN-DIFF\t{rel}\ttoken {first}: "
                f"{original_tokens[first:first + 2]!r} != {final_tokens[first:first + 2]!r}"
            )

        actual_notice = [final[start:end] for start, end in comments]
        expected_notice = [SPDX, *FOOT]
        if actual_notice != expected_notice:
            failures.append(
                f"LICENSE-DIFF\t{rel}\t"
                f"expected {len(expected_notice)} canonical comments, found {len(actual_notice)}"
            )
        normalized = final.replace("\r\n", "\n").replace("\r", "\n")
        if not normalized.startswith(SPDX + "\n\n") \
                or not normalized.endswith("\n".join(FOOT) + "\n"):
            failures.append(f"LICENSE-LAYOUT\t{rel}")

    return failures


def main():
    ap = argparse.ArgumentParser(description="Deploy ship-formatted payload to Zomboid\\Workshop")
    ap.add_argument("--dest", default=DEFAULT_DEST)
    ap.add_argument("--dry-run", action="store_true", help="stage, format and validate, but do not swap in")
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

    removed_total, collapsed_total, saved_total = 0, 0, 0
    for path in lua_files:
        removed, collapsed, saved = strip_file(path)
        removed_total += removed
        collapsed_total += collapsed
        saved_total += saved
    print(f"formatted {removed_total} comments stripped, {collapsed_total} blank lines collapsed "
          f"across {len(lua_files)} files ({saved_total / 1024:.0f} KB stay home)")

    print("validate  luacheck --only 011 --std lua51")
    r = subprocess.run([LUACHECK, "--only", "011", "--std", "lua51", "--formatter", "plain", staging],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout.strip() or r.stderr.strip())
        sys.exit(f"ABORT: final tree fails the syntax gate - staging kept at {staging}")

    print("validate  Lua 5.1 compilation of final files")
    with tempfile.TemporaryDirectory() as tmp:
        listing = os.path.join(tmp, "lua-files.txt")
        helper = os.path.join(tmp, "compile.lua")
        with open(listing, "w", encoding="utf-8") as f:
            for path in lua_files:
                f.write(path + "\n")
        with open(helper, "w", encoding="utf-8") as f:
            f.write(COMPILE_LUA)
        r = subprocess.run([LUA51, helper, listing], capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout.strip() or r.stderr.strip())
            sys.exit(f"ABORT: final code does not compile as Lua 5.1 - staging kept at {staging}")

    print("validate  token identity, retained comments and copied payload")
    failures = validate_payload(staging)
    if failures:
        print("\n".join(failures))
        sys.exit(f"ABORT: final payload changed semantics or collateral files - staging kept at {staging}")

    if args.dry_run:
        shutil.rmtree(staging)
        print(f"dry run   OK - would deploy to {dest}")
        remove_rival(dest, dry_run=True)
        return

    if os.path.exists(dest):
        refuse_reparse_points(dest)
        shutil.rmtree(dest)
    os.rename(staging, dest)
    print(f"deployed  {dest}")
    print("          (repo untouched; upload from the in-game Workshop menu)")
    remove_rival(dest, dry_run=False)


if __name__ == "__main__":
    main()
