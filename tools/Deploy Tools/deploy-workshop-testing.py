#!/usr/bin/env python3
"""Stage an isolated, unlisted Workshop test item through the production pipeline.

The production deployer remains the single owner of ship-source formatting and
semantic validation. This wrapper asks it to build a candidate, changes only the
Workshop publication identity, verifies that change, then swaps the candidate
into a separate staging folder.

Windows forbids ':' in directory names, so the filesystem item is RoTD-Testing
while its Workshop title is RoTD:Testing.

Usage:
    python "tools/Deploy Tools/deploy-workshop-testing.py" --dry-run
    python "tools/Deploy Tools/deploy-workshop-testing.py"
"""

import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile


HERE = os.path.dirname(os.path.abspath(__file__))
CANONICAL_PATH = os.path.join(HERE, "deploy-workshop.py")
DEFAULT_DEST = os.path.join(
    os.path.expanduser("~"), "Zomboid", "Workshop", "RoTD-Testing"
)
TEST_TITLE = "RoTD:Testing"
TEST_VISIBILITY = "unlisted"


def _load_canonical():
    spec = importlib.util.spec_from_file_location("rftd_deploy_workshop", CANONICAL_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CANONICAL = _load_canonical()


def test_manifest(raw):
    """Return a new-item manifest and the removed numeric publication id."""
    text = raw.decode("utf-8-sig")
    lines = text.splitlines(keepends=True)
    id_values, titles, visibilities = [], 0, 0
    out = []

    for line in lines:
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        if body.startswith("id="):
            id_values.append(body[3:])
        elif body.startswith("title="):
            titles += 1
            out.append("title=" + TEST_TITLE + ending)
        elif body.startswith("visibility="):
            visibilities += 1
            out.append("visibility=" + TEST_VISIBILITY + ending)
        else:
            out.append(line)

    if len(id_values) != 1 or not id_values[0].isdigit():
        raise ValueError("expected exactly one numeric id= line in workshop.txt")
    if titles != 1:
        raise ValueError("expected exactly one title= line in workshop.txt")
    if visibilities != 1:
        raise ValueError("expected exactly one visibility= line in workshop.txt")

    bom = b"\xef\xbb\xbf" if raw.startswith(b"\xef\xbb\xbf") else b""
    return bom + "".join(out).encode("utf-8"), id_values[0]


def prepare_manifest(candidate):
    path = os.path.join(candidate, "workshop.txt")
    with open(path, "rb") as handle:
        raw = handle.read()
    prepared, old_id = test_manifest(raw)
    with open(path, "wb") as handle:
        handle.write(prepared)
    return old_id


def verify_candidate(candidate):
    required = (
        os.path.join(candidate, "workshop.txt"),
        os.path.join(candidate, "preview.png"),
        os.path.join(candidate, "Contents", "mods"),
    )
    missing = [path for path in required if not os.path.exists(path)]
    if missing:
        raise RuntimeError("testing artifact missing: " + ", ".join(missing))

    with open(required[0], encoding="utf-8-sig") as handle:
        lines = [line.rstrip("\r\n") for line in handle]
    if any(line.startswith("id=") for line in lines):
        raise RuntimeError("testing workshop.txt still contains a publication id")
    if lines.count("title=" + TEST_TITLE) != 1:
        raise RuntimeError("testing workshop.txt has the wrong title")
    if lines.count("visibility=" + TEST_VISIBILITY) != 1:
        raise RuntimeError("testing workshop.txt is not unlisted")

    mods = [entry for entry in os.scandir(required[2]) if entry.is_dir()]
    if not mods:
        raise RuntimeError("testing artifact contains no mods")
    return len(mods)


def run_canonical(candidate):
    subprocess.run(
        [sys.executable, CANONICAL_PATH, "--dest", candidate],
        check=True,
    )


def ensure_owned_path(dest):
    parent = os.path.abspath(os.path.dirname(dest))
    workshop = os.path.abspath(
        os.path.join(os.path.expanduser("~"), "Zomboid", "Workshop")
    )
    if os.path.commonpath((parent, workshop)) != workshop:
        raise RuntimeError("testing destination must remain under " + workshop)


def build(candidate):
    run_canonical(candidate)
    old_id = prepare_manifest(candidate)
    mods = verify_candidate(candidate)
    print(f"identity   removed Workshop id {old_id}")
    print(f"identity   title={TEST_TITLE}, visibility={TEST_VISIBILITY}")
    print(f"verified   {mods} internal mod id(s) preserved")


def main():
    parser = argparse.ArgumentParser(description="Stage the isolated RoTD testing item")
    parser.add_argument("--dest", default=DEFAULT_DEST)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    dest = os.path.abspath(args.dest)
    ensure_owned_path(dest)

    if args.dry_run:
        with tempfile.TemporaryDirectory(prefix="rftd-testing-") as tmp:
            candidate = os.path.join(tmp, "RoTD-Testing")
            build(candidate)
        print(f"dry run    OK - would deploy to {dest}")
        return

    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    candidate = os.path.join(parent, ".candidate-" + os.path.basename(dest))
    if os.path.exists(candidate):
        CANONICAL.refuse_reparse_points(candidate)
        shutil.rmtree(candidate)

    try:
        build(candidate)
        if os.path.exists(dest):
            CANONICAL.refuse_reparse_points(dest)
            shutil.rmtree(dest)
        os.rename(candidate, dest)
    except Exception:
        print(f"ABORT: candidate kept for inspection at {candidate}", file=sys.stderr)
        raise

    print(f"deployed   {dest}")
    print("           new unlisted item; upload from the in-game Workshop menu")


if __name__ == "__main__":
    main()
