#!/usr/bin/env python3
"""validate_jsonl.py - the selftest's exit criterion, and a general health check.

Walks a directory tree (default: the RFTD dir under a Zomboid Lua cache),
runs json.loads over every line of every JSONL file plus every JSON file
as a whole, and reports failures. Zero failures = the Lua encoder held up.

TWO NAMING ERAS, both accepted. Since 42.20 the engine refuses to WRITE any
extension outside ("ini","cfg","txt","log"), so the mods append a second
extension: events.jsonl -> events.jsonl.log, latest.json -> latest.json.txt
(see RDShared.EXT_STREAM / EXT_DOC). Pre-42.20 files keep their bare names and
are never migrated - Lua cannot rename or delete - so a real cache holds both
and this tool must read both or it silently under-reports.

Matching is therefore on the NAME, not Path.suffix: for "events.jsonl.log"
suffix is ".log", which the old `suffix == ".jsonl"` test skipped entirely
while still exiting 0 - a validator that passes by finding nothing.

Usage:
    python tools/validate_jsonl.py <path-to-RFTD-dir>
    python tools/validate_jsonl.py "%USERPROFILE%/Zomboid/Lua/RFTD"

Stdlib only, per family convention.
"""

import json
import sys
from pathlib import Path

# Order matters: ".jsonl" must be tested before ".json" or a JSONL file would
# match the whole-document branch and fail on its second line. Kept as suffix
# tuples so the compound and legacy forms stay visibly paired.
JSONL_SUFFIXES = (".jsonl", ".jsonl.log", ".jsonl.txt")
JSON_SUFFIXES = (".json", ".json.txt", ".json.log")


def classify(name: str) -> str | None:
    """Return 'jsonl', 'json', or None for a filename."""
    lowered = name.lower()
    if lowered.endswith(JSONL_SUFFIXES):
        return "jsonl"
    if lowered.endswith(JSON_SUFFIXES):
        return "json"
    return None


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
        if not path.is_file():
            continue
        kind = classify(path.name)
        if kind == "jsonl":
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
        elif kind == "json":
            files += 1
            lines += 1
            try:
                json.loads(path.read_text(encoding="utf-8", errors="replace"))
            except json.JSONDecodeError as exc:
                bad += 1
                print(f"BAD {path}: {exc}")

    # "0 failures" over 0 files means the glob missed, not that the data is
    # clean - say so rather than exiting 0 on an empty sweep.
    if files == 0:
        print(f"no JSON/JSONL files found under {root} - nothing was validated")
        return 2

    print(f"{files} files, {lines} records, {bad} failures")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
