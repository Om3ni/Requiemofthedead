#!/usr/bin/env python3
"""Stage an isolated, unlisted Workshop test item through the production pipeline.

The production deployer remains the single owner of ship-source formatting and
semantic validation. This wrapper asks it to build a candidate, changes only the
Workshop publication identity, verifies that change, then swaps the candidate
into a separate staging folder.

Windows forbids ':' in directory names, so the filesystem item is RoTD-Testing
while its Workshop title is RoTD:Testing.

Deploying this REMOVES the production RequiemOfTheDead staging folder, and
deploying that one removes this. Both hold the same 13 mod ids, so two staged
copies let the engine pick between them by enumeration order rather than by
intent - and it picks the stale one often enough to cost an afternoon.

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


def test_manifest(raw, keep_id=None):
    """Return a testing manifest and the production id taken out of it.

    keep_id is the publication id Steam already assigned to the TESTING item,
    read back from the destination folder. Passing it re-emits that id so an
    upload UPDATES the existing test item.

    Without it every run shipped an id-less manifest. That is right exactly
    once - the first publish, where Steam mints an id and writes it back into
    the deployed workshop.txt. Every run after that overwrote the file and took
    the id with it, so the next upload silently created ANOTHER new Workshop
    item instead of updating the one already there.
    """
    text = raw.decode("utf-8-sig")
    lines = text.splitlines(keepends=True)
    id_values, titles, visibilities = [], 0, 0
    out = []

    for line in lines:
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        if body.startswith("id="):
            id_values.append(body[3:])
            # The PRODUCTION id never survives into a testing manifest. The
            # testing id, when we have one, takes its place and its position.
            if keep_id is not None:
                out.append("id=" + keep_id + ending)
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


def deployed_test_id(dest):
    """The publication id Steam assigned to the testing item, if it has one.

    Read BEFORE the destination is replaced - the swap deletes that folder, and
    with it the only record of the id.
    """
    path = os.path.join(dest, "workshop.txt")
    if not os.path.exists(path):
        return None
    with open(path, "rb") as handle:
        text = handle.read().decode("utf-8-sig")
    found = [
        line.rstrip("\r\n")[3:]
        for line in text.splitlines()
        if line.startswith("id=")
    ]
    found = [value for value in found if value.isdigit()]
    if not found:
        return None
    if len(found) > 1:
        raise RuntimeError(
            "deployed testing workshop.txt carries %d id= lines; refusing to guess"
            % len(found)
        )
    return found[0]


def prepare_manifest(candidate, keep_id=None):
    path = os.path.join(candidate, "workshop.txt")
    with open(path, "rb") as handle:
        raw = handle.read()
    prepared, old_id = test_manifest(raw, keep_id)
    if keep_id is not None and keep_id == old_id:
        raise RuntimeError(
            "the deployed testing item carries the PRODUCTION id (%s) - refusing "
            "to republish; that folder is not a test item" % old_id
        )
    with open(path, "wb") as handle:
        handle.write(prepared)
    return old_id


def verify_candidate(candidate, production_id, keep_id=None):
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
    # The safety property is NOT "there is no id" - it is "the id is not the
    # production one". Demanding absence is what made every redeploy discard
    # the testing item's own id and mint a fresh Workshop entry.
    ids = [line[3:] for line in lines if line.startswith("id=")]
    if production_id in ids:
        raise RuntimeError("testing workshop.txt still carries the PRODUCTION id")
    if keep_id is None:
        if ids:
            raise RuntimeError(
                "testing workshop.txt has an unexpected id: " + ", ".join(ids))
    elif ids != [keep_id]:
        raise RuntimeError(
            "testing workshop.txt should carry exactly the deployed testing id %s, "
            "found %s" % (keep_id, ids or "none"))
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


def build(candidate, keep_id=None):
    run_canonical(candidate)
    old_id = prepare_manifest(candidate, keep_id)
    mods = verify_candidate(candidate, old_id, keep_id)
    print(f"identity   production Workshop id {old_id} removed")
    if keep_id is None:
        print("identity   no testing id yet - Steam will mint one on first upload")
    else:
        print(f"identity   testing Workshop id {keep_id} PRESERVED (this is an update)")
    print(f"identity   title={TEST_TITLE}, visibility={TEST_VISIBILITY}")
    print(f"verified   {mods} internal mod id(s) preserved")


def main():
    parser = argparse.ArgumentParser(description="Stage the isolated RoTD testing item")
    parser.add_argument("--dest", default=DEFAULT_DEST)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    dest = os.path.abspath(args.dest)
    ensure_owned_path(dest)
    # Read FIRST: the swap below deletes dest, and its workshop.txt is the only
    # place the testing item's publication id exists.
    keep_id = deployed_test_id(dest)

    if args.dry_run:
        with tempfile.TemporaryDirectory(prefix="rftd-testing-") as tmp:
            candidate = os.path.join(tmp, "RoTD-Testing")
            build(candidate, keep_id)
        print(f"dry run    OK - would deploy to {dest}")
        CANONICAL.remove_rival(dest, dry_run=True)
        return

    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    candidate = os.path.join(parent, ".candidate-" + os.path.basename(dest))
    if os.path.exists(candidate):
        CANONICAL.refuse_reparse_points(candidate)
        shutil.rmtree(candidate)

    try:
        build(candidate, keep_id)
        if os.path.exists(dest):
            CANONICAL.refuse_reparse_points(dest)
            shutil.rmtree(dest)
        os.rename(candidate, dest)
    except Exception:
        print(f"ABORT: candidate kept for inspection at {candidate}", file=sys.stderr)
        raise

    print(f"deployed   {dest}")
    if keep_id is None:
        print("           NEW unlisted item; upload from the in-game Workshop menu")
    else:
        print(f"           updates existing unlisted item {keep_id}; upload to publish")

    # The production item and this one carry the same 13 mod ids, so only one of
    # them may be staged at a time - see CANONICAL.remove_rival for the engine
    # reason. Note the canonical run above CANNOT do this for us: it is invoked
    # with --dest pointing at a temp candidate, whose basename is neither item,
    # so its own rival_of returns None by design.
    CANONICAL.remove_rival(dest, dry_run=False)


if __name__ == "__main__":
    main()
