"""Identity and safety tests for the isolated Workshop testing deployer."""

import importlib.util
import os
import sys


root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
path = os.path.join(root, "tools", "Deploy Tools", "deploy-workshop-testing.py")
spec = importlib.util.spec_from_file_location("deploy_workshop_testing_test", path)
testing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(testing)


source = (
    b"version=1\r\n"
    b"id=3772176444\r\n"
    b"title=Requiem of the Dead: Season One\r\n"
    b"description=unchanged\r\n"
    b"visibility=public\r\n"
)
prepared, old_id = testing.test_manifest(source)
text = prepared.decode("utf-8")

checks = {
    "old publication id returned": old_id == "3772176444",
    "production id removed": "id=3772176444" not in text,
    "minted testing id installed": "id=" + testing.TEST_ITEM_ID + "\r\n" in text,
    "testing title installed": "title=RoTD:Testing\r\n" in text,
    "testing item is unlisted": "visibility=unlisted\r\n" in text,
    "description preserved": "description=unchanged\r\n" in text,
    "line endings preserved": "\n" not in text.replace("\r\n", ""),
    # The id takes the production id's POSITION, not the end of the file -
    # workshop.txt is read line-wise by both the game and our own reader.
    "testing id keeps the id line position":
        text.index("id=" + testing.TEST_ITEM_ID) < text.index("title="),
}

# A production manifest that somehow carries the TESTING id is an identity
# swap, not a deploy: refuse rather than "rewrite" it into itself.
try:
    testing.test_manifest(source.replace(b"3772176444",
                                         testing.TEST_ITEM_ID.encode()))
except ValueError:
    checks["swapped identity refused"] = True
else:
    checks["swapped identity refused"] = False

for bad in (
    source.replace(b"id=3772176444\r\n", b""),
    source.replace(b"id=3772176444", b"id=abc"),
    source.replace(b"id=3772176444\r\n", b"id=1\r\nid=2\r\n"),
):
    try:
        testing.test_manifest(bad)
    except ValueError:
        pass
    else:
        checks["invalid id shape rejected"] = False
        break
else:
    checks["invalid id shapes rejected"] = True


# ---------------------------------------------------------------------------
# The deployed-folder probe.
#
# With the minted id baked in (2026-08-28) this is a SAFETY check rather than
# a source of truth: main() refuses a folder wearing any other digit id, so a
# production copy sitting at the testing path is never silently replaced -
# and, more to the point, never pushed to Steam under the testing identity.
# ---------------------------------------------------------------------------
import tempfile

tmp = tempfile.mkdtemp()
try:
    dest = os.path.join(tmp, "RoTD-Testing")
    os.makedirs(dest)
    manifest = os.path.join(dest, "workshop.txt")
    checks["absent folder yields no id"] = testing.deployed_test_id(
        os.path.join(tmp, "nope")) is None
    open(manifest, "w", encoding="utf-8").write(
        "version=1\r\ntitle=RoTD:Testing\r\nvisibility=unlisted\r\n")
    checks["id-less folder yields no id"] = testing.deployed_test_id(dest) is None
    open(manifest, "w", encoding="utf-8").write(
        "version=1\r\nid=" + testing.TEST_ITEM_ID + "\r\ntitle=RoTD:Testing\r\n")
    checks["deployed id is read back"] = (
        testing.deployed_test_id(dest) == testing.TEST_ITEM_ID)
    # A BOM must not hide the id - the manifest is written with one.
    open(manifest, "w", encoding="utf-8-sig").write(
        "version=1\r\nid=1234567890\r\ntitle=RoTD:Testing\r\n")
    checks["BOM does not hide the id"] = testing.deployed_test_id(dest) == "1234567890"
    # Two ids is ambiguous - refuse rather than pick one.
    open(manifest, "w", encoding="utf-8").write(
        "version=1\r\nid=1\r\nid=2\r\n")
    try:
        testing.deployed_test_id(dest)
    except RuntimeError:
        checks["ambiguous deployed ids refused"] = True
    else:
        checks["ambiguous deployed ids refused"] = False
finally:
    import shutil as _sh
    _sh.rmtree(tmp, ignore_errors=True)

# ---------------------------------------------------------------------------
# The push targets the right item, and only ever that one.
# ---------------------------------------------------------------------------
canonical = testing.CANONICAL
checks["testing id is not the production id"] = (
    testing.TEST_ITEM_ID != "3772176444")

push_tmp = tempfile.mkdtemp()
try:
    staged = os.path.join(push_tmp, testing.CANONICAL.TESTING_ITEM)
    os.makedirs(staged)
    open(os.path.join(staged, "workshop.txt"), "w", encoding="utf-8").write(
        "version=1\r\nid=" + testing.TEST_ITEM_ID + "\r\n"
        "title=RoTD:Testing\r\ndescription=one\r\ndescription=two\r\n"
        "visibility=unlisted\r\n")
    read = canonical.read_manifest(staged)
    checks["push reads the testing id"] = read["id"] == testing.TEST_ITEM_ID
    checks["push reads the unlisted flag"] = read["visibility"] == "unlisted"
    checks["push joins the description lines"] = read["description"] == "one\ntwo"

    vdf = canonical.build_vdf(read, staged, "note")
    checks["vdf carries the app id"] = '"appid" "108600"' in vdf
    checks["vdf targets the testing item"] = (
        '"publishedfileid" "' + testing.TEST_ITEM_ID + '"' in vdf)
    # unlisted is 3 - a wrong number here would silently PUBLISH the test item.
    checks["vdf keeps the item unlisted"] = '"visibility" "3"' in vdf
    checks["vdf points at the staged tree"] = '"contentfolder" "' + staged + '"' in vdf
    checks["vdf carries the multi-line description"] = '"description" "one\ntwo"' in vdf
finally:
    import shutil as _sh2
    _sh2.rmtree(push_tmp, ignore_errors=True)

# A quote in a value cannot be escaped in steamcmd's VDF dialect; the builder
# must refuse rather than emit a document that means something else.
class _Exit(Exception):
    pass

_real_exit = canonical.sys.exit
canonical.sys.exit = lambda *a: (_ for _ in ()).throw(_Exit(a))
try:
    canonical.build_vdf(
        {"id": "1", "title": 'a "quoted" title', "visibility": "unlisted",
         "description": "d"}, "C:\\x", "note")
except _Exit:
    checks["a quote in the manifest is refused"] = True
else:
    checks["a quote in the manifest is refused"] = False
finally:
    canonical.sys.exit = _real_exit

failed = [name for name, passed in checks.items() if not passed]
if failed:
    for name in failed:
        print("FAIL deploy-workshop-testing: " + name)
    raise SystemExit(1)

print(f"deploy-workshop-testing: {len(checks)} passed, 0 failed")
