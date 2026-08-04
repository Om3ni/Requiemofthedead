#!/usr/bin/env python3
"""seed-bot-characters.py - give FakeClientManager bots a character to log into.

WHY THIS IS NEEDED: the server does not create a character for an arriving bot. On PlayerConnect it
calls ServerPlayerDB.serverLoadNetworkCharacter(playerIndex, username) (GameServer.java:2572), which
is a straight SELECT against the networkPlayers table (ServerPlayerDB.java:218). No row means the
method returns null at :274 and the server kicks with UI_LoadPlayerProfileError (GameServer.java:2574).

A real player never hits this because character creation happens client-side and writes the row
first. Bots skip character creation entirely - FakeClientManager sends a PlayerConnect and expects a
character to be waiting.

So we clone one: take an existing character's serialized blob and re-insert it under each bot name.
The blob is a real IsoPlayer serialized at a known worldversion, so it loads cleanly; copying beats
synthesising one, because the format is large, versioned, and not documented anywhere we control.

Safe to re-run: bot rows are deleted and rewritten each time.

Usage:
    python seed-bot-characters.py                     # 14 bots from the only/first character
    python seed-bot-characters.py --count 8
    python seed-bot-characters.py --source Omen --x 10800 --y 9500
    python seed-bot-characters.py --remove            # delete bot rows, leave real players alone
"""
import argparse
import os
import shutil
import sqlite3
import sys

DEFAULT_DB = r"C:\Mosaic\pzdata\Saves\Multiplayer\MDS\players.db"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=DEFAULT_DB)
    ap.add_argument('--count', type=int, default=14, help='bots to seed (Client0..Client<N-1>)')
    ap.add_argument('--source', help='username to clone (default: the first row found)')
    ap.add_argument('--x', type=float, help='override spawn x')
    ap.add_argument('--y', type=float, help='override spawn y')
    ap.add_argument('--remove', action='store_true', help='delete Client* rows and exit')
    ap.add_argument('--no-backup', action='store_true')
    args = ap.parse_args()

    if not os.path.isfile(args.db):
        sys.exit(f'players.db not found: {args.db}')

    if not args.no_backup:
        bak = args.db + '.bak'
        if not os.path.exists(bak):
            shutil.copy2(args.db, bak)
            print(f'backup: {bak}')

    con = sqlite3.connect(args.db)
    cur = con.cursor()

    names = [f'Client{i}' for i in range(args.count)]

    if args.remove:
        cur.execute("DELETE FROM networkPlayers WHERE username LIKE 'Client%'")
        con.commit()
        print(f'removed {cur.rowcount} bot rows')
        return

    if args.source:
        cur.execute("SELECT world,name,steamid,x,y,z,worldversion,data,isDead "
                    "FROM networkPlayers WHERE username=?", (args.source,))
    else:
        cur.execute("SELECT world,name,steamid,x,y,z,worldversion,data,isDead "
                    "FROM networkPlayers WHERE username NOT LIKE 'Client%' LIMIT 1")
    row = cur.fetchone()
    if not row:
        sys.exit('no source character found. Log in once with a real account first, '
                 'so there is a character to clone.')

    world, name, steamid, x, y, z, worldversion, data, isDead = row
    if args.x is not None:
        x = args.x
    if args.y is not None:
        y = args.y

    print(f'cloning from world={world} worldversion={worldversion} '
          f'blob={len(data)}B -> ({x:.0f},{y:.0f})')

    # Rewrite rather than INSERT OR IGNORE: a stale bot row from an earlier world or worldversion
    # would fail to deserialize and the server would kick with the same error this exists to fix.
    cur.execute("DELETE FROM networkPlayers WHERE username LIKE 'Client%'")

    for n in names:
        cur.execute(
            "INSERT INTO networkPlayers (world,username,playerIndex,name,steamid,x,y,z,"
            "worldversion,data,isDead) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (world, n, 0, n, '', x, y, z, worldversion, data, 0))
    con.commit()

    cur.execute("SELECT COUNT(*) FROM networkPlayers WHERE username LIKE 'Client%'")
    print(f'seeded {cur.fetchone()[0]} bot characters')
    con.close()


if __name__ == '__main__':
    main()
