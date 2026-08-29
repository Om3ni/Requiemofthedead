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

The testing item's Workshop id is BAKED IN below (Steam minted it once; the
owner recorded it 2026-08-28), which is what lets this script push straight to
Steam through steamcmd without the game - the earlier design read the id back
from the deployed folder because the first in-game upload was the only thing
that knew it.

Usage:
    python "tools/Deploy Tools/deploy-workshop-testing.py" --dry-run
    python "tools/Deploy Tools/deploy-workshop-testing.py"
    python "tools/Deploy Tools/deploy-workshop-testing.py" --no-push
    python "tools/Deploy Tools/deploy-workshop-testing.py" --yes
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
# The unlisted testing item Steam minted for this suite. Baked so every deploy
# updates THAT item and the push needs no game and no read-back; a deployed
# folder carrying any OTHER digit id is refused rather than guessed about.
TEST_ITEM_ID = "3786060706"


def _load_canonical():
    spec = importlib.util.spec_from_file_location("rftd_deploy_workshop", CANONICAL_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CANONICAL = _load_canonical()


def test_manifest(raw):
    """Return a testing manifest and the production id taken out of it.

    The production id never survives into a testing manifest; TEST_ITEM_ID
    takes its place and its position, so every deploy updates the one minted
    testing item. (The earlier design threaded a keep_id read back from the
    deployed folder, because before the id was recorded here the first
    in-game upload was the only thing that knew it.)
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
            out.append("id=" + TEST_ITEM_ID + ending)
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
    if id_values[0] == TEST_ITEM_ID:
        raise ValueError("the production manifest carries the TESTING item id - "
                         "someone swapped identities; refusing to touch it")
    if titles != 1:
        raise ValueError("expected exactly one title= line in workshop.txt")
    if visibilities != 1:
        raise ValueError("expected exactly one visibility= line in workshop.txt")

    bom = b"\xef\xbb\xbf" if raw.startswith(b"\xef\xbb\xbf") else b""
    return bom + "".join(out).encode("utf-8"), id_values[0]


def deployed_test_id(dest):
    """The publication id the DEPLOYED testing folder carries, if any.

    With TEST_ITEM_ID baked in this is a safety probe, not a source of truth:
    main() refuses a folder carrying any other digit id (the production id, or
    a stray second test item) instead of silently replacing it.
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


def prepare_manifest(candidate):
    path = os.path.join(candidate, "workshop.txt")
    with open(path, "rb") as handle:
        raw = handle.read()
    prepared, old_id = test_manifest(raw)
    with open(path, "wb") as handle:
        handle.write(prepared)
    return old_id


def verify_candidate(candidate, production_id):
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
    # The safety property: exactly the minted testing id, never the production
    # one - a push of this folder must be able to hit only the test item.
    ids = [line[3:] for line in lines if line.startswith("id=")]
    if production_id in ids:
        raise RuntimeError("testing workshop.txt still carries the PRODUCTION id")
    if ids != [TEST_ITEM_ID]:
        raise RuntimeError(
            "testing workshop.txt should carry exactly the testing id %s, "
            "found %s" % (TEST_ITEM_ID, ids or "none"))
    if lines.count("title=" + TEST_TITLE) != 1:
        raise RuntimeError("testing workshop.txt has the wrong title")
    if lines.count("visibility=" + TEST_VISIBILITY) != 1:
        raise RuntimeError("testing workshop.txt is not unlisted")

    mods = [entry for entry in os.scandir(required[2]) if entry.is_dir()]
    if not mods:
        raise RuntimeError("testing artifact contains no mods")
    return len(mods)


def run_canonical(candidate):
    # --no-push and --no-pause are load-bearing, not politeness: the candidate
    # still wears the PRODUCTION identity at this point and must never reach
    # Steam, and a child pausing for Enter would hang this pipeline mid-build.
    subprocess.run(
        [sys.executable, CANONICAL_PATH, "--dest", candidate,
         "--no-push", "--no-pause"],
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
    mods = verify_candidate(candidate, old_id)
    print(f"identity   production Workshop id {old_id} removed")
    print(f"identity   testing Workshop id {TEST_ITEM_ID} installed")
    print(f"identity   title={TEST_TITLE}, visibility={TEST_VISIBILITY}")
    print(f"verified   {mods} internal mod id(s) preserved")


def main():
    parser = argparse.ArgumentParser(description="Stage the isolated RoTD testing item")
    parser.add_argument("--dest", default=DEFAULT_DEST)
    parser.add_argument("--dry-run", action="store_true")
    CANONICAL.add_push_args(parser)
    args = parser.parse_args()

    # --login builds nothing; it is the same one-per-machine Steam session
    # both deployers push with, reachable from whichever script is at hand.
    if args.login:
        sys.exit(CANONICAL.do_login_only(args))

    dest = os.path.abspath(args.dest)
    ensure_owned_path(dest)
    # Probe FIRST: the swap below deletes dest. Any digit id other than the
    # minted testing id means this folder is not ours to replace.
    seen = deployed_test_id(dest)
    if seen is not None and seen != TEST_ITEM_ID:
        raise RuntimeError(
            "the deployed testing folder carries Workshop id %s, not the minted "
            "testing id %s - that folder is a production copy or a stray second "
            "test item; refusing to replace it unseen" % (seen, TEST_ITEM_ID))

    if args.dry_run:
        with tempfile.TemporaryDirectory(prefix="rftd-testing-") as tmp:
            candidate = os.path.join(tmp, "RoTD-Testing")
            build(candidate)
        print(f"dry run    OK - would deploy to {dest}")
        CANONICAL.remove_rival(dest, dry_run=True)
        if not args.no_push:
            print(f"would push item {TEST_ITEM_ID} \"{TEST_TITLE}\" ({TEST_VISIBILITY}) via steamcmd")
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
    print(f"           updates unlisted item {TEST_ITEM_ID}")

    # The production item and this one carry the same 13 mod ids, so only one of
    # them may be staged at a time - see CANONICAL.remove_rival for the engine
    # reason. Note the canonical run above CANNOT do this for us: it is invoked
    # with --dest pointing at a temp candidate, whose basename is neither item,
    # so its own rival_of returns None by design.
    CANONICAL.remove_rival(dest, dry_run=False)

    # The push happens HERE, after the identity rewrite and the swap - never in
    # the canonical child, which would have shipped the production identity.
    if not args.no_push:
        CANONICAL.push_workshop(dest, args)


if __name__ == "__main__":
    CANONICAL.hold_console(main)
