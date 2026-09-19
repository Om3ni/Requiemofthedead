"""Generate Dirge's RQPoise gunfire compression nodes by TRANSFORMING vanilla's.

===========================================================================
BROUGHT HOME 2026-09-17
===========================================================================
Written in the Bulwark lab as gen_poise_nodes.py, where the nodes were
BZPoise* keyed on BZPoised. When the lab's logic was ported into RFTDDirge
(slices 1-4) the thirteen nodes moved with it, renamed; when the lab was
scraped to a shell (slice 5) this generator came home, retargeted, so the
nodes have a regeneration path that still exists. It writes straight into
the Dirge payload:

    python "tools/Asset Tools/gen_poise_nodes.py"            (vanilla at VANILLA)
    python "tools/Asset Tools/gen_poise_nodes.py" <animsets>  (override the path)

Output is deterministic, so a diff after a run is the review. Shipping these
nodes changes the network animation checksum (AdvancedAnimator.load()
hashes every AnimSets file, :752-760), which is why server and clients take
them from the one Workshop item together.


===========================================================================
WHY THIS WAS REWRITTEN, 2026-09-05
===========================================================================
The first version SYNTHESISED each node from a fixed template: it read the clip
name out of vanilla and then emitted a node built from scratch with a hardcoded
event list. That silently discarded everything else vanilla's node carried. All
thirteen lost the `FallOnFront` event, and ShotBelly additionally lost
`m_DeferredBoneName=Bip01` / `m_deferredBoneAxis=Z` - the root-motion
declaration that decides whether a clip moves the CHARACTER or only the model.

The owner then reported specials that keep playing their walk animation while
making no forward progress. THE CAUSAL CHAIN IS NOT PROVEN - see FINDINGS F19 -
but shipping a node that drops vanilla's root-motion declaration and then
investigating why movement broke is the wrong order of work.

So this version does what RQFlinch's headers said that work did, and what
should have happened the first time: take vanilla's fully-resolved node and
change ONLY what has to change. Everything not in OVERRIDES is vanilla's,
verbatim - every event, and every field this script has never heard of.

===========================================================================
RESOLVING x_extends
===========================================================================
Vanilla's Shot nodes inherit from ShotDefault.xml and override ONE FIELD of ONE
condition, keyed by that condition's x_name GUID:

    ShotDefault.xml   x_name=0cee3750..  m_Name=hitreaction STRING m_Value=""
    Shot/ShotChestL   x_extends=../ShotDefault.xml
                      x_name=0cee3750..  m_Value=ShotChestL

so the merged condition is `hitreaction == "ShotChestL"`. Read alone, a child
node shows a condition with no name and no type, which is why an earlier
version of this script found almost nothing.

OUR NODES ARE STANDALONE, not extended: they are generated, so there is no
duplication to drift, and it avoids depending on x_extends resolving a relative
path from a MOD directory, which is unverified and would fail silently.

MELEE STRINGS ARE DELIBERATELY EXCLUDED (owner, 2026-09-05). The melee reaction
is short already and it is the player's hit feedback.
"""

import io
import os
import re
import sys

VANILLA = r"D:\Steam\steamapps\common\ProjectZomboid\media\AnimSets\zombie\hitreaction"
if len(sys.argv) > 1:
    VANILLA = sys.argv[1]

# Repo-relative, so the script is not tied to one checkout path.
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(
    HERE, "..", "..", "RequiemOfTheDead", "Contents", "mods", "RFTDDirge",
    "42", "media", "AnimSets", "zombie", "hitreaction"))

# The animation variable RQPoise asserts on a special (RQPoise.lua POISED).
VARIABLE = "RQPoised"
PREFIX = "RQPoise"

# Everything CombatManager.resolveHitReaction can return for a firearm
# (CombatManager.java:2313-2377), minus the three ShotHead* crits, which leave
# this state entirely for hitreaction-shothead-* and are a different lane.
GUNFIRE = [
    "ShotBelly", "ShotBellyStep", "ShotBellyStepBehind",
    "ShotChestL", "ShotChestR",
    "ShotChestStepL", "ShotChestStepR",
    "ShotLegL", "ShotLegR",
    "ShotShoulderL", "ShotShoulderR",
    "ShotShoulderStepL", "ShotShoulderStepR",
]

# The ONLY fields we change. Everything else is vanilla's.
#   m_SpeedScale         the mechanism - the state exits on ActiveAnimFinishing,
#                        so a faster clip is a shorter state.
#   blend times          zeroed, or a two-frame clip is mostly blend.
#   m_ConditionPriority  100 beats vanilla's 0 default without editing vanilla.
OVERRIDES = {
    "m_SpeedScale": "20.00",
    "m_BlendTime": "0.0",
    "m_BlendOutTime": "0.0",
    "m_ConditionPriority": "100",
}

FIELD_ORDER = [
    "m_AnimName", "m_DeferredBoneName", "m_deferredBoneAxis", "m_Looped",
    "m_EarlyTransitionOut", "m_BlendTime", "m_BlendOutTime", "m_SpeedScale",
    "m_Scalar", "m_Scalar2", "m_ConditionPriority",
]
KNOWN_FIELDS = FIELD_ORDER + ["m_Name"]

COND_RE = re.compile(r'<m_Conditions\s+x_name="([^"]+)"\s*>(.*?)</m_Conditions>', re.S)
EV_RE = re.compile(r'<m_Events\s+x_name="([^"]+)"\s*>(.*?)</m_Events>', re.S)
CFIELD_RE = re.compile(r"<(m_Name|m_Type|m_Value)>(.*?)</\1>", re.S)
EFIELD_RE = re.compile(r"<(m_EventName|m_Time|m_TimePc|m_ParameterValue)>(.*?)</\1>", re.S)

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<!--
  RQPoise - the {string} gunfire reaction, compressed.

  GENERATED by tools/Asset Tools/gen_poise_nodes.py (the Bulwark lab's
  generator, brought home 2026-09-17), which TRANSFORMS vanilla's {source}
  rather than rebuilding a node from a template. Everything here is vanilla's
  except the node name, our added condition, and four fields: m_SpeedScale,
  m_BlendTime, m_BlendOutTime and m_ConditionPriority. Every EVENT and every
  field such as m_DeferredBoneName is carried across untouched. Do not
  hand-edit one of these - regenerate.

  THE FIRST VERSION OF THIS SCRIPT DID NOT DO THAT, which is why these were
  regenerated on 2026-09-05. It synthesised nodes from a fixed template and so
  dropped vanilla's FallOnFront event from all thirteen, and ShotBelly's
  m_DeferredBoneName/m_deferredBoneAxis - the root-motion declaration that
  decides whether a clip moves the CHARACTER or only the model. Specials were
  reported walking on the spot. Copy and adjust; never rebuild.

  WHAT IT DOES. Chosen instead of vanilla's node whenever {variable} is true on
  the zombie, playing vanilla's own clip at twenty times speed. The state is
  still entered and the hit still lands in full; it is over in a frame or two
  instead of about a second, so a fast weapon can no longer re-trigger the
  reaction before the previous one ended. That re-trigger IS the stun-lock.

  WHY SPEED AND NOT REFUSAL. actiongroups/zombie/hitreaction/to_idle.xml exits
  on <eventOccurred>ActiveAnimFinishing</eventOccurred> - an ANIMATION event,
  not a flag - so shortening the animation genuinely shortens the state. It is
  also why a node MUST be selected here: a reaction with no matching node plays
  nothing, so the finish event never fires and a standing zombie has no exit at
  all (the single NoAnimConditionsPass escape requires bOnFloor).

  WHY IT WINS SELECTION. AnimNode.compareSelectionConditions orders by
  abstractness, then m_ConditionPriority, then condition count
  (AnimNode.java:283-306); AnimState.getAnimNodes takes the first node whose
  conditions pass and stops at the first lower-ranked one
  (AnimState.java:43-55). Vanilla's zombie nodes leave m_ConditionPriority at
  its 0 default, so 100 wins without modifying any of them. With {variable}
  false or absent this node fails its own condition - AnimCondition.check
  returns !boolValue for a variable that was never set - and vanilla's node is
  chosen exactly as before, so an ordinary zombie is untouched.
-->
"""


def resolve(path, depth=0):
    """Vanilla's node with x_extends merged: (fields, conditions, events)."""
    if depth > 6:
        raise RuntimeError("x_extends too deep at " + path)
    text = io.open(path, encoding="utf-8").read()

    fields, conds, events = {}, {}, {}
    parent = re.search(r'<animNode\s+x_extends="([^"]+)"', text)
    if parent:
        base = os.path.normpath(os.path.join(os.path.dirname(path),
                                             parent.group(1)))
        pf, pc, pe = resolve(base, depth + 1)
        fields, conds, events = dict(pf), dict(pc), dict(pe)

    # Scalars read GENERICALLY, after the containers are cut out, so a field
    # this script has never heard of still survives the round trip. Dropping
    # one is the exact bug this rewrite exists to fix.
    body = COND_RE.sub("", text)
    body = EV_RE.sub("", body)
    for name, value in re.findall(r"<(m_[A-Za-z0-9_]+)>(.*?)</\1>", body, re.S):
        fields[name] = value

    for guid_, chunk in COND_RE.findall(text):
        merged = dict(conds.get(guid_, {}))
        merged.update(dict(CFIELD_RE.findall(chunk)))
        conds[guid_] = merged
    for guid_, chunk in EV_RE.findall(text):
        merged = dict(events.get(guid_, {}))
        merged.update(dict(EFIELD_RE.findall(chunk)))
        events[guid_] = merged
    return fields, conds, events


def reactions_of(conds):
    """Every hitreaction string this node can match - there can be several.

    Shot/ShotBellyStepFromBehind.xml is the case that forced this: it extends
    ShotBellyStep.xml, keeps the inherited `hitreaction == ShotBellyStep` test,
    adds its own `hitreaction == ShotBellyStepBehind`, and separates them with a
    condition of m_Type OR. AnimCondition.pass treats OR as a group separator -
    conditions before it are one alternative, conditions after it another - so
    the node means (FromBehind AND ShotBellyStep) OR (ShotBellyStepBehind).

    Returning only the first match keyed that node under the wrong string and
    lost ShotBellyStepBehind entirely.
    """
    out = []
    for f in conds.values():
        if f.get("m_Name") == "hitreaction" and f.get("m_Type") == "STRING":
            value = f.get("m_Value")
            if value:
                out.append(value)
    return out


def guid(index, slot):
    return "rqpoise%02d-%04d-4000-8000-rftddirge" % (index, slot)


def emit(string, index, fields, conds, events, source):
    out = [HEADER.format(string=string, source=source, variable=VARIABLE)]
    out.append("<animNode>\n")
    out.append("\t<m_Name>%s%s</m_Name>\n" % (PREFIX, string))

    merged = dict(fields)
    merged.pop("m_Name", None)
    merged.update(OVERRIDES)
    for name in FIELD_ORDER:
        if name in merged:
            out.append("\t<%s>%s</%s>\n" % (name, merged[name], name))
    for name in sorted(merged):
        if name not in KNOWN_FIELDS:
            out.append("\t<%s>%s</%s>\n" % (name, merged[name], name))

    slot = 1
    out.append('\t<m_Conditions x_name="%s">\n' % guid(index, slot))
    out.append("\t\t<m_Name>%s</m_Name>\n" % VARIABLE)
    out.append("\t\t<m_Type>BOOL</m_Type>\n")
    out.append("\t\t<m_Value>true</m_Value>\n")
    out.append("\t</m_Conditions>\n")
    slot += 1

    # CONDITIONS ARE OURS, DELIBERATELY, and this is the one place we do not
    # copy vanilla. Our node targets exactly ONE reaction string, so it needs
    # exactly two tests: are we poised, and is this that reaction. Carrying
    # vanilla's set across would drag in FromBehind specialisations and the OR
    # grouping that separates them, which are how VANILLA chooses between two
    # clips of the same reaction - a choice we do not make, because at twenty
    # times speed the two are indistinguishable and one node wins both on
    # priority anyway.
    #
    # FIELDS and EVENTS are a different matter and ARE copied verbatim: those
    # carry root motion and state flags, and dropping them is what broke the
    # first version.
    out.append('\t<m_Conditions x_name="%s">\n' % guid(index, slot))
    out.append("\t\t<m_Name>hitreaction</m_Name>\n")
    out.append("\t\t<m_Type>STRING</m_Type>\n")
    out.append("\t\t<m_Value>%s</m_Value>\n" % string)
    out.append("\t</m_Conditions>\n")
    slot += 1

    # EVERY vanilla event, verbatim. This is the half the first version lost.
    for _g, e in sorted(events.items(),
                        key=lambda kv: kv[1].get("m_EventName", "")):
        if not e.get("m_EventName"):
            continue
        out.append('\t<m_Events x_name="%s">\n' % guid(index, slot))
        out.append("\t\t<m_EventName>%s</m_EventName>\n" % e["m_EventName"])
        if "m_Time" in e:
            out.append("\t\t<m_Time>%s</m_Time>\n" % e["m_Time"])
        if "m_TimePc" in e:
            out.append("\t\t<m_TimePc>%s</m_TimePc>\n" % e["m_TimePc"])
        out.append("\t\t<m_ParameterValue>%s</m_ParameterValue>\n"
                   % e.get("m_ParameterValue", ""))
        out.append("\t</m_Events>\n")
        slot += 1

    out.append("</animNode>\n")
    return "".join(out)


def main():
    found = {}
    for root, _dirs, files in os.walk(VANILLA):
        for name in files:
            if not name.endswith(".xml"):
                continue
            path = os.path.join(root, name)
            try:
                fields, conds, events = resolve(path)
            except Exception as exc:                          # noqa: BLE001
                print("  skip %s (%s)" % (name, exc))
                continue
            if not fields.get("m_AnimName"):
                continue                                       # abstract base
            # Once every declared string is collected, "fewest conditions wins"
            # picks correctly on its own. ShotBellyStep is declared by both
            # ShotBellyStep.xml (one condition) and its FromBehind child (four),
            # so the base wins; ShotBellyStepBehind is declared ONLY by the
            # child, so the child wins and brings its own clip with it.
            for reaction in reactions_of(conds):
                cur = found.get(reaction)
                if cur is None or len(conds) < len(cur[1]):
                    found[reaction] = (fields, conds, events, name)

    missing = [s for s in GUNFIRE if s not in found]
    if missing:
        print("FAIL no vanilla node for: " + ", ".join(missing))
        print("known: " + ", ".join(sorted(found)))
        return 1

    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    for index, string in enumerate(GUNFIRE, start=1):
        fields, conds, events, source = found[string]
        io.open(os.path.join(OUT, PREFIX + string + ".xml"), "w",
                encoding="utf-8", newline="\n").write(
                    emit(string, index, fields, conds, events, source))
        evs = sorted(e.get("m_EventName", "?") for e in events.values())
        extra = [k for k in ("m_DeferredBoneName", "m_deferredBoneAxis")
                 if k in fields]
        print("  %-22s <- %-26s events=[%s]%s"
              % (string, source, " ".join(evs),
                 "  carried=" + ",".join(extra) if extra else ""))

    print("OK wrote %d nodes" % len(GUNFIRE))
    print("NOT covered (melee, by owner decision): "
          + ", ".join(sorted(s for s in found if not s.startswith("Shot"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
