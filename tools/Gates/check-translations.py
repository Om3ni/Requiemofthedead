#!/usr/bin/env python3
# check-translations - every referenced translation key exists in every
# shipped language.
#
# WHY (2026-08-25). O&E shipped a whole Workshop sandbox section with no
# Spanish at all - a Spanish client showed the raw Sandbox_OE_WorkshopEnable
# key - and nothing could see it: ES carried eight page names where EN had
# nine, and the gap sat there from the day the section was added. The check
# is mechanical, so it belongs to a machine (the same argument that bought
# check-kahlua and check-versions).
#
# THREE CHECKS per mod:
#
#   1. REFERENCED KEYS EXIST IN EN (fails). Every `translation = X` in the
#      mod's sandbox-options.txt must have `Sandbox_X` in EN. EN is the
#      reference language - a key missing there shows raw for everyone.
#   2. EVERY OTHER LANGUAGE MATCHES EN (fails on missing). For each non-EN
#      language the mod ships, every EN key in the SAME file must be present.
#      A missing key shows raw for that language's clients - the O&E case.
#   3. ORPHANS (advisory). A key present in a translation file but absent
#      from EN, or an EN Sandbox key no sandbox-options.txt references, is
#      probably a rename's leftover. Reported, never fails: an orphan shows
#      nobody anything wrong, and some Sandbox keys (page names,
#      section headers) are referenced from lua rather than options files.
#      Advisory means a PERSON decides - do not "fix" one without reading it.
#
# Only key PRESENCE is compared. Values are prose in a human language;
# nothing mechanical can check them.

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
MODS = ROOT / "RequiemOfTheDead" / "Contents" / "mods"

# Two reference forms with different key shapes: `translation = X` names the
# label key Sandbox_X directly; `valueTranslation = X` names an enum's shared
# per-value label FAMILY, which the engine expands to Sandbox_X_option1..N -
# the bare Sandbox_X is never asked for and legitimately does not exist.
LABEL_REF = re.compile(r'^\s*translation\s*=\s*([A-Za-z0-9_]+)', re.M)
VALUE_REF = re.compile(r'^\s*value[Tt]ranslation\s*=\s*([A-Za-z0-9_]+)', re.M)
KEY = re.compile(r'"([A-Za-z0-9_.]+)"\s*:')


def keys_of(path):
    # The files are JSON-shaped; keys are all we need, and a regex tolerates
    # the trailing-comma looseness PZ's own reader allows.
    return set(KEY.findall(path.read_text(encoding="utf-8", errors="replace")))


def main():
    problems = 0
    advisories = []

    for mod in sorted(p for p in MODS.iterdir() if p.is_dir()):
        translate = mod / "42" / "media" / "lua" / "shared" / "Translate"
        en_dir = translate / "EN"
        opts = mod / "42" / "media" / "sandbox-options.txt"

        refs = set()
        value_refs = set()
        namespaces = set()
        if opts.is_file():
            text = opts.read_text(encoding="utf-8", errors="replace")
            refs = {"Sandbox_" + m for m in LABEL_REF.findall(text)}
            value_refs = {"Sandbox_" + m for m in VALUE_REF.findall(text)}
            # `option RFTDOddsAndEnds.WorkshopEnable` - the namespace names the
            # sandbox PAGE, whose title key Sandbox_<namespace> the engine
            # resolves on its own, with no `translation =` line anywhere.
            namespaces = set(re.findall(r'^\s*option\s+([A-Za-z0-9_]+)\.',
                                        text, re.M))

        en_files = {}
        if en_dir.is_dir():
            for f in sorted(en_dir.iterdir()):
                if f.is_file():
                    en_files[f.name] = keys_of(f)

        # 1. referenced keys exist in EN
        en_sandbox = en_files.get("Sandbox.json", set())
        for ref in sorted(refs):
            if ref not in en_sandbox:
                print(f"TRANSLATIONS  {mod.name}: sandbox-options references "
                      f"{ref} but EN/Sandbox.json does not define it")
                problems += 1
        for ref in sorted(value_refs):
            if (ref + "_option1") not in en_sandbox:
                print(f"TRANSLATIONS  {mod.name}: sandbox-options "
                      f"valueTranslation references {ref} but EN/Sandbox.json "
                      f"has no {ref}_option1")
                problems += 1

        # 2. every other language carries every EN key, file by file
        if translate.is_dir():
            for lang_dir in sorted(p for p in translate.iterdir()
                                   if p.is_dir() and p.name != "EN"):
                for fname, en_keys in en_files.items():
                    lf = lang_dir / fname
                    if not lf.is_file():
                        print(f"TRANSLATIONS  {mod.name}: {lang_dir.name} has "
                              f"no {fname} (EN has {len(en_keys)} keys)")
                        problems += 1
                        continue
                    lk = keys_of(lf)
                    for k in sorted(en_keys - lk):
                        print(f"TRANSLATIONS  {mod.name}: {lang_dir.name}/"
                              f"{fname} is missing {k} - shows the raw key "
                              f"to that language's clients")
                        problems += 1
                    for k in sorted(lk - en_keys):
                        advisories.append(f"{mod.name}: {lang_dir.name}/"
                                          f"{fname} has {k} that EN lacks")
                # a language file EN does not have at all
                for lf in sorted(lang_dir.iterdir()):
                    if lf.is_file() and lf.name not in en_files:
                        advisories.append(f"{mod.name}: {lang_dir.name}/"
                                          f"{lf.name} has no EN counterpart")

        # 3. unreferenced EN Sandbox keys (labels only). Three key shapes
        # are auto-referenced by the engine and are NOT orphans:
        #   _tooltip        rides its base key
        #   _optionN        an enum dropdown's per-value label, rides its base
        #   Sandbox_<ns>    the sandbox PAGE title for an option namespace
        for k in sorted(en_sandbox - refs):
            if k.endswith("_tooltip") or not k.startswith("Sandbox_"):
                continue
            base = re.sub(r"_option\d+$", "", k)
            if base != k and (base in refs or base in value_refs):
                continue
            if k[len("Sandbox_"):] in namespaces:
                continue
            if refs:
                advisories.append(f"{mod.name}: EN Sandbox key {k} is not "
                                  f"referenced by sandbox-options.txt")

    if advisories:
        print(f"advisory ({len(advisories)} orphan(s), a person decides - "
              "renames leave these behind):")
        for a in advisories[:20]:
            print("  " + a)
        if len(advisories) > 20:
            print(f"  ... and {len(advisories) - 20} more (run with a pipe "
                  "through findstr to see a mod)")

    if problems == 0:
        print("translations: every referenced key defined, every shipped "
              "language complete. Clean.")
        return 0
    print(f"translations: {problems} problem(s).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
