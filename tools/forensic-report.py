#!/usr/bin/env python3
"""forensic-report.py - turn forensic ring segments into one readable HTML page.

WHY THIS EXISTS: the ring is deliberately unfiltered at the WRITE side, because a
sensor that decides what matters before it records has already thrown away the
thing you will want later. The consequence is that reading it raw is hopeless -
in a real 19-hour Guardian sample, 74% of records were one third-party vehicle
library's chatter (that_damn_lib/setVehicleData + silentPartInstall). Filtering
belongs HERE, at presentation, where a mistake costs a click instead of evidence.

Output is a single self-contained .html file - no CDN, no server, no build step.
Open it, un-tick the noise, read the meat. Filters are live in the page, so the
same file answers different questions without regenerating it.

RING ORDER IS NOT FILE ORDER. Segments are a wrap-around ring: 003 can be older
than 000. Everything is sorted by envelope "t" (epoch seconds), so feeding the
whole directory in any order produces one correct timeline.

TWO NAMING ERAS, same reason validate_jsonl.py handles both. Current segments are
"000.<stream>.jsonl.log"; before that "000.jsonl.log"; before 42.20 a bare
".jsonl". Lua can neither rename nor delete, so a live cache holds all three and
matching is on the NAME, not Path.suffix.

THE sid FIELD IS APPROXIMATE and the page says so. RDIdentity.sidApprox is
string.format("%.0f", getSteamID()); Kahlua hands that Java long over as a double,
so anything above 2^53 is lossy. It is stable per player - fine for correlation -
but it is NOT the real account id and must not be used to ban. Where a real
17-digit id appears inside an args payload, the page surfaces it as "real id seen".

Usage:
    python tools/forensic-report.py <log-or-dir> [more...] -o report.html
    python tools/forensic-report.py "%USERPROFILE%/Zomboid/Lua/RFTD/forensic"
    python tools/forensic-report.py guardiant.log --open

Stdlib only, per family convention.
"""

import argparse
import html
import json
import re
import sys
import webbrowser
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

# Producers that are high-volume and low-signal by default. Not dropped - just
# pre-muted in the page, one click from visible. Keyed by "module/command"; a bare
# module name mutes all of its commands.
DEFAULT_MUTED = [
    "that_damn_lib",
    "ISLogSystem/writeLog",
]

# Any module contributing more than this share of the file is auto-muted on load
# even if it is not listed above, so a NEW chatty mod does not require a code edit
# before the report is usable. Always reported in the page as auto-muted.
AUTO_MUTE_SHARE = 0.20

STEAMID = re.compile(r"\b7656119\d{10}\b")


def is_log(p: Path) -> bool:
    n = p.name
    return n.endswith(".jsonl.log") or n.endswith(".jsonl")


def collect(paths):
    out = []
    for raw in paths:
        p = Path(raw)
        if p.is_dir():
            out.extend(sorted(q for q in p.rglob("*") if q.is_file() and is_log(q)))
        elif p.is_file():
            out.append(p)
        else:
            print(f"  ! not found: {p}", file=sys.stderr)
    return out


def load(files):
    recs, bad = [], 0
    for f in files:
        stream = f.parent.name
        with f.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except Exception:
                    bad += 1
                    continue
                x = r.get("x") or {}
                if not isinstance(x, dict):
                    x = {"value": x}
                # A real steam id inside the payload beats the lossy envelope sid.
                real = None
                m = STEAMID.search(json.dumps(x, ensure_ascii=False))
                if m and m.group(0) != str(x.get("sid") or ""):
                    real = m.group(0)
                recs.append({
                    "t": r.get("t") or 0,
                    "d": r.get("d"),
                    "e": r.get("e") or "?",
                    "m": r.get("m") or "?",
                    "s": r.get("s") or "?",
                    "u": r.get("u") or "?",
                    "l": r.get("l"),
                    "stream": stream,
                    "module": str(x.get("module") or ""),
                    "command": str(x.get("command") or ""),
                    "access": str(x.get("access") or ""),
                    "sid": str(x.get("sid") or ""),
                    "realsid": real,
                    "est": x.get("est") or 0,
                    "pos": _pos(x),
                    "x": x,
                })
    recs.sort(key=lambda r: r["t"])
    return recs, bad


def _pos(x):
    try:
        if x.get("x") is None:
            return ""
        return f"{int(x['x'])},{int(x['y'])},{int(x['z'])}"
    except Exception:
        return ""


def key_of(r):
    """The filter identity of a record: module/command, or the event if no module."""
    if r["module"]:
        return f"{r['module']}/{r['command']}" if r["command"] else r["module"]
    return r["e"]


def build_mutes(recs):
    total = max(1, len(recs))
    by_mod = Counter(r["module"] or r["e"] for r in recs)
    muted, auto = set(), set()
    for k in {key_of(r) for r in recs}:
        mod = k.split("/", 1)[0]
        if k in DEFAULT_MUTED or mod in DEFAULT_MUTED:
            muted.add(k)
    for mod, n in by_mod.items():
        if n / total > AUTO_MUTE_SHARE:
            for k in {key_of(r) for r in recs if (r["module"] or r["e"]) == mod}:
                if k not in muted:
                    muted.add(k)
                    auto.add(k)
    return sorted(muted), sorted(auto)


def render(recs, bad, files, out_path):
    muted, auto = build_mutes(recs)
    ts = [r["t"] for r in recs if r["t"]]
    span = ""
    if ts:
        a = datetime.fromtimestamp(min(ts), timezone.utc).strftime("%Y-%m-%d %H:%M")
        b = datetime.fromtimestamp(max(ts), timezone.utc).strftime("%Y-%m-%d %H:%M")
        hours = (max(ts) - min(ts)) / 3600
        span = f"{a} → {b} UTC &middot; {hours:.1f}h &middot; {len(recs)/max(hours,0.01):.0f}/h"

    payload = {
        "recs": [{
            "t": r["t"], "iso": datetime.fromtimestamp(r["t"], timezone.utc).strftime("%m-%d %H:%M:%S") if r["t"] else "",
            "d": r["d"], "e": r["e"], "m": r["m"], "u": r["u"], "l": r["l"],
            "stream": r["stream"], "key": key_of(r), "access": r["access"],
            "sid": r["sid"], "realsid": r["realsid"], "est": r["est"], "pos": r["pos"],
            "x": r["x"],
        } for r in recs],
        "muted": muted,
        "auto": auto,
    }
    blob = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")

    srcs = "".join(f"<li>{html.escape(str(f))}</li>" for f in files)
    doc = _TEMPLATE.replace("__DATA__", blob) \
                   .replace("__SPAN__", span) \
                   .replace("__NBAD__", str(bad)) \
                   .replace("__NREC__", str(len(recs))) \
                   .replace("__SRCS__", srcs)
    out_path.write_text(doc, encoding="utf-8")


_TEMPLATE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>RFTD forensic report</title>
<style>
:root{color-scheme:dark light;
 --bg:#12141a;--panel:#191c24;--line:#2a2f3a;--fg:#dfe3ec;--dim:#8b93a7;
 --accent:#7aa2f7;--warn:#e0af68;--bad:#f7768e;--ok:#9ece6a;}
@media (prefers-color-scheme:light){:root{
 --bg:#f6f7fa;--panel:#fff;--line:#dfe3ea;--fg:#1c2028;--dim:#5d6577;
 --accent:#2f6feb;--warn:#b5730a;--bad:#c33;--ok:#2f7d32;}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
 font:13px/1.5 ui-monospace,SFMono-Regular,Consolas,monospace}
header{padding:14px 18px;border-bottom:1px solid var(--line);background:var(--panel);
 position:sticky;top:0;z-index:5}
h1{margin:0 0 4px;font-size:15px;letter-spacing:.02em}
.meta{color:var(--dim);font-size:12px}
.wrap{display:flex;align-items:flex-start;gap:0}
aside{width:290px;flex:0 0 290px;padding:14px;border-right:1px solid var(--line);
 position:sticky;top:74px;max-height:calc(100vh - 74px);overflow:auto}
main{flex:1;padding:14px 18px;min-width:0}
h2{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--dim);
 margin:16px 0 6px}
h2:first-child{margin-top:0}
label{display:flex;gap:7px;align-items:baseline;padding:2px 0;cursor:pointer}
label:hover{color:var(--accent)}
label span.n{margin-left:auto;color:var(--dim);font-size:11px}
input[type=search]{width:100%;padding:7px 9px;background:var(--bg);color:var(--fg);
 border:1px solid var(--line);border-radius:5px;font:inherit}
.card{border:1px solid var(--line);border-left:3px solid var(--accent);
 border-radius:6px;background:var(--panel);padding:9px 11px;margin:0 0 8px}
.card.rc{border-left-color:var(--ok)} .card.err{border-left-color:var(--bad)}
.card.wire{border-left-color:var(--warn)}
.row1{display:flex;gap:10px;flex-wrap:wrap;align-items:baseline}
.k{font-weight:600}
.tag{font-size:11px;color:var(--dim);border:1px solid var(--line);
 border-radius:10px;padding:0 7px}
.tag.admin{color:var(--warn);border-color:var(--warn)}
time{color:var(--dim);font-size:11px}
pre{margin:7px 0 0;padding:8px;background:var(--bg);border:1px solid var(--line);
 border-radius:5px;overflow-x:auto;font-size:12px;white-space:pre-wrap;
 word-break:break-word;max-height:280px}
.muted-note{color:var(--warn);font-size:11px;margin:6px 0 0}
.btn{background:var(--bg);color:var(--fg);border:1px solid var(--line);
 border-radius:5px;padding:5px 9px;cursor:pointer;font:inherit;margin:0 4px 4px 0}
.btn:hover{border-color:var(--accent);color:var(--accent)}
#status{color:var(--dim);margin:0 0 10px}
.empty{color:var(--dim);padding:30px 0;text-align:center}
details summary{cursor:pointer;color:var(--dim);font-size:11px}
</style></head><body>
<header>
 <h1>RFTD forensic report</h1>
 <div class="meta">__NREC__ records &middot; __SPAN__ &middot; __NBAD__ malformed
  <details style="display:inline"><summary>sources</summary><ul>__SRCS__</ul></details>
 </div>
</header>
<div class="wrap">
<aside>
 <input type="search" id="q" placeholder="search user, command, payload...">
 <div style="margin-top:8px">
  <button class="btn" id="all">show all</button>
  <button class="btn" id="none">hide all</button>
  <button class="btn" id="reset">reset</button>
 </div>
 <div id="facets"></div>
</aside>
<main><div id="status"></div><div id="list"></div></main>
</div>
<script>
const DATA = __DATA__;
const muted = new Set(DATA.muted), auto = new Set(DATA.auto);
const off = new Set(muted);
const FACETS = [["key","source"],["u","player"],["stream","stream"],["m","mod"],["access","access"]];
const state = {};
FACETS.forEach(([f])=>state[f]=new Set());

function counts(field){
  const c = {};
  for(const r of DATA.recs){ const v = r[field]||"?"; c[v]=(c[v]||0)+1; }
  return Object.entries(c).sort((a,b)=>b[1]-a[1]);
}
function buildFacets(){
  let h="";
  for(const [f,label] of FACETS){
    h += `<h2>${label}</h2>`;
    for(const [v,n] of counts(f)){
      const isOff = f==="key" && off.has(v);
      const tag = auto.has(v) ? " (auto-muted: high volume)" : "";
      h += `<label title="${esc(v)}${tag}"><input type="checkbox" data-f="${f}" value="${esc(v)}"${isOff?"":" checked"}>`
        +  `<span>${esc(v.length>34?v.slice(0,33)+"…":v)}</span><span class="n">${n}</span></label>`;
    }
  }
  document.getElementById("facets").innerHTML = h;
  document.querySelectorAll("#facets input").forEach(cb=>{
    if(!cb.checked) state[cb.dataset.f].add(cb.value);
    cb.addEventListener("change",()=>{
      const s=state[cb.dataset.f];
      cb.checked ? s.delete(cb.value) : s.add(cb.value);
      draw();
    });
  });
}
const esc = s => String(s).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

function cls(r){
  if(/ERROR|REJECT/.test(r.e)) return "err";
  if(r.stream==="wire") return "wire";
  if(/^RC\./.test(r.e)) return "rc";
  return "";
}
function payload(r){
  const x = Object.assign({},r.x);
  ["module","command","access","sid","onlineid","est","x","y","z"].forEach(k=>delete x[k]);
  let s = "";
  for(const [k,v] of Object.entries(x)) s += k+" = "+(typeof v==="string"?v:JSON.stringify(v))+"\n";
  return s.trim();
}
function draw(){
  const q = document.getElementById("q").value.toLowerCase();
  let shown=0, hidden=0, out=[];
  for(const r of DATA.recs){
    let skip=false;
    for(const [f] of FACETS){ if(state[f].has(r[f]||"?")){skip=true;break;} }
    if(!skip && q){
      const hay = (r.u+" "+r.key+" "+r.e+" "+JSON.stringify(r.x)).toLowerCase();
      if(!hay.includes(q)) skip=true;
    }
    if(skip){hidden++;continue;}
    shown++;
    if(out.length>=3000) continue;
    const p = payload(r);
    out.push(`<div class="card ${cls(r)}">`
      +`<div class="row1"><span class="k">${esc(r.key)}</span>`
      +`<span class="tag${r.access==="admin"?" admin":""}">${esc(r.u)}${r.access?" · "+esc(r.access):""}</span>`
      +`<span class="tag">${esc(r.e)}</span>`
      +(r.pos?`<span class="tag">${esc(r.pos)}</span>`:"")
      +(r.est?`<span class="tag">${r.est}B</span>`:"")
      +`<time>${esc(r.iso)}${r.d!=null?" · day "+Number(r.d).toFixed(2):""}</time></div>`
      +(r.realsid?`<div class="muted-note">envelope sid ${esc(r.sid)} is approximate — real id in payload: ${esc(r.realsid)}</div>`:"")
      +(p?`<pre>${esc(p)}</pre>`:"")
      +`</div>`);
  }
  document.getElementById("status").textContent =
    `${shown} shown, ${hidden} hidden by filters` + (shown>3000?" (first 3000 rendered)":"");
  document.getElementById("list").innerHTML = out.join("") ||
    `<div class="empty">nothing matches — widen the filters</div>`;
}
document.getElementById("q").addEventListener("input",draw);
document.getElementById("all").onclick=()=>{FACETS.forEach(([f])=>state[f].clear());
  document.querySelectorAll("#facets input").forEach(c=>c.checked=true);draw();};
document.getElementById("none").onclick=()=>{
  document.querySelectorAll("#facets input").forEach(c=>{c.checked=false;state[c.dataset.f].add(c.value);});draw();};
document.getElementById("reset").onclick=()=>{FACETS.forEach(([f])=>state[f].clear());buildFacets();draw();};
buildFacets(); draw();
</script></body></html>"""


def main():
    ap = argparse.ArgumentParser(description="Render RFTD forensic logs to one HTML page.")
    ap.add_argument("paths", nargs="+", help="log file(s) or a forensic directory")
    ap.add_argument("-o", "--out", default="forensic-report.html")
    ap.add_argument("--open", action="store_true", help="open the report when done")
    a = ap.parse_args()

    files = collect(a.paths)
    if not files:
        print("no .jsonl / .jsonl.log files found", file=sys.stderr)
        return 2

    recs, bad = load(files)
    if not recs:
        print("no parseable records found", file=sys.stderr)
        return 2

    out = Path(a.out)
    render(recs, bad, files, out)

    muted, auto = build_mutes(recs)
    print(f"{len(recs)} records from {len(files)} file(s) -> {out}")
    if bad:
        print(f"  ! {bad} malformed line(s) skipped")
    if muted:
        print(f"  pre-muted (one click to show): {', '.join(muted)}")
    if auto:
        print(f"  auto-muted for exceeding {AUTO_MUTE_SHARE:.0%} of the file: {', '.join(auto)}")

    if a.open:
        webbrowser.open(out.resolve().as_uri())
    return 0


if __name__ == "__main__":
    sys.exit(main())
