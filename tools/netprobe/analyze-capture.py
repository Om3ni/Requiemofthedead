#!/usr/bin/env python3
"""analyze-capture.py - turn a folder of /metrics snapshots into per-client traffic attribution.

WHY THIS EXISTS: the engine's Prometheus exporter labels its packet histograms by BOTH packet type
and client (StatisticManager.java:77-78, fed from NetworkStatistic.java:129/:143 with
connection.getUserName()). That means the raw endpoint already knows exactly how many bytes went to
each player - but it reports them as monotonic counters smeared across thousands of lines, which is
unreadable by hand. This does the only two things that turn that into an answer: diff the counters
across the window, and pivot the result into client x packetType.

COUNTER RESETS ARE HANDLED. A server restart mid-capture zeroes every counter. Naive last-minus-
first would then report a large negative or a wildly understated delta. We walk the snapshots in
order and accumulate per monotonic segment, so a restart costs you the packets in flight during the
restart and nothing else. Segments are reported, because a capture that silently spanned a restart
is a capture you should know about.

ESTIMATES ARE NOT MIXED IN. Everything here is measured wire bytes from the engine's own send path
(UdpConnection.java:295-298 is a true chokepoint - no send bypasses it). RDWire's per-mod numbers
are estimates and deliberately live in a different report; do not merge the two into one column and
lose track of which is which.

Usage:
    python analyze-capture.py <capture-dir>
    python analyze-capture.py <capture-dir> -o report.html
    python analyze-capture.py <capture-dir> --top 25
    python analyze-capture.py <capture-dir> --csv pivot.csv

No dependencies beyond the standard library.
"""
import argparse
import html
import os
import re
import sys
from collections import defaultdict
from datetime import datetime

# packet_send_bytes_sum{packetType="PlayerUpdateReliable",client="Client0"} 1.234567E7
SAMPLE = re.compile(
    r'^(?P<metric>packet_(?:send|receive)_bytes)_(?P<agg>count|sum)\{(?P<labels>[^}]*)\}\s+(?P<value>[0-9eE.+\-]+)\s*$'
)
LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')
TS_FROM_NAME = re.compile(r'(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})')


def parse_snapshot(path):
    """-> {(metric, agg, packetType, client): float}"""
    out = {}
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        for line in fh:
            if not line.startswith('packet_'):
                continue
            m = SAMPLE.match(line.rstrip('\n'))
            if not m:
                continue
            labels = dict(LABEL.findall(m.group('labels')))
            try:
                value = float(m.group('value'))
            except ValueError:
                continue
            key = (m.group('metric'), m.group('agg'),
                   labels.get('packetType', '?'), labels.get('client', ''))
            # Same series can appear once per bucket-less aggregate only; last wins.
            out[key] = value
    return out


def snapshot_time(path):
    m = TS_FROM_NAME.search(os.path.basename(path))
    if m:
        try:
            return datetime.strptime(m.group(1), '%Y-%m-%d_%H-%M-%S')
        except ValueError:
            pass
    return datetime.fromtimestamp(os.path.getmtime(path))


def accumulate(paths):
    """Walk snapshots in order, summing deltas within monotonic segments.

    Returns (totals, n_segments, elapsed_seconds).
    """
    totals = defaultdict(float)
    prev = None
    segments = 1
    for path in paths:
        cur = parse_snapshot(path)
        if prev is not None:
            # A reset is detected per-series: any series that went DOWN means the
            # process restarted and every counter restarted with it.
            reset = any(cur.get(k, 0.0) < v - 1e-9 for k, v in prev.items() if k in cur)
            if reset:
                segments += 1
                # Post-reset values are themselves accrued-since-restart, so the
                # current snapshot's absolute values are the segment's delta so far.
                for k, v in cur.items():
                    totals[k] += v
            else:
                for k, v in cur.items():
                    totals[k] += v - prev.get(k, 0.0)
        prev = cur

    elapsed = 0.0
    if len(paths) >= 2:
        elapsed = (snapshot_time(paths[-1]) - snapshot_time(paths[0])).total_seconds()
    return totals, segments, elapsed


def human(n):
    for unit in ('B', 'KB', 'MB', 'GB'):
        if abs(n) < 1024.0:
            return f'{n:,.1f} {unit}'
        n /= 1024.0
    return f'{n:,.1f} TB'


def build_tables(totals):
    """-> dict of pivots keyed by direction ('send'/'receive')."""
    out = {}
    for direction in ('send', 'receive'):
        metric = f'packet_{direction}_bytes'
        by_client = defaultdict(float)
        by_type = defaultdict(float)
        by_client_count = defaultdict(float)
        cross = defaultdict(float)
        for (m, agg, ptype, client), value in totals.items():
            if m != metric or value <= 0:
                continue
            if agg == 'sum':
                by_client[client] += value
                by_type[ptype] += value
                cross[(client, ptype)] += value
            else:
                by_client_count[client] += value
        out[direction] = {
            'by_client': by_client,
            'by_type': by_type,
            'by_client_count': by_client_count,
            'cross': cross,
            'total': sum(by_client.values()),
        }
    return out


def print_report(tables, segments, elapsed, top):
    if segments > 1:
        print(f'!! capture spans {segments} counter segments - the server restarted mid-window.\n')
    print(f'window: {elapsed / 60.0:.1f} min\n')

    for direction in ('send', 'receive'):
        t = tables[direction]
        arrow = 'server -> client' if direction == 'send' else 'client -> server'
        print(f'== packet_{direction}  ({arrow})  total {human(t["total"])} '
              f'| {human(t["total"] / elapsed) if elapsed else "n/a"}/s ==')
        if not t['total']:
            print('   (no data)\n')
            continue

        print(f'\n   {"client":<24}{"bytes":>14}{"share":>9}{"bytes/s":>12}{"packets":>12}')
        print('   ' + '-' * 71)
        for client, value in sorted(t['by_client'].items(), key=lambda kv: -kv[1]):
            share = 100.0 * value / t['total']
            rate = human(value / elapsed) + '/s' if elapsed else '-'
            pkts = t['by_client_count'].get(client, 0.0)
            name = client if client else '(unnamed)'
            print(f'   {name:<24}{human(value):>14}{share:>8.1f}%{rate:>12}{pkts:>12,.0f}')

        print(f'\n   {"packetType":<40}{"bytes":>14}{"share":>9}')
        print('   ' + '-' * 63)
        for ptype, value in sorted(t['by_type'].items(), key=lambda kv: -kv[1])[:top]:
            share = 100.0 * value / t['total']
            print(f'   {ptype:<40}{human(value):>14}{share:>8.1f}%')
        if len(t['by_type']) > top:
            print(f'   ... {len(t["by_type"]) - top} more types (--top to widen)')
        print()


HTML_HEAD = """<title>netprobe - per-client traffic</title>
<style>
  :root { color-scheme: light dark; --fg:#1a1a1a; --bg:#fff; --mut:#666; --line:#e2e2e2; --accent:#b3541e; }
  @media (prefers-color-scheme: dark) {
    :root { --fg:#e8e6e3; --bg:#16181a; --mut:#9aa0a6; --line:#2c3034; --accent:#e08b4e; }
  }
  body { font:14px/1.55 ui-monospace,"Cascadia Mono",Consolas,monospace; color:var(--fg);
         background:var(--bg); margin:0; padding:2rem 1.25rem; }
  .wrap { max-width:1100px; margin:0 auto; }
  h1 { font-size:1.35rem; margin:0 0 .25rem; }
  h2 { font-size:1.05rem; margin:2.25rem 0 .5rem; border-bottom:1px solid var(--line); padding-bottom:.3rem; }
  .meta { color:var(--mut); margin-bottom:1.5rem; }
  .warn { border-left:3px solid var(--accent); padding:.6rem .9rem; margin:1rem 0; background:color-mix(in srgb, var(--accent) 8%, transparent); }
  .scroll { overflow-x:auto; }
  table { border-collapse:collapse; width:100%; margin:.5rem 0 1rem; font-size:13px; }
  th,td { text-align:right; padding:.32rem .6rem; border-bottom:1px solid var(--line); white-space:nowrap; }
  th:first-child, td:first-child { text-align:left; }
  th { color:var(--mut); font-weight:600; }
  .bar { display:block; height:3px; background:var(--accent); border-radius:2px; margin-top:3px; }
  footer { color:var(--mut); margin-top:3rem; font-size:12px; }
</style>
"""


def bar(share):
    return f'<span class="bar" style="width:{max(share, 0.4):.1f}%"></span>'


def write_html(path, tables, segments, elapsed, capture_dir, n_snaps, top):
    p = [HTML_HEAD, '<div class="wrap">']
    p.append('<h1>netprobe &mdash; per-client traffic attribution</h1>')
    p.append(f'<div class="meta">{html.escape(capture_dir)} &middot; {n_snaps} snapshots &middot; '
             f'{elapsed / 60.0:.1f} min window</div>')
    if segments > 1:
        p.append(f'<div class="warn"><strong>Counter reset detected.</strong> This capture spans '
                 f'{segments} segments &mdash; the server restarted mid-window. Deltas are summed '
                 f'per segment; traffic in flight across the restart is lost.</div>')
    p.append('<div class="warn">Measured wire bytes from the engine send path, not estimates. '
             'Per-mod attribution needs RDWire and is a different report.</div>')

    for direction in ('send', 'receive'):
        t = tables[direction]
        arrow = 'server &rarr; client' if direction == 'send' else 'client &rarr; server'
        p.append(f'<h2>packet_{direction} <span style="color:var(--mut)">({arrow})</span></h2>')
        if not t['total']:
            p.append('<p style="color:var(--mut)">No data.</p>')
            continue
        rate = f'{human(t["total"] / elapsed)}/s' if elapsed else 'n/a'
        p.append(f'<div class="meta">total {human(t["total"])} &middot; {rate}</div>')

        p.append('<div class="scroll"><table><thead><tr><th>client</th><th>bytes</th>'
                 '<th>share</th><th>bytes/s</th><th>packets</th></tr></thead><tbody>')
        for client, value in sorted(t['by_client'].items(), key=lambda kv: -kv[1]):
            share = 100.0 * value / t['total']
            r = f'{human(value / elapsed)}/s' if elapsed else '-'
            pkts = t['by_client_count'].get(client, 0.0)
            name = html.escape(client) if client else '<em>(unnamed)</em>'
            p.append(f'<tr><td>{name}{bar(share)}</td><td>{human(value)}</td>'
                     f'<td>{share:.1f}%</td><td>{r}</td><td>{pkts:,.0f}</td></tr>')
        p.append('</tbody></table></div>')

        p.append('<div class="scroll"><table><thead><tr><th>packetType</th><th>bytes</th>'
                 '<th>share</th></tr></thead><tbody>')
        for ptype, value in sorted(t['by_type'].items(), key=lambda kv: -kv[1])[:top]:
            share = 100.0 * value / t['total']
            p.append(f'<tr><td>{html.escape(ptype)}{bar(share)}</td><td>{human(value)}</td>'
                     f'<td>{share:.1f}%</td></tr>')
        p.append('</tbody></table></div>')

        # cross-tab: top packet types as columns, clients as rows
        types = [k for k, _ in sorted(t['by_type'].items(), key=lambda kv: -kv[1])[:8]]
        clients = [k for k, _ in sorted(t['by_client'].items(), key=lambda kv: -kv[1])]
        if types and clients:
            p.append('<div class="scroll"><table><thead><tr><th>client \\ type</th>' +
                     ''.join(f'<th>{html.escape(x)}</th>' for x in types) +
                     '</tr></thead><tbody>')
            for client in clients:
                name = html.escape(client) if client else '(unnamed)'
                cells = ''.join(
                    f'<td>{human(t["cross"].get((client, x), 0.0))}</td>' for x in types)
                p.append(f'<tr><td>{name}</td>{cells}</tr>')
            p.append('</tbody></table></div>')

    p.append('<footer>Generated by tools/netprobe/analyze-capture.py from the engine\'s own '
             'Prometheus exporter. Counters diffed per monotonic segment.</footer>')
    p.append('</div>')
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(p))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('capture_dir', help='folder of .prom snapshots from scrape-metrics.ps1; '
                                        'with --latest, the captures ROOT to search instead')
    ap.add_argument('--latest', action='store_true',
                    help='treat capture_dir as a root and analyse its newest subfolder')
    ap.add_argument('-o', '--out', help='write an HTML report here (default: <dir>/report.html)')
    ap.add_argument('--top', type=int, default=15, help='packet types to list (default 15)')
    ap.add_argument('--csv', help='also dump the client x packetType pivot as CSV')
    args = ap.parse_args()

    # Resolved here rather than in the .bat: picking the newest folder from cmd needs either an
    # inline PowerShell block or a for/f loop, both of which are quoting minefields. Doing it in
    # Python keeps the batch files to a single unambiguous line.
    if args.latest:
        if not os.path.isdir(args.capture_dir):
            sys.exit(f'no captures folder yet: {args.capture_dir}\n'
                     f'Run 2-START-CAPTURE.bat first.')
        subs = [os.path.join(args.capture_dir, d) for d in os.listdir(args.capture_dir)]
        subs = [d for d in subs if os.path.isdir(d)]
        if not subs:
            sys.exit(f'no captures in {args.capture_dir}\nRun 2-START-CAPTURE.bat first.')
        args.capture_dir = max(subs, key=os.path.getmtime)
        print(f'latest capture: {args.capture_dir}\n')

    if not os.path.isdir(args.capture_dir):
        sys.exit(f'not a directory: {args.capture_dir}')

    paths = sorted(os.path.join(args.capture_dir, f)
                   for f in os.listdir(args.capture_dir) if f.endswith('.prom'))
    if len(paths) < 2:
        sys.exit(f'need at least 2 .prom snapshots to diff counters, found {len(paths)}')

    totals, segments, elapsed = accumulate(paths)
    tables = build_tables(totals)

    print_report(tables, segments, elapsed, args.top)

    out = args.out or os.path.join(args.capture_dir, 'report.html')
    write_html(out, tables, segments, elapsed, args.capture_dir, len(paths), args.top)
    print(f'HTML: {out}')

    if args.csv:
        with open(args.csv, 'w', encoding='utf-8', newline='') as fh:
            fh.write('direction,client,packetType,bytes\n')
            for direction in ('send', 'receive'):
                for (client, ptype), value in sorted(tables[direction]['cross'].items(),
                                                     key=lambda kv: -kv[1]):
                    fh.write(f'{direction},{client},{ptype},{value:.0f}\n')
        print(f'CSV:  {args.csv}')


if __name__ == '__main__':
    main()
