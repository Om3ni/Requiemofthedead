# Engine determination — The Lua mod networking surface, and whether a second route is possible (42.20.0)

*Verified against `PZ_Engine_Decompiled_42.20.0-a2947723ca`, 2026-08-02. Companion to
`engine-class-patch-feasibility-42.20.md`.*

**Short version: a server-only class patch CANNOT create a second route, because packet
IDs are enum ordinals and a stock client drops any ordinal it doesn't know. Both ends
would have to be patched — a forked client, which a Workshop suite can't ship. But the
investigation found the actual ceiling, and it's a tunable one we're very likely sitting
under: every Lua command from a client shares ONE budget of `MaxPacketsPerSecond`
(default 300) and excess is silently cancelled. That's the narrowness — and it's an INI
line, not an engine patch.**

## Why a second route can't be server-only

`PacketType.getId()` returns **`(short)this.ordinal()`**
([PacketTypes.java:660](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/PacketTypes.java#L660)),
and the receiver resolves it by lookup:

```java
this.type = PacketTypes.packetTypes.get(id);
if (this.type == null) DebugType.Multiplayer.error("Received unknown packet id=%d", id);
```
([ZomboidNetData.java:37](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/ZomboidNetData.java#L37))

Consequences:

- **Append a new type on the server** → the stock client has no such ordinal, logs
  "unknown packet id", drops it. Dead route.
- **Insert a type mid-enum** → every later ordinal shifts, and server and client
  disagree about *every* packet type after the insertion point. Catastrophic, not
  merely broken.
- **Repurpose an existing type** → the client routes it to its own stock handler, which
  parses our payload as something else.

So the route requires a patched client. Per
`engine-class-patch-feasibility-42.20.md`, Workshop ships no class files — that's a
forked client distributed by hand. Not viable for RFTD. (Same for a separate socket:
the server can open one, but stock clients have nothing to talk to it with.)

## The real ceiling — and it's tunable

**`MaxPacketsPerSecond`: min 100, max 1000, default 300**
([ServerOptions.java:177](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/ServerOptions.java#L177)).

The limiter lives in `PacketsCache`, and `UdpConnection extends PacketsCache`
([UdpConnection.java:40](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/core/raknet/UdpConnection.java#L40)),
so the budget is **per connection, per packet type**. Every Lua
`sendClientCommand` — from **every mod on that client** — is the single
`ClientCommand` type
([PacketTypes.java:480](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/PacketTypes.java#L480)).
**All mods share one 300/sec bucket.** That is exactly the narrowness the >10-pop
symptom points at.

The asymmetry matters:

- **Client → server is hard-capped.** `PacketType.send` checks
  `GameClient.client && connection.isLimitExceeded(this)` and calls
  **`cancelPacket()`** — the packet is *silently dropped*, not queued
  ([PacketTypes.java:644](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/PacketTypes.java#L644)).
- **Server → client is not capped by this.** The send-side check is client-gated, and
  the server's receive path only *logs* when the limit trips
  ([PacketTypes.java:667](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/PacketTypes.java#L667)).

**Diagnostic to look for right now:** the limiter emits
`Packets limit has exceeded for ClientCommand`
([PacketsCache.java:69](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/PacketsCache.java#L69)).
If that line appears in Mosaic's logs, mod commands are being thrown away and we have
direct evidence, not a theory.

## Other verified costs in the path

1. **One buffer + one lock per connection.** `UdpConnection` holds a single
   `ByteBuffer.allocate(1000000)` and a single `ByteBufferWriter`, and `startPacket()`
   takes a `ReentrantLock` before handing it out
   ([UdpConnection.java:45](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/core/raknet/UdpConnection.java#L45),
   [:201](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/core/raknet/UdpConnection.java#L201)).
   All traffic to a player serializes through it.
2. **Broadcast re-serializes per player.** `sendServerCommand(module, cmd, table)` loops
   every connection and calls the per-connection variant
   ([GameServer.java:3209](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/GameServer.java#L3209)),
   which runs the full `TableNetworkUtils.save` each time. 30 players = **30 full
   serializations of the identical table**, on the main thread.
3. **Each serialization walks the table three times** — GameServer's own `canSave`
   logging pass ([:3195](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/GameServer.java#L3195)),
   then `save`'s count pass, then its write pass
   ([TableNetworkUtils.java:33](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/TableNetworkUtils.java#L33)).
4. **ClientCommand is classified priority 1, reliability 2, ordering channel 0.** (Under
   the standard RakNet mapping that's HIGH priority / RELIABLE — *not* verified in this
   decompile, since the enum lives in the native layer. Worth noting reliability 2 is
   reliable-but-unordered, so channel 0 is not head-of-line blocking it.)

## Headroom available without any patch

1. **Raise `MaxPacketsPerSecond`.** Default 300 → up to 1000 is a 3.3× lift on the
   constrained direction, one INI line. Same shape as the `ZombiesCountBeforeDelete`
   discovery: a silent default nobody knew was there. Check the log line first.
2. **The limiter counts packets, not bytes.** Fewer, larger commands are strictly better
   than many small ones. RDWire's byte-budget chunker should prefer bigger chunks — at
   3072 bytes it's nowhere near the 1 MB connection buffer, and every extra chunk is a
   whole packet against the shared bucket.
3. **Push work to server → client**, which this limiter doesn't cap. Design so clients
   ask rarely and the server pushes.
4. **Never broadcast a large table.** Use `sendServerCommandToRelevant(x, y, ...)`
   ([GameServer.java:3216](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/GameServer.java#L3216))
   or targeted per-player sends with deltas. Broadcast cost is O(players × table).
5. **Keep tables flat with short keys** — three walks per serialization per player.

## Recommendation

Don't patch. The "narrow surface" is mostly one undiscovered default plus a
packet-count-shaped budget we can design around. Get the evidence (`Packets limit has
exceeded for ClientCommand` in the Mosaic logs), raise `MaxPacketsPerSecond`, and shift
RDWire toward fewer/larger client→server packets and server-push. If after all that a
genuine ceiling remains, the honest options are reducing what needs syncing — not a
forked client.
