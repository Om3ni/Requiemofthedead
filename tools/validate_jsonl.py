#!/usr/bin/env python3
"""validate_jsonl.py - the selftest's exit criterion, and a general health check.

Walks a directory tree (default: the RFTD dir under a Zomboid Lua cache),
runs json.loads over every line of every .jsonl file plus every .json file
as a whole, and reports failures. Zero failures = the Lua encoder held up.

Usage:
    python tools/validate_jsonl.py <path-to-RFTD-dir>
    python tools/validate_jsonl.py "%USERPROFILE%/Zomboid/Lua/RFTD"

Stdlib only, per family convention.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = Path(sys.argv[1]).expanduser()
    if not root.is_dir():
        print(f"not a directory: {root}")
        return 2

    files = lines = bad = 0
    for path in sorted(root.rglob("*")):
        if path.suffix == ".jsonl":
            files += 1
            with path.open("r", encoding="utf-8", errors="replace") as fh:
                for lineno, line in enumerate(fh, 1):
                    line = line.strip()
                    if not line:
                        continue
                    lines += 1
                    try:
                        json.loads(line)
                    except json.JSONDecodeError as exc:
                        bad += 1
                        print(f"BAD {path}:{lineno}: {exc}: {line[:120]!r}")
        elif path.suffix == ".json":
            files += 1
            lines += 1
            try:
                json.loads(path.read_text(encoding="utf-8", errors="replace"))
            except json.JSONDecodeError as exc:
                bad += 1
                print(f"BAD {path}: {exc}")

    print(f"{files} files, {lines} records, {bad} failures")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
