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

failed = [name for name, passed in checks.items() if not passed]
if failed:
    for name in failed:
        print("FAIL deploy-workshop-testing: " + name)
    raise SystemExit(1)

print(f"deploy-workshop-testing: {len(checks)} passed, 0 failed")
