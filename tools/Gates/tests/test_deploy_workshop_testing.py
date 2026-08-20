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
    "publication id removed": "\nid=" not in "\n" + text,
    "testing title installed": "title=RoTD:Testing\r\n" in text,
    "testing item is unlisted": "visibility=unlisted\r\n" in text,
    "description preserved": "description=unchanged\r\n" in text,
    "line endings preserved": "\n" not in text.replace("\r\n", ""),
}

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
# Publication-id RETENTION.
#
# Steam mints an id on the first upload and writes it back into the DEPLOYED
# workshop.txt. Before 2026-08-18 every later run rebuilt from the production
# manifest with the id stripped, overwrote the destination, and took the
# testing id with it - so the next upload silently created ANOTHER Workshop
# item instead of updating the one already published.
# ---------------------------------------------------------------------------
import tempfile

kept, kept_old = testing.test_manifest(source, "9988776655")
kept_text = kept.decode("utf-8")
checks["testing id is re-emitted"] = "id=9988776655\r\n" in kept_text
checks["production id is still removed"] = "id=3772176444" not in kept_text
checks["production id still reported"] = kept_old == "3772176444"
checks["retained id keeps its line position"] = (
    kept_text.index("id=9988776655") < kept_text.index("title=")
)
checks["retention does not disturb the rest"] = (
    "description=unchanged\r\n" in kept_text
    and "visibility=unlisted\r\n" in kept_text
)

# Reading the id back off a deployed folder.
tmp = tempfile.mkdtemp()
try:
    dest = os.path.join(tmp, "RoTD-Testing")
    os.makedirs(dest)
    manifest = os.path.join(dest, "workshop.txt")
    checks["absent folder yields no id"] = testing.deployed_test_id(
        os.path.join(tmp, "nope")) is None
    open(manifest, "w", encoding="utf-8").write(
        "version=1\r\ntitle=RoTD:Testing\r\nvisibility=unlisted\r\n")
    checks["first publish yields no id"] = testing.deployed_test_id(dest) is None
    open(manifest, "w", encoding="utf-8").write(
        "version=1\r\nid=9988776655\r\ntitle=RoTD:Testing\r\n")
    checks["published id is read back"] = testing.deployed_test_id(dest) == "9988776655"
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

failed = [name for name, passed in checks.items() if not passed]
if failed:
    for name in failed:
        print("FAIL deploy-workshop-testing: " + name)
    raise SystemExit(1)

print(f"deploy-workshop-testing: {len(checks)} passed, 0 failed")
