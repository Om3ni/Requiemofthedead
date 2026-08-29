#!/usr/bin/env python3
"""Regression cases for the Workshop Lua ship-source transformation."""

import importlib.util
import os
import sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", ".."))
path = os.path.join(root, "tools", "Deploy Tools", "deploy-workshop.py")
spec = importlib.util.spec_from_file_location("deploy_workshop_test", path)
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)
stamp_path = os.path.join(root, "tools", "Deploy Tools", "stamp-license.py")
stamp_spec = importlib.util.spec_from_file_location("stamp_license_test", stamp_path)
stamper = importlib.util.module_from_spec(stamp_spec)
stamp_spec.loader.exec_module(stamper)

cases = {
    "line and block comments": (
        "-- header notes\n"
        "\n"
        "local alpha = 1 -- inline note\n"
        "-- another block\n"
        "-- with two lines\n"
        "\n"
        "local beta = 2\n"
    ),
    "token boundary": "local answer = left- --[[ removed ]]-right\n",
    "comment markers in strings": (
        "local quoted = \"-- live string\"\n"
        "local long = [=[first\n\n\n-- still a string\nlast]=]\n"
    ),
    "long comment between tokens": "local joined = before--[=[ note ]=]after\n",
    "canonical notice already present": (
        deploy.SPDX + "\n\nlocal value = 7\n\n" + "\n".join(deploy.FOOT) + "\n"
    ),
}

failures = []
expected_notice = [deploy.SPDX, *deploy.FOOT]
for name, source in cases.items():
    final, _, _ = deploy.prepare_lua(source)
    if deploy.scan_lua(source)[0] != deploy.scan_lua(final)[0]:
        failures.append(name + ": token stream changed")
    comments = [final[start:end] for start, end in deploy.find_comments(final)]
    if comments != expected_notice:
        failures.append(name + ": final licence/comment policy drifted")
    repeated, _, _ = deploy.prepare_lua(final)
    if repeated != final:
        failures.append(name + ": transformation is not idempotent")

literal = cases["comment markers in strings"]
literal_final = deploy.prepare_lua(literal)[0]
if "[=[first\n\n\n-- still a string\nlast]=]" not in literal_final:
    failures.append("blank lines or comment markers inside a long string changed")

crlf_source = "local alpha = 1 -- note\r\n\r\n-- block\r\nlocal beta = 2\r\n"
crlf_final = deploy.prepare_lua(crlf_source)[0]
if "\n" in crlf_final.replace("\r\n", ""):
    failures.append("CRLF source gained mixed line endings")
if "\r\n\r\n\r\n" in crlf_final:
    failures.append("CRLF blank runs were not collapsed")

plain = deploy.prepare_lua("\n\nlocal alpha = 1\n\n\nlocal beta = 2\n\n")[0]
if "\n\n\n" in plain:
    failures.append("ordinary blank runs were not collapsed")

# ---------------------------------------------------------------------------
# MUTUAL EXCLUSION between the two staged Workshop items.
#
# This is the only DELETE in the deploy path, and it deletes a folder the script
# did not create - so it gets pinned rather than trusted. The hazard it exists
# for is silent: both items carry the same 13 mod ids, and with both staged the
# engine picks between them by enumeration order, usually landing on the stale
# one while the deploy still reports success.
# ---------------------------------------------------------------------------
import tempfile

rival_checks = 0
with tempfile.TemporaryDirectory(prefix="rftd-rival-") as _tmp:
    _prod = os.path.join(_tmp, deploy.PRODUCTION_ITEM)
    _test = os.path.join(_tmp, deploy.TESTING_ITEM)
    _other = os.path.join(_tmp, "ModTemplate")
    for _d in (_prod, _test, _other):
        os.makedirs(os.path.join(_d, "Contents", "mods"))

    def _rc(ok, message):
        global rival_checks
        if ok:
            rival_checks += 1
        else:
            failures.append(message)

    _rc(deploy.rival_of(_prod) == _test, "production's rival is not the testing item")
    _rc(deploy.rival_of(_test) == _prod, "testing's rival is not the production item")
    # A custom --dest has no rival: the pairing only means anything for the two
    # names, and a stray third folder alongside them is not ours to touch.
    _rc(deploy.rival_of(_other) is None, "a non-suite folder was claimed as a rival")

    # A --dry-run that deletes is worse than one that lies.
    deploy.remove_rival(_prod, dry_run=True)
    _rc(os.path.isdir(_test), "--dry-run deleted the rival item")

    deploy.remove_rival(_prod, dry_run=False)
    _rc(not os.path.isdir(_test), "the rival item survived a real run")
    _rc(os.path.isdir(_prod), "removing the rival took the deployed item with it")
    _rc(os.path.isdir(_other), "removing the rival ate an unrelated staged folder")

    # Idempotent: the common case is that no rival is staged at all.
    deploy.remove_rival(_prod, dry_run=False)
    _rc(os.path.isdir(_prod), "a second removal disturbed the deployed item")


repository_stamp = stamper.stamp("local answer = 42\n")
if repository_stamp is None or deploy.SPDX not in repository_stamp \
        or not repository_stamp.rstrip().endswith(deploy.FOOT[-1]):
    failures.append("repository stamper drifted from the shared notice")

# ---------------------------------------------------------------------------
# THE CACHED-SESSION PROBE.
#
# steamcmd's password prompt needs a real console; a child on a piped stdin
# gets nothing typed into it and fails ninety seconds later claiming a bad
# password (owner, 2026-08-28). The push therefore refuses to start until a
# session is cached, so this probe is what stands between the deploy and that
# dead prompt - and a false "cached" reading puts it straight back.
# ---------------------------------------------------------------------------
probe_checks = 0
with tempfile.TemporaryDirectory(prefix="rftd-steam-") as _tmp:
    _steamcmd = os.path.join(_tmp, "steamcmd.exe")
    open(_steamcmd, "w").close()
    _cfg_dir = os.path.join(_tmp, "config")
    os.makedirs(_cfg_dir)
    _cfg = os.path.join(_cfg_dir, "config.vdf")

    def _pc(ok, message):
        global probe_checks
        if ok:
            probe_checks += 1
        else:
            failures.append(message)

    # No config at all: unknown, NOT "cached" - a fresh steamcmd must still be
    # able to reach the login path rather than be told it is already logged in.
    _pc(deploy.credentials_cached(_steamcmd, "someone") is None,
        "a missing config.vdf did not read as unknown")

    # A config with no Accounts block is a definite "never logged in".
    open(_cfg, "w").write('"InstallConfigStore"\n{\n\t"Software" "x"\n}\n')
    _pc(deploy.credentials_cached(_steamcmd, "someone") is False,
        "a config without an Accounts block did not read as uncached")

    # The real shape: Accounts holds one nested block per account. The brace
    # counter must span that nesting - a non-greedy match stops at the inner
    # close and never sees the second account.
    open(_cfg, "w").write(
        '"InstallConfigStore"\n{\n'
        '\t"Software"\n\t{\n\t\t"Valve" "1"\n\t}\n'
        '\t"Accounts"\n\t{\n'
        '\t\t"FirstUser"\n\t\t{\n\t\t\t"SteamID" "76561190000000001"\n\t\t}\n'
        '\t\t"SecondUser"\n\t\t{\n\t\t\t"SteamID" "76561190000000002"\n\t\t}\n'
        '\t}\n}\n')
    _pc(deploy.credentials_cached(_steamcmd, "FirstUser") is True,
        "a cached account was not recognised")
    _pc(deploy.credentials_cached(_steamcmd, "SecondUser") is True,
        "the second account in the block was missed - brace counting broke")
    # Steam is case-insensitive about the account name and records whatever
    # case was typed; a case mismatch must not send a logged-in user to login.
    _pc(deploy.credentials_cached(_steamcmd, "firstuser") is True,
        "a case-different account name was not matched")
    _pc(deploy.credentials_cached(_steamcmd, "Stranger") is False,
        "an account that never logged in read as cached")
    # A name that appears ELSEWHERE in the document is not a login.
    open(_cfg, "w").write(
        '"InstallConfigStore"\n{\n\t"LastUser" "Ghost"\n'
        '\t"Accounts"\n\t{\n\t}\n}\n')
    _pc(deploy.credentials_cached(_steamcmd, "Ghost") is False,
        "a name outside the Accounts block counted as a cached login")

if failures:
    for failure in failures:
        print("FAIL deploy-workshop: " + failure)
    raise SystemExit(1)

print(f"deploy-workshop: {len(cases) + 4 + rival_checks + probe_checks} passed, 0 failed")
