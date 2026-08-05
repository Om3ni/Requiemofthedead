#!/usr/bin/env python3
"""stamp-license - put the GPL notice on every Lua file in the bundle.

WHY A TOOL AND NOT A ONE-OFF EDIT: the sweep is not a single event. New files
land every milestone, and a licence notice that only covers the files that
existed on the day someone remembered is worse than useless - it implies the
unmarked ones are unlicensed. Run this after adding files, and run it with
--check in a gate if you ever want the sweep enforced rather than remembered.

WHAT IT WRITES, and why it is split in two:

  Line 1        -- SPDX-License-Identifier: GPL-3.0-or-later
                One line, machine-readable, recognised by every licence
                scanner there is. It goes at the very top because that is
                where scanners look - but it is only one line, so the file's
                real header (what the module does, and why) still opens the
                file for a human.

  Foot          The notice in plain words. It replaces the family's existing
                "-- Copyright Project_Omen" sign-off rather than sitting
                alongside it, so a file never ends up with two copyright
                lines disagreeing about the year.

Idempotent: a file that already carries the SPDX line is left alone entirely,
so running twice is a no-op and running after adding one file stamps one file.

Line endings are preserved per file - this tree is checked out CRLF on Windows
and rewriting that would turn a licence sweep into a whole-repo diff.

Usage:
  python tools/stamp-license.py            stamp everything that needs it
  python tools/stamp-license.py --check    report only; exit 1 if any unstamped
"""

import io
import os
import sys

SPDX = "-- SPDX-License-Identifier: GPL-3.0-or-later"

FOOT = [
    "-- ---------------------------------------------------------------------------",
    "-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.",
    "--",
    "-- Free software under the GNU General Public License, version 3 or later.",
    "-- You may use, study, modify and share it. If you share it - modified or not,",
    "-- on the Workshop or anywhere else - keep this notice, license your version",
    "-- under the GPL too, publish your source, and say what you changed.",
    "-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.",
    "-- <https://www.gnu.org/licenses/gpl-3.0.html>",
]

# The sign-off this replaces. Matched loosely because it has drifted a little
# over the life of the tree.
OLD_SIGNOFF = "copyright project_omen"
RULE = "-- ---"


def find_lua(root):
    base = os.path.join(root, "RequiemOfTheDead", "Contents", "mods")
    for dirpath, _dirnames, filenames in os.walk(base):
        for name in sorted(filenames):
            if name.endswith(".lua"):
                yield os.path.join(dirpath, name)


def stamp(text):
    """Return the stamped text, or None if it already carries the SPDX line."""
    if SPDX in text:
        return None

    crlf = "\r\n" in text
    eol = "\r\n" if crlf else "\n"
    lines = text.replace("\r\n", "\n").split("\n")

    # Drop the trailing sign-off (and the rule line above it, if that is all
    # the rule was there for) so the new foot replaces it cleanly.
    while lines and lines[-1].strip() == "":
        lines.pop()
    if lines and OLD_SIGNOFF in lines[-1].lower():
        lines.pop()
        if lines and lines[-1].startswith(RULE):
            lines.pop()
        while lines and lines[-1].strip() == "":
            lines.pop()

    out = [SPDX] + lines + [""] + FOOT + [""]
    return eol.join(out)


def main():
    check = "--check" in sys.argv
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    changed, skipped = [], 0
    for path in find_lua(root):
        with io.open(path, encoding="utf-8") as fh:
            text = fh.read()
        new = stamp(text)
        if new is None:
            skipped += 1
            continue
        changed.append(path)
        if not check:
            with io.open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write(new)

    rel = lambda p: os.path.relpath(p, root).replace("\\", "/")
    if check:
        if changed:
            print("%d Lua file(s) carry no licence notice:" % len(changed))
            for p in changed[:20]:
                print("  " + rel(p))
            if len(changed) > 20:
                print("  ... and %d more" % (len(changed) - 20))
            print("Run: python tools/stamp-license.py")
            return 1
        print("All %d Lua files carry the licence notice." % skipped)
        return 0

    print("stamped %d file(s), %d already had it" % (len(changed), skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
