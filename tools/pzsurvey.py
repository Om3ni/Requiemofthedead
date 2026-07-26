#!/usr/bin/env python3
"""
pzsurvey.py - Project Zomboid players.db  ->  self-contained HTML survey report.

Decodes every character blob in a PZ (Build 42) players.db byte-exact from the raw
IsoPlayer serialization, then writes a single self-contained .html file: a server-wide
"what is this DB made of" dashboard + a searchable/sortable/expandable table of every
survivor. No dependencies beyond the Python standard library.

USAGE
    python pzsurvey.py players.db                       # -> players.report.html
    python pzsurvey.py players.db -o report.html
    python pzsurvey.py players.db --tables both         # include localPlayers too
    python pzsurvey.py players.db --title "My Server"
    python pzsurvey.py players.db --json data.json      # also dump the raw decoded data

Tested against Build 42 worldversion 247. If a future PZ version changes the save
format, decoding stops cleanly and the offending row is reported (see --strict).
"""
import struct, json, argparse, sqlite3, sys, os, re

# ============================================================================
#  Binary reader (Java ByteBuffer = big-endian)
# ============================================================================
class R:
    def __init__(s, d): s.d = d; s.p = 0
    def rem(s): return len(s.d) - s.p
    def _n(s, n):
        if s.p + n > len(s.d): raise EOFError(f"want {n}@{s.p}, have {s.rem()}")
    def u8(s):  s._n(1); v = s.d[s.p]; s.p += 1; return v
    def b(s):   return s.u8() != 0
    def s16(s): s._n(2); v = struct.unpack_from(">h", s.d, s.p)[0]; s.p += 2; return v
    def u16(s): s._n(2); v = struct.unpack_from(">H", s.d, s.p)[0]; s.p += 2; return v
    def s32(s): s._n(4); v = struct.unpack_from(">i", s.d, s.p)[0]; s.p += 4; return v
    def s64(s): s._n(8); v = struct.unpack_from(">q", s.d, s.p)[0]; s.p += 8; return v
    def f32(s): s._n(4); v = struct.unpack_from(">f", s.d, s.p)[0]; s.p += 4; return round(v, 6)
    def f64(s): s._n(8); v = struct.unpack_from(">d", s.d, s.p)[0]; s.p += 8; return v
    def utf(s):
        n = s.u16()
        if n == 0: return ""
        s._n(n); v = s.d[s.p:s.p+n].decode("utf-8", "replace"); s.p += n; return v
    def rgb(s): return [s.u8(), s.u8(), s.u8()]

# ============================================================================
#  ModData (se.krka.kahlua.j2se.KahluaTableImpl): 0=str 1=double 2=table 3=bool
# ============================================================================
def mod_val(r, t):
    if t == 0: return r.utf()
    if t == 1: return r.f64()
    if t == 3: return r.b()
    if t == 2: return mod_tbl(r)
    raise ValueError(f"bad ModData type {t}@{r.p}")

def mod_tbl(r):
    n = r.s32(); o = {}
    for _ in range(n):
        k = mod_val(r, r.u8()); v = mod_val(r, r.u8()); o[k] = v
    return o

# ============================================================================
#  Sub-object savers reverse-engineered from the engine
# ============================================================================
def item_visual(r):  # ItemVisual.save
    f = r.u8()
    v = {"fullType": r.utf(), "altModel": r.utf(), "clothingItem": r.utf()}
    if f & 1:  v["tint"] = r.rgb()
    if f & 2:  v["baseTexture"] = r.u8()
    if f & 4:  v["textureChoice"] = r.u8()
    if f & 8:  v["hue"] = r.f32()
    if f & 16: v["decal"] = r.utf()
    for a in ("blood", "dirt", "holes", "basicPatches", "denimPatches", "leatherPatches"):
        n = r.u8(); [r.u8() for _ in range(n)]
    return {k: val for k, val in v.items() if val not in ("", None)}

def human_visual(r):  # HumanVisual.save
    f = r.u8(); v = {}
    if f & 4: v["hairColor"] = r.rgb()
    if f & 2: v["beardColor"] = r.rgb()
    if f & 8: v["skinColor"] = r.rgb()
    v["bodyHair"] = r.u8(); v["skinTexture"] = r.u8(); v["zombieRotStage"] = r.u8()
    if f & 64: v["skinTextureName"] = r.utf()
    if f & 16: v["beardModel"] = r.utf()
    if f & 32: v["hairModel"] = r.utf()
    for a in ("blood", "dirt", "holes"):
        n = r.u8(); [r.u8() for _ in range(n)]
    nbv = r.u8()
    v["bodyVisuals"] = [item_visual(r) for _ in range(nbv)]
    v["nonAttachedHair"] = r.utf()
    f2 = r.u8()
    if f2 & 4: v["naturalHairColor"] = r.rgb()
    if f2 & 2: v["naturalBeardColor"] = r.rgb()
    return v

def scan_strings(body):  # find 2-byte-len-prefixed printable UTF-8 strings in an item body
    out = []; i = 0; n = len(body)
    while i + 2 <= n:
        ln = struct.unpack_from(">H", body, i)[0]
        if 2 <= ln <= 64 and i + 2 + ln <= n:
            c = body[i+2:i+2+ln]
            if all(32 <= x < 127 for x in c):
                s = c.decode("ascii")
                if re.search(r'[A-Za-z]', s) and (('.' in s) or ('_' in s) or (' ' in s) or s.isalnum()):
                    out.append(s); i += 2 + ln; continue
        i += 1
    return out

def read_item(r):  # InventoryItem.loadItem: length-prefixed, so we skip by dataLen
    dataLen = r.s32(); start = r.p
    reg = r.s16(); saveType = r.u8()
    body = r.d[start:start+dataLen]
    strs = scan_strings(body)
    ft = next((x for x in strs if '.' in x and ' ' not in x), None)
    cname = None
    for j, x in enumerate(strs):
        if x == "customName" and j + 1 < len(strs): cname = strs[j+1]
    r.p = start + dataLen
    return {"registryID": reg, "type": ft, "customName": cname}

def read_container(r):  # ItemContainer.save + CompressIdenticalItems
    c = {"type": r.utf(), "explored": r.b()}
    cnt = r.s16(); items = []
    for _ in range(cnt):
        identical = r.s32()
        it = read_item(r); it["count"] = identical
        for _ in range(max(0, identical - 1)): r.s32()  # id list
        items.append(it)
    c["itemGroups"] = items
    c["hasBeenLooted"] = r.b(); c["capacity"] = r.s32()
    return c

def survivor_desc(r):  # SurvivorDesc.save
    d = {"id": r.s32(), "forename": r.utf(), "surname": r.utf(), "torso": r.utf(),
         "gender": "female" if r.s32() == 1 else "male", "profession": r.utf()}
    if r.s32() == 1:
        d["extra"] = [r.utf() for _ in range(r.s32())]
    xb = r.s32(); d["xpBoost"] = {r.utf(): r.s32() for _ in range(xb)}
    d["voicePrefix"] = r.utf(); d["voicePitch"] = r.f32(); d["voiceType"] = r.s32()
    return d

STAT_NAMES = ["ANGER","BOREDOM","DISCOMFORT","ENDURANCE","FATIGUE","FITNESS","FOOD_SICKNESS",
 "HUNGER","IDLENESS","INTOXICATION","MORALE","NICOTINE_WITHDRAWAL","PAIN","PANIC","POISON",
 "SANITY","SICKNESS","STRESS","TEMPERATURE","THIRST","UNHAPPINESS","WETNESS","ZOMBIE_FEVER","ZOMBIE_INFECTION"]
def stats(r): return {STAT_NAMES[i]: r.f32() for i in range(24)}

BODY_PARTS = ["Hand_L","Hand_R","ForeArm_L","ForeArm_R","UpperArm_L","UpperArm_R","Torso_Upper",
 "Torso_Lower","Head","Neck","Groin","UpperLeg_L","UpperLeg_R","LowerLeg_L","LowerLeg_R","Foot_L","Foot_R"]
def body_part(r):  # BodyPart fields
    p = {}
    isCut = r.b(); p["bitten"] = r.b(); p["scratched"] = r.b(); bandaged = r.b()
    p["bleeding"] = r.b(); p["deepWounded"] = r.b(); p["fakeInfected"] = r.b(); p["infected"] = r.b()
    p["health"] = r.f32()
    if bandaged: p["bandageLife"] = r.f32()
    if r.b(): p["woundInfectionLevel"] = r.f32()
    for _ in range(7): r.f32()  # cut/bite/scratch/bleed/alcohol/pain/deepwound times
    p["haveGlass"] = r.b(); p["getBandageXp"] = r.b(); stitched = r.b(); r.f32()
    p["getStitchXp"] = r.b(); p["getSplintXp"] = r.b(); r.f32()  # fractureTime
    splint = r.b()
    if splint: r.f32()
    p["haveBullet"] = r.b(); r.f32(); p["needBurnWash"] = r.b(); r.f32()
    r.utf(); r.utf()  # splintItem, bandageType
    for _ in range(6): r.f32()  # cut2/wetness/stiffness/comfrey/garlic/plantain
    p["isCut"] = isCut; p["bandaged"] = bandaged; p["stitched"] = stitched; p["splint"] = splint
    return p
def body_damage(r):  # BodyDamage.save
    parts = {BODY_PARTS[i]: body_part(r) for i in range(17)}
    # saveMainFields
    r.f32(); r.b(); r.f32(); r.s32(); r.b(); r.f32(); r.f32(); r.f32(); r.f32(); r.f32(); r.f32()
    if r.b():  # Thermoregulator.save
        for _ in range(8): r.f32()
        nn = r.s32()
        for _ in range(nn):
            r.s32(); [r.f32() for _ in range(9)]
    return {"parts": parts}

def xp(r):  # XP inner class (starts with CharacterTraits.save)
    nt = r.s32(); traits = [r.utf() for _ in range(nt)]
    x = {"traits": traits, "totalXp": r.f32(), "level": r.s32(), "lastLevel": r.s32()}
    n = r.s32(); x["xpMap"] = {r.utf(): r.f32() for _ in range(n)}
    n = r.s32(); x["perkLevels"] = {r.utf(): r.s32() for _ in range(n)}
    n = r.s32()
    for _ in range(n): r.utf(); r.f32(); r.u8(); r.u8()  # xp multipliers
    return x

def fitness(r):  # Fitness.save
    n = r.s32(); [(r.utf(), r.f32()) for _ in range(n)]
    n = r.s32(); [(r.utf(), r.s32()) for _ in range(n)]
    n = r.s32(); [(r.utf(), r.f32()) for _ in range(n)]
    n = r.s32(); [r.utf() for _ in range(n)]
    n = r.s32(); [(r.utf(), r.s64()) for _ in range(n)]

def craft_history(r):  # PlayerCraftHistory.save (UTF-16 keys)
    n = r.s32(); out = {}
    for _ in range(n):
        kl = r.s32()
        key = r.d[r.p:r.p+kl*2].decode("utf-16-be", "replace"); r.p += kl*2
        out[key] = {"craftCount": r.s32(), "lastCraftTime": r.f64()}
    return out

# ============================================================================
#  Full IsoPlayer save  (IsoPlayer.save -> IsoGameCharacter.save -> IsoMovingObject.save)
#  Records byte offsets per section for size attribution.
# ============================================================================
def decode(blob):
    r = R(blob); o = {"_blobLen": len(blob)}
    sec = []
    def ck(l): sec.append((l, r.p))
    ck("header")
    o["header"] = {"serialize": r.u8(), "classId": r.u8(), "offsetX": r.f32(), "offsetY": r.f32(),
                   "x": r.f32(), "y": r.f32(), "z": r.f32(), "forwardDir": r.s32()}
    ck("modData")
    if r.u8() == 1: o["modData"] = mod_tbl(r)
    ck("descriptor")
    if r.u8() == 1: o["descriptor"] = survivor_desc(r)
    ck("visual");    o["visual"] = human_visual(r)
    ck("inventory"); o["inventory"] = read_container(r)
    o["asleep"] = r.b(); r.f32()
    ck("stats");      o["stats"] = stats(r)
    ck("bodyDamage"); o["bodyDamage"] = body_damage(r)
    ck("xp/traits");  o["xp"] = xp(r)
    o["leftHandItemIdx"] = r.s32(); o["rightHandItemIdx"] = r.s32()
    o["onFire"] = r.b(); [r.f32() for _ in range(8)]  # drug effects
    ck("readBooks")
    n = r.s32(); o["readBooks"] = [{"type": r.utf(), "pages": r.s32()} for _ in range(n)]
    r.f32()  # reduceInfectionPower
    ck("knownRecipes")
    n = r.s32(); o["knownRecipes"] = [r.utf() for _ in range(n)]
    r.s32(); r.f32(); r.f32(); r.f32()  # lastHourSleeped, smoke, beard, hair
    [r.u8() for _ in range(15)]  # cheat flags
    ck("readLiterature")
    n = r.s32(); o["readLiterature"] = {r.utf(): r.s32() for _ in range(n)}
    n = r.s32(); o["readPrintMedia"] = [r.utf() for _ in range(n)]
    r.s64()  # lastAnimalPet
    n = r.s32(); o["cheats"] = [r.u8() for _ in range(n)]
    # IsoPlayer.save
    ck("isoPlayer")
    o["hoursSurvived"] = r.f64(); o["zombieKills"] = r.s32()
    n = r.u8(); o["wornItems"] = [{"location": r.utf(), "itemIdx": r.s16()} for _ in range(n)]
    o["primaryHandIdx"] = r.s16(); o["secondaryHandIdx"] = r.s16()
    o["survivorKills"] = r.s32()
    o["nutrition"] = {k: r.f32() for k in ["calories","proteins","lipids","carbohydrates","weight"]}
    o["allChatMuted"] = r.b(); o["tagPrefix"] = r.utf()
    o["tagColor"] = [r.f32(), r.f32(), r.f32()]; o["displayName"] = r.utf()
    o["showTag"] = r.b(); o["factionPvp"] = r.b(); o["autoDrink"] = r.b(); o["extraInfoFlags"] = r.u8()
    if r.u8() == 1:
        o["vehicle"] = {"x": r.f32(), "y": r.f32(), "seat": r.u8(), "engineRunning": r.b()}
    n = r.s32(); [(r.s64(), r.s64()) for _ in range(n)]  # mechanicsItems
    ck("fitness"); fitness(r)
    n = r.s16(); [r.s16() for _ in range(n)]  # alreadyReadBook registry ids
    ck("knownMediaLines")
    n = r.s16(); o["knownMediaLines"] = [r.utf() for _ in range(n)]
    o["voiceType"] = r.u8()
    ck("craftHistory"); o["craftHistory"] = craft_history(r)
    ck("_end")
    o["_sections"] = {sec[i][0]: sec[i+1][1] - sec[i][1] for i in range(len(sec)-1)}
    o["_bytesRemaining"] = r.rem()
    return o

def modkey_sizes(blob):  # bytes each top-level ModData key occupies
    r = R(blob)
    r.u8(); r.u8(); [r.f32() for _ in range(5)]; r.s32()
    if r.u8() != 1: return {}
    n = r.s32(); sizes = {}
    for _ in range(n):
        key = mod_val(r, r.u8()); start = r.p
        mod_val(r, r.u8()); sizes[str(key)] = r.p - start
    return sizes

# ============================================================================
#  Build the compact dataset the report renders from
# ============================================================================
SEC = ["header","modData","descriptor","visual","inventory","stats","bodyDamage","xp/traits",
       "readBooks","knownRecipes","readLiterature","knownMediaLines","fitness","isoPlayer","craftHistory"]

def _table_columns(cur, table):
    return [c[1] for c in cur.execute(f"PRAGMA table_info({table})")]

def build_dataset(db_path, tables, strict=False):
    con = sqlite3.connect(db_path); cur = con.cursor()
    have = {r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    want = []
    if tables in ("network", "both") and "networkPlayers" in have: want.append("networkPlayers")
    if tables in ("local", "both") and "localPlayers" in have: want.append("localPlayers")
    if not want:
        raise SystemExit(f"No matching player tables in {db_path} (have: {sorted(have)})")

    records = []; agg_sec = {k: 0 for k in SEC}; agg_mod = {}
    n_alive = n_dead = n_inf = 0; tot = 0; errors = 0

    for table in want:
        cols = _table_columns(cur, table)
        has_user = "username" in cols; has_steam = "steamid" in cols
        rows = cur.execute(f"SELECT * FROM {table}").fetchall()
        for row in rows:
            d = dict(zip(cols, row))
            blob = d.get("data")
            if not blob: continue
            blob = bytes(blob)
            try:
                o = decode(blob)
                if o["_bytesRemaining"] != 0 and strict:
                    raise ValueError(f"{o['_bytesRemaining']} trailing bytes")
            except Exception as ex:
                errors += 1
                sys.stderr.write(f"  ! skip {table} id={d.get('id')} ({d.get('username') or d.get('name')}): {ex}\n")
                continue
            tot += len(blob)
            desc = o.get("descriptor", {})
            inv = []
            for g in o["inventory"]["itemGroups"]:
                t = g["type"] or f"reg#{g['registryID']}"
                for _ in range(g["count"]): inv.append(t)
            def hand(i): return inv[i] if 0 <= i < len(inv) else None
            bd = o["bodyDamage"]["parts"]
            is_inf = bool(o.get("modData", {}).get("bitten")) or any(p.get("infected") for p in bd.values())
            dead = bool(d.get("isDead"))
            if dead: n_dead += 1
            elif is_inf: n_inf += 1
            else: n_alive += 1
            for k in SEC: agg_sec[k] += o["_sections"].get(k, 0)
            msz = modkey_sizes(blob)
            for k, v in msz.items(): agg_mod[k] = agg_mod.get(k, 0) + v
            items = []
            for g in o["inventory"]["itemGroups"]:
                t = g["type"] or f"<reg#{g['registryID']}>"
                cn = g["customName"] if g["customName"] and g["customName"] != t else None
                items.append([t, cn, g["count"]])
            worn = [[w["location"], hand(w["itemIdx"])] for w in o["wornItems"]]
            worn = [w for w in worn if w[1]]
            records.append({
                "id": d.get("id"), "ac": d.get("username") or d.get("name"),
                "fn": desc.get("forename"), "sn": desc.get("surname"),
                "g": "f" if desc.get("gender") == "female" else "m", "pr": desc.get("profession"),
                "st": str(d.get("steamid") or ""), "dead": int(dead), "inf": int(is_inf),
                "b": len(blob), "x": round(o["header"]["x"]), "y": round(o["header"]["y"]), "z": round(o["header"]["z"]),
                "hr": round(o["hoursSurvived"], 1), "zk": o["zombieKills"], "sk": o["survivorKills"],
                "wt": round(o["nutrition"]["weight"], 1),
                "sec": [o["_sections"].get(k, 0) for k in SEC],
                "mod": {k: v for k, v in msz.items() if v >= 150},
                "tr": o["xp"]["traits"],
                "pk": {k: v for k, v in o["xp"]["perkLevels"].items() if v > 0},
                "it": items, "wo": worn,
                "ph": hand(o["primaryHandIdx"]), "osh": hand(o["secondaryHandIdx"]),
                "rc": len(o["knownRecipes"]), "md": len(o["knownMediaLines"]), "bk": len(o["readBooks"]),
                "at": {k: round(v) for k, v in o.get("modData", {}).get("AdaptiveTraits", {}).items() if isinstance(v, (int, float))},
                "cf": {k: v["craftCount"] for k, v in o["craftHistory"].items()},
            })
    records.sort(key=lambda r: -r["b"])
    if errors: sys.stderr.write(f"  ({errors} rows skipped)\n")
    return {
        "meta": {"count": len(records), "totalBytes": tot,
                 "alive": n_alive, "dead": n_dead, "infected": n_inf,
                 "secOrder": SEC, "aggSec": agg_sec,
                 "aggMod": dict(sorted(agg_mod.items(), key=lambda kv: -kv[1])[:20])},
        "records": records,
    }

# ============================================================================
#  HTML template (self-contained; data injected at __DATA__)
# ============================================================================
TPL = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<style>
:root{
  --bg:#141613;--panel:#1b1f1a;--panel2:#20241f;--line:#2c322b;
  --ink:#c9cfc4;--ink-dim:#8b9285;--ink-face:#e7ebe2;
  --amber:#e0a83e;--amber-dim:#9c7a33;
  --inv:#e0a83e;--rec:#7f9b57;--med:#c8564a;--mod:#5a8f96;--oth:#5c6157;
  --alive:#7f9b57;--inf:#c8564a;--dead:#6b6f64;
}
@media (prefers-color-scheme:light){:root{
  --bg:#e9e6db;--panel:#f3f0e7;--panel2:#eae7dc;--line:#d3cec0;
  --ink:#2e3128;--ink-dim:#6a6a5c;--ink-face:#1c1e17;--amber:#a5711a;--amber-dim:#b58a3a;
  --inv:#b07d1c;--rec:#5f7a3a;--med:#a63f34;--mod:#3f7078;--oth:#8a8778;
  --alive:#5f7a3a;--inf:#a63f34;--dead:#8a8778;}}
:root[data-theme="dark"]{--bg:#141613;--panel:#1b1f1a;--panel2:#20241f;--line:#2c322b;
  --ink:#c9cfc4;--ink-dim:#8b9285;--ink-face:#e7ebe2;--amber:#e0a83e;--amber-dim:#9c7a33;
  --inv:#e0a83e;--rec:#7f9b57;--med:#c8564a;--mod:#5a8f96;--oth:#5c6157;
  --alive:#7f9b57;--inf:#c8564a;--dead:#6b6f64;}
:root[data-theme="light"]{--bg:#e9e6db;--panel:#f3f0e7;--panel2:#eae7dc;--line:#d3cec0;
  --ink:#2e3128;--ink-dim:#6a6a5c;--ink-face:#1c1e17;--amber:#a5711a;--amber-dim:#b58a3a;
  --inv:#b07d1c;--rec:#5f7a3a;--med:#a63f34;--mod:#3f7078;--oth:#8a8778;
  --alive:#5f7a3a;--inf:#a63f34;--dead:#8a8778;}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
  font-family:ui-monospace,"Cascadia Mono","Cascadia Code",Consolas,"DejaVu Sans Mono",monospace;
  font-size:13.5px;line-height:1.5;-webkit-font-smoothing:antialiased}
.wrap{max-width:1160px;margin:0 auto;padding:0 18px 90px}
a{color:var(--amber);text-decoration:none}
.tabnum,.num{font-variant-numeric:tabular-nums}
.mast{border-top:3px solid var(--amber);padding:24px 0 14px}
.mast .kicker{color:var(--amber);letter-spacing:.32em;font-size:11px;text-transform:uppercase}
.mast h1{font-size:25px;margin:6px 0 4px;letter-spacing:.05em;color:var(--ink-face);text-transform:uppercase;font-weight:700;text-wrap:balance}
.mast .lede{color:var(--ink-dim);max-width:78ch}
.mast .lede b{color:var(--ink)}
.eyebrow{font-size:10.5px;letter-spacing:.2em;text-transform:uppercase;color:var(--ink-dim)}
.mt{margin-top:12px}
.muted{color:var(--ink-dim);font-size:11.5px}
.kpis{display:grid;grid-template-columns:repeat(6,1fr);gap:1px;background:var(--line);border:1px solid var(--line);margin:18px 0}
.kpi{background:var(--panel);padding:11px 12px}
.kpi .n{font-size:19px;color:var(--ink-face)}
.kpi .l{font-size:10px;color:var(--ink-dim);text-transform:uppercase;letter-spacing:.13em}
.kpi.inf .n{color:var(--inf)} .kpi.alive .n{color:var(--alive)} .kpi.dead .n{color:var(--dead)}
.dash{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin:8px 0 6px}
.pan{background:var(--panel);border:1px solid var(--line);padding:14px 15px}
.pan h3{margin:0 0 10px;font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:var(--ink-face);font-weight:700}
.brow{display:grid;grid-template-columns:150px 1fr 66px 44px;align-items:center;gap:9px;font-size:11.5px;margin-bottom:3px}
.brow .bl{color:var(--ink-dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.btrack{height:9px;background:var(--panel2);border:1px solid var(--line)}
.bfill{display:block;height:100%}
.brow .bb{text-align:right;color:var(--ink-face)} .brow .bp{text-align:right;color:var(--ink-dim)}
.seg-inv{background:var(--inv)} .seg-rec{background:var(--rec)} .seg-med{background:var(--med)}
.seg-mod{background:var(--mod)} .seg-oth{background:var(--oth)}
.callout{border-left:3px solid var(--med);background:var(--panel2);padding:9px 12px;margin-top:10px;font-size:12px;color:var(--ink)}
.callout b{color:var(--med)}
.hist{display:flex;align-items:flex-end;gap:3px;height:110px;margin-top:6px}
.hbar{flex:1;background:var(--amber);min-height:2px;opacity:.85}.hbar:hover{opacity:1}
.hlabels{display:flex;gap:3px;margin-top:4px}
.hlabels span{flex:1;font-size:8.5px;color:var(--ink-dim);text-align:center;overflow:hidden;white-space:nowrap}
.controls{position:sticky;top:0;z-index:5;background:var(--bg);padding:14px 0 10px;border-bottom:1px solid var(--line);margin-top:26px;display:flex;flex-wrap:wrap;gap:10px;align-items:center}
.controls input,.controls select{background:var(--panel);border:1px solid var(--line);color:var(--ink);font-family:inherit;font-size:13px;padding:6px 9px}
.controls input{flex:1;min-width:180px}
.fbtns{display:flex;gap:1px;border:1px solid var(--line)}
.fbtn{background:var(--panel);color:var(--ink-dim);border:none;font-family:inherit;font-size:11px;letter-spacing:.1em;text-transform:uppercase;padding:6px 11px;cursor:pointer}
.fbtn.on{background:var(--amber);color:#141613}
.count{color:var(--ink-dim);font-size:11.5px;white-space:nowrap}
.tablewrap{border:1px solid var(--line);border-top:none;background:var(--panel)}
table{border-collapse:collapse;width:100%}
thead th{position:sticky;top:52px;background:var(--panel2);z-index:4;font-size:10px;letter-spacing:.14em;text-transform:uppercase;color:var(--ink-dim);font-weight:400;text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);cursor:pointer;white-space:nowrap}
thead th.n{text-align:right}
tbody td{padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:middle;font-size:12px}
tbody tr.rowmain{cursor:pointer} tbody tr.rowmain:hover{background:var(--panel2)}
.rk{color:var(--amber-dim);width:38px;text-align:right}
.pn b{color:var(--ink-face);font-weight:700}
.pn .ac{display:block;font-size:10.5px;color:var(--ink-dim)}
td.n{text-align:right;color:var(--ink-face)}
.bar{display:flex;height:10px;width:150px;background:var(--panel2);border:1px solid var(--line);overflow:hidden}
.bar .seg{height:100%;display:block}
.pill{font-size:9.5px;letter-spacing:.1em;padding:2px 7px;border:1px solid;text-transform:uppercase;white-space:nowrap}
.st-alive{color:var(--alive);border-color:var(--alive)} .st-inf{color:var(--inf);border-color:var(--inf)} .st-dead{color:var(--dead);border-color:var(--dead)}
tr.detailrow>td{padding:0;background:var(--panel2);border-bottom:2px solid var(--amber-dim)}
.detail{padding:16px 18px}
.metrics{display:grid;grid-template-columns:repeat(5,1fr);gap:1px;background:var(--line);border:1px solid var(--line);margin-bottom:14px}
.m{background:var(--panel);padding:7px 9px}
.m .ml{display:block;font-size:9.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--ink-dim)}
.m .mv{color:var(--ink-face);font-size:13px}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.block .eyebrow{margin-bottom:7px;display:block}.block.wide{grid-column:1/-1}
.chips{display:flex;flex-wrap:wrap;gap:5px}
.chip{font-size:11px;padding:2px 7px;border:1px solid var(--line);background:var(--panel);color:var(--ink)}
.chip.mod{border-color:var(--mod);color:var(--mod)}
.skills{display:grid;gap:4px}
.skill{display:grid;grid-template-columns:108px 1fr 20px;align-items:center;gap:8px;font-size:11.5px}
.sk-name{color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sk-bar{height:6px;background:var(--panel);border:1px solid var(--line)}.sk-fill{display:block;height:100%;background:var(--amber)}
.sk-lvl{text-align:right;color:var(--ink-face)}
.kvlist{display:grid;gap:2px}
.kv{display:flex;justify-content:space-between;gap:10px;font-size:11px;border-bottom:1px dotted var(--line);padding-bottom:2px}
.kv .k{color:var(--ink-dim)} .kv .v{color:var(--ink);text-align:right}
.inv{display:grid;grid-template-columns:1fr 1fr;gap:2px 20px}
.irow{display:flex;gap:7px;align-items:baseline;font-size:11.5px;border-bottom:1px dotted var(--line);padding:2px 0}
.itype{color:var(--ink-face)} .ix{color:var(--amber);font-size:10.5px} .icust{color:var(--ink-dim)}
.worn{display:grid;gap:2px}
.wrow{display:flex;gap:7px;font-size:11px;padding:1px 0}
.slot{color:var(--ink-dim);min-width:118px} .arrow{color:var(--amber-dim)} .witem{color:var(--ink)}
.fbrow{display:grid;grid-template-columns:150px 1fr 60px 42px;align-items:center;gap:9px;font-size:11px}
.fbl{color:var(--ink-dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fbt{height:7px;background:var(--panel);border:1px solid var(--line)}.fbf{display:block;height:100%}
.fbb{text-align:right;color:var(--ink-face)} .fbp{text-align:right;color:var(--ink-dim)}
details summary{cursor:pointer;list-style:none} details summary::-webkit-details-marker{display:none}
details summary::before{content:"\25B8 ";color:var(--amber)} details[open] summary::before{content:"\25BE "}
.footer{margin-top:40px;padding-top:14px;border-top:1px solid var(--line);color:var(--ink-dim);font-size:11px;max-width:80ch}
a:focus-visible,summary:focus-visible,.fbtn:focus-visible,tr.rowmain:focus-visible{outline:2px solid var(--amber);outline-offset:-2px}
@media (max-width:820px){.kpis{grid-template-columns:repeat(3,1fr)}.dash{grid-template-columns:1fr}.metrics{grid-template-columns:repeat(2,1fr)}.grid2{grid-template-columns:1fr}.inv{grid-template-columns:1fr}.bar{width:96px}thead th.hide,td.hide{display:none}}
</style></head><body>
<div class="wrap">
 <div class="mast">
  <div class="kicker">Records Division · Full Survey</div>
  <h1>__TITLE__</h1>
  <p class="lede">Every character in this <b>players.db</b> decoded byte-exact from the raw <b>IsoPlayer</b>
  serialization. Search, sort, and click any row for the full record. The dashboard shows what the whole
  database is <b>actually made of</b> - and where the bloat lives.</p>
 </div>
 <div id="kpis" class="kpis"></div>
 <div class="dash">
  <div class="pan"><h3>What the whole database is made of</h3><div id="aggSec"></div><div id="callout"></div></div>
  <div class="pan"><h3>Heaviest mod tables (server-wide)</h3><div id="aggMod"></div></div>
 </div>
 <div class="pan"><h3>Blob size distribution</h3><div id="hist" class="hist"></div><div id="histlabels" class="hlabels"></div></div>
 <div class="controls">
  <input id="search" type="search" placeholder="search name / account / profession / steamid..." autocomplete="off">
  <div class="fbtns" id="filters">
   <button class="fbtn on" data-f="all">All</button><button class="fbtn" data-f="alive">Alive</button>
   <button class="fbtn" data-f="inf">Infected</button><button class="fbtn" data-f="dead">Dead</button>
  </div>
  <select id="sort">
   <option value="b">Sort: blob size</option><option value="hr">Hours survived</option>
   <option value="zk">Zombie kills</option><option value="rc">Known recipes</option>
   <option value="md">Known media (recorded)</option><option value="name">Name A-Z</option>
  </select>
  <span class="count" id="count"></span>
 </div>
 <div class="tablewrap"><table>
  <thead><tr><th class="n">#</th><th>Survivor</th><th class="n">KB</th><th class="hide">Composition</th><th>Status</th><th class="n hide">Hours</th><th class="n hide">Z-kills</th></tr></thead>
  <tbody id="tbody"></tbody>
 </table></div>
 <div class="footer">Reconstructed from the Project Zomboid B42 engine serialization. Decoder validated when every
 record parses to zero bytes remaining. Quoted item labels are player-set custom names; &lt;reg#N&gt; = item type
 lives only in the runtime registry, not the save. Generated by pzsurvey.py.</div>
</div>
<script id="data" type="application/json">__DATA__</script>
<script>
const DB=JSON.parse(document.getElementById('data').textContent);
const R=DB.records,M=DB.meta,SEC=M.secOrder;
const IX={mod:SEC.indexOf('modData'),inv:SEC.indexOf('inventory'),rec:SEC.indexOf('knownRecipes'),med:SEC.indexOf('knownMediaLines')};
const SECLBL={header:'header',modData:'mod data',descriptor:'descriptor',visual:'visual/appearance',inventory:'inventory',stats:'stats',bodyDamage:'body damage','xp/traits':'xp + traits',readBooks:'read books',knownRecipes:'known recipes',readLiterature:'read literature',knownMediaLines:'known media (recorded)',fitness:'fitness',isoPlayer:'player fields',craftHistory:'craft history'};
const SECCLS={inventory:'seg-inv',knownRecipes:'seg-rec',knownMediaLines:'seg-med',modData:'seg-mod'};
const e=s=>String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const kb=b=>(b/1024).toFixed(1),mb=b=>(b/1048576).toFixed(2),nf=n=>Number(n).toLocaleString();
const nm=r=>((r.fn||'')+' '+(r.sn||'')).trim()||r.ac||'(unnamed)';
const stcls=r=>r.dead?'st-dead':(r.inf?'st-inf':'st-alive'),stlbl=r=>r.dead?'DECEASED':(r.inf?'INFECTED':'ALIVE');
function compBar(sec){const tot=sec.reduce((a,b)=>a+b,0)||1;const P=[[sec[IX.inv],'seg-inv'],[sec[IX.rec],'seg-rec'],[sec[IX.med],'seg-med'],[sec[IX.mod],'seg-mod']];let named=P.reduce((a,p)=>a+p[0],0),oth=Math.max(tot-named,0),h='';for(const[v,c]of P)if(v>0)h+=`<span class="seg ${c}" style="width:${(v/tot*100).toFixed(3)}%"></span>`;if(oth>0)h+=`<span class="seg seg-oth" style="width:${(oth/tot*100).toFixed(3)}%"></span>`;return `<div class="bar">${h}</div>`;}
const MODNAMES={DeadbandUIState:'Deadband',PhunZones:'PhunZones',AdaptiveTraits:'SOTO',infectionThreshold:'Dirge/RQ',projectRV_seat:'Reclamation',SOTOWeightFixed:'SOTO',BurdJournals:'BurdJournals',SRJ:'SkillJournal',QuickFits:'QuickFits',ParanormalZ_Data:'ParanormalZ'};
function detail(r){const tot=r.sec.reduce((a,b)=>a+b,0),mx=Math.max(...r.sec)||1;let fb='';SEC.forEach((k,i)=>{const v=r.sec[i];fb+=`<div class="fbrow"><span class="fbl">${e(SECLBL[k])}</span><span class="fbt"><span class="fbf ${SECCLS[k]||'seg-oth'}" style="width:${(v/mx*100).toFixed(2)}%"></span></span><span class="fbb">${nf(v)}</span><span class="fbp">${(v/tot*100).toFixed(1)}%</span></div>`;});
let mrows='';const me=Object.entries(r.mod||{}).sort((a,b)=>b[1]-a[1]);if(me.length){const mmx=me[0][1],mt=me.reduce((a,x)=>a+x[1],0);for(const[k,v]of me)mrows+=`<div class="fbrow"><span class="fbl">${e(k)}</span><span class="fbt"><span class="fbf seg-mod" style="width:${(v/mmx*100).toFixed(2)}%"></span></span><span class="fbb">${nf(v)}</span><span class="fbp">${(v/mt*100).toFixed(1)}%</span></div>`;}
const pk=Object.entries(r.pk||{}).sort((a,b)=>b[1]-a[1]||a[0].localeCompare(b[0]));let sk=pk.map(([n,l])=>`<div class="skill"><span class="sk-name">${e(n)}</span><span class="sk-bar"><span class="sk-fill" style="width:${l/10*100}%"></span></span><span class="sk-lvl">${l}</span></div>`).join('')||'<div class="muted">no skills</div>';
const at=Object.entries(r.at||{}).sort((a,b)=>b[1]-a[1]).slice(0,12);let atH=at.map(([k,v])=>`<div class="kv"><span class="k">${e(k)}</span><span class="v">${nf(v)}</span></div>`).join('')||'<div class="muted">none</div>';
let inv=(r.it||[]).map(it=>`<div class="irow"><span class="itype">${e(it[0])}</span>${it[2]>1?`<span class="ix">×${it[2]}</span>`:''}${it[1]?`<span class="icust">"${e(it[1])}"</span>`:''}</div>`).join('');const nItems=(r.it||[]).reduce((a,it)=>a+it[2],0);
let wo='';if(r.ph)wo+=`<div class="wrow"><span class="slot">primary hand</span><span class="arrow">→</span><span class="witem">${e(r.ph)}</span></div>`;if(r.osh&&r.osh!==r.ph)wo+=`<div class="wrow"><span class="slot">off-hand</span><span class="arrow">→</span><span class="witem">${e(r.osh)}</span></div>`;wo+=(r.wo||[]).map(w=>`<div class="wrow"><span class="slot">${e(w[0])}</span><span class="arrow">→</span><span class="witem">${e(w[1])}</span></div>`).join('');
const mods=[...new Set(Object.keys(r.mod||{}).map(k=>MODNAMES[k]).filter(Boolean))];const cf=Object.entries(r.cf||{}).sort((a,b)=>b[1]-a[1]);let craft=cf.map(([k,v])=>`<div class="kv"><span class="k">${e(k)}</span><span class="v">×${v}</span></div>`).join('')||'<div class="muted">none</div>';
const mv=(l,v)=>`<div class="m"><span class="ml">${l}</span><span class="mv">${v}</span></div>`;
return `<div class="detail"><div class="metrics">${mv('Profession',e(r.pr||'?'))}${mv('Gender',r.g==='f'?'female':'male')}${mv('Hours',r.hr)}${mv('Zombie kills',nf(r.zk))}${mv('Weight',r.wt+' kg')}${mv('Position',nf(r.x)+','+nf(r.y)+(r.z?' z'+r.z:''))}${mv('Recipes',nf(r.rc))}${mv('Books',r.bk)}${mv('Media lines',nf(r.md))}${mv('Steam',e(r.st))}</div>
<div class="grid2">
<div class="block"><span class="eyebrow">Traits · ${(r.tr||[]).length}</span><div class="chips">${(r.tr||[]).map(t=>`<span class="chip">${e(t)}</span>`).join('')||'<span class="muted">none</span>'}</div><span class="eyebrow" style="display:block;margin-top:12px">Mods on record</span><div class="chips">${mods.map(m=>`<span class="chip mod">${e(m)}</span>`).join('')||'<span class="muted">-</span>'}</div></div>
<div class="block"><span class="eyebrow">Skills · ${pk.length} trained</span><div class="skills">${sk}</div></div>
<div class="block wide"><details><summary><span class="eyebrow">Full byte breakdown - ${nf(tot)} bytes across ${SEC.filter((k,i)=>r.sec[i]>0).length} sections</span></summary><div style="margin-top:8px;display:grid;gap:3px">${fb}</div><span class="eyebrow" style="display:block;margin-top:12px">Inside "mod data" - per-mod tables</span><div style="margin-top:6px;display:grid;gap:3px">${mrows||'<div class="muted">none</div>'}</div></details></div>
<div class="block wide"><details><summary><span class="eyebrow">Inventory · ${nItems} items</span></summary><div class="inv" style="margin-top:8px">${inv||'<div class="muted">empty</div>'}</div></details></div>
<div class="block"><span class="eyebrow">Worn / equipped</span><div class="worn">${wo||'<div class="muted">none</div>'}</div></div>
<div class="block"><span class="eyebrow">SOTO adaptive-trait minutes</span><div class="kvlist">${atH}</div><span class="eyebrow" style="display:block;margin-top:12px">Craft history</span><div class="kvlist">${craft}</div></div>
</div></div>`;}
function dash(){const avg=M.totalBytes/M.count;document.getElementById('kpis').innerHTML=[['n',nf(M.count),'Characters'],['n',mb(M.totalBytes)+' MB','Total in DB'],['alive',nf(M.alive),'Alive'],['inf',nf(M.infected),'Infected'],['dead',nf(M.dead),'Dead'],['n',kb(avg)+' KB','Avg record']].map(([c,n,l])=>`<div class="kpi ${c==='n'?'':c}"><div class="n">${n}</div><div class="l">${l}</div></div>`).join('');
const as=M.aggSec,tot=Object.values(as).reduce((a,b)=>a+b,0),mx=Math.max(...Object.values(as));let h='';SEC.forEach(k=>{const v=as[k]||0;h+=`<div class="brow"><span class="bl">${e(SECLBL[k])}</span><span class="btrack"><span class="bfill ${SECCLS[k]||'seg-oth'}" style="width:${(v/mx*100).toFixed(2)}%"></span></span><span class="bb">${mb(v)} MB</span><span class="bp">${(v/tot*100).toFixed(1)}%</span></div>`;});document.getElementById('aggSec').innerHTML=h;
const dbui=M.aggMod.DeadbandUIState||0;let co='';if(dbui>0)co=`<div class="callout"><b>DeadbandUIState = ${mb(dbui)} MB</b> = <b>${(dbui/M.totalBytes*100).toFixed(0)}%</b> of the entire ${mb(M.totalBytes)} MB database. Project Zomboid never prunes ModData keys from mods that are no longer loaded, so a removed mod's data stays frozen in every character's save. The DB does not self-clean.</div>`;document.getElementById('callout').innerHTML=co;
const mm=Object.entries(M.aggMod);if(mm.length){const mmx=mm[0][1];document.getElementById('aggMod').innerHTML=mm.map(([k,v])=>`<div class="brow"><span class="bl">${e(k)}</span><span class="btrack"><span class="bfill seg-mod" style="width:${(v/mmx*100).toFixed(2)}%"></span></span><span class="bb">${mb(v)} MB</span><span class="bp">${nf(v)}B</span></div>`).join('');}
const bins=[0,10,20,30,40,50,60,70,80,90,100,1e9],labels=['<10','10','20','30','40','50','60','70','80','90','100+'],cnt=new Array(labels.length).fill(0);R.forEach(r=>{const k=r.b/1024;let i=bins.findIndex((b,j)=>k<bins[j+1]);if(i<0||i>=labels.length)i=labels.length-1;cnt[i]++;});const hmx=Math.max(...cnt)||1;document.getElementById('hist').innerHTML=cnt.map((c,i)=>`<div class="hbar" style="height:${c/hmx*100}%" title="${labels[i]} KB: ${c}"></div>`).join('');document.getElementById('histlabels').innerHTML=labels.map(l=>`<span>${l}</span>`).join('');}
let state={q:'',f:'all',sort:'b',open:new Set()};const tbody=document.getElementById('tbody');
function view(){let rows=R.filter(r=>{if(state.f==='alive'&&(r.dead||r.inf))return false;if(state.f==='inf'&&!r.inf)return false;if(state.f==='dead'&&!r.dead)return false;if(state.q){const s=((r.fn||'')+' '+(r.sn||'')+' '+(r.ac||'')+' '+(r.pr||'')+' '+(r.st||'')).toLowerCase();if(!s.includes(state.q))return false;}return true;});
const S=state.sort;rows.sort(S==='name'?(a,b)=>nm(a).localeCompare(nm(b)):(a,b)=>b[S]-a[S]);document.getElementById('count').textContent=`${rows.length} of ${R.length}`;let html='';
rows.forEach((r,i)=>{const op=state.open.has(r.id);html+=`<tr class="rowmain" data-id="${r.id}" tabindex="0"><td class="rk">${i+1}</td><td class="pn"><b>${e(nm(r))}</b><span class="ac">${e(r.ac||'')} · id ${r.id}</span></td><td class="n">${kb(r.b)}</td><td class="hide">${compBar(r.sec)}</td><td><span class="pill ${stcls(r)}">${stlbl(r)}</span></td><td class="n hide">${r.hr}</td><td class="n hide">${nf(r.zk)}</td></tr>`;if(op)html+=`<tr class="detailrow"><td colspan="7">${detail(r)}</td></tr>`;});
tbody.innerHTML=html;}
tbody.addEventListener('click',ev=>{const tr=ev.target.closest('tr.rowmain');if(!tr)return;const id=+tr.dataset.id;state.open.has(id)?state.open.delete(id):state.open.add(id);view();});
tbody.addEventListener('keydown',ev=>{if(ev.key==='Enter'){const tr=ev.target.closest('tr.rowmain');if(tr){ev.preventDefault();const id=+tr.dataset.id;state.open.has(id)?state.open.delete(id):state.open.add(id);view();}}});
document.getElementById('search').addEventListener('input',ev=>{state.q=ev.target.value.trim().toLowerCase();view();});
document.getElementById('sort').addEventListener('change',ev=>{state.sort=ev.target.value;view();});
document.getElementById('filters').addEventListener('click',ev=>{const b=ev.target.closest('.fbtn');if(!b)return;document.querySelectorAll('.fbtn').forEach(x=>x.classList.remove('on'));b.classList.add('on');state.f=b.dataset.f;view();});
dash();view();
</script></body></html>"""

def render(dataset, title):
    payload = json.dumps(dataset, separators=(",", ":"), default=str).replace("</", "<\\/")
    return TPL.replace("__TITLE__", title).replace("__DATA__", payload)

# ============================================================================
def main():
    ap = argparse.ArgumentParser(description="Decode a PZ players.db into a self-contained HTML survey report.")
    ap.add_argument("db", help="path to players.db")
    ap.add_argument("-o", "--out", help="output .html (default: <db>.report.html)")
    ap.add_argument("--tables", choices=["network", "local", "both"], default="network",
                    help="which player table(s) to read (default: network)")
    ap.add_argument("--title", help="report title (default derived from db filename)")
    ap.add_argument("--json", help="also write the raw decoded dataset to this .json")
    ap.add_argument("--strict", action="store_true", help="treat any trailing-byte mismatch as an error")
    a = ap.parse_args()
    if not os.path.exists(a.db): raise SystemExit(f"not found: {a.db}")
    title = a.title or (os.path.splitext(os.path.basename(a.db))[0] + " - Player Database").replace("_", " ")
    out = a.out or (os.path.splitext(a.db)[0] + ".report.html")
    sys.stderr.write(f"decoding {a.db} ...\n")
    ds = build_dataset(a.db, a.tables, a.strict)
    m = ds["meta"]
    sys.stderr.write(f"  {m['count']} characters, {m['totalBytes']/1048576:.2f} MB total "
                     f"(alive {m['alive']} / infected {m['infected']} / dead {m['dead']})\n")
    if a.json:
        json.dump(ds, open(a.json, "w"), separators=(",", ":"), default=str)
        sys.stderr.write(f"  wrote {a.json}\n")
    open(out, "w", encoding="utf-8").write(render(ds, title))
    sys.stderr.write(f"  wrote {out}  ({os.path.getsize(out)/1048576:.2f} MB)\n")

if __name__ == "__main__":
    main()
