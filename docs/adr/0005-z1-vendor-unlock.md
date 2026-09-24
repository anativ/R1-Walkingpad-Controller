# 0005 — Unlock the Z1 on the vendor channel before any FTMS

Status: Accepted

## Context

A Z1F (`KS-HD-Z1D`, software V0.0.6) connected cleanly through v1.1–v1.8, then sent nothing:
no Treadmill Data, no Control Point result, no reply on the vendor channel. Those builds tried,
in turn, a timing fix, a looser parser, an MC-21 property-list frame, a vendor "wake" frame,
KingSmith's obfuscated text protocol, and a model/timestamp init copied from
kkz6/WalkingPadSDK. See `docs/z1f-investigation.md`.

slandau3/z1-walkingpad-mcp documents the cause, verified on the same pad and software
(`docs/protocol.md`), and the duttke.de Web Bluetooth controller does the same thing
independently. The pad gates everything behind an unlock on the supplement service. Until the
pad answers `71 80`, it acknowledges every write, ignores the Control Point and sends no
notification on any characteristic. The unlock is `71 00 05 01 <T> <checksum>` with
`T = LE32(last four bytes of the Bluetooth name) + 1`. The `71 00 05 64 …Z1D` frame that v1.8
sent is the same frame with a different nonce, frozen to one name.

## Decision

1. **The unlock is the FTMS dialect's handshake.** Bring-up subscribes the supplement notify
   characteristic, then the `.handshake` step sends the unlock derived from the peripheral's
   name (`peripheral.name ?? advertised local name`, the same choice as the reference). It
   sends the unlock again at 5 s and gives up at 10 s. `71 80` completes the step. Session info
   (`71 01`), a read of every property (`72 00 01 00 73`) and "request control" follow, in
   that order. A belt without the supplement pair, or with a name too short for a token, skips
   the unlock.
2. **The supplement pair is a binary channel.** The text handshake runs only on the dedicated
   `…0E00`/`…0F00` pair, and on a belt that has both pairs it runs after the unlock. Every
   vendor reply is framed, checked and logged.
3. **Removed:** the wake frame (`72 01 03 0A 00 00`, a property-10 write that zeroed the mode
   word), its start-time preamble, the `72 00 00 72` "status query", `WLR` status parsing, and
   the kkz6 model/timestamp frames.
4. **Vendor writes are at least 400 ms apart.** A Control Point refusal with result 5 ("control
   not permitted") gets control re-requested and the same bytes retried once, if nothing newer
   has gone out since.
5. `2A26` is read as the firmware revision, and `2A28` is now labelled "software".

## Rationale

- **Two implementations have run this on hardware; nothing else has.** Every earlier theory
  came from decompilation or from SDKs that never stated a firmware version.
- **In the dialect, not the controller** (invariant 7). The controller learned only generic
  things: the name reaches `beginHandshake`, a handshake step may carry a retry time, and each
  command write is reported to the dialect.
- **Retrying the exact bytes** keeps the safety clamp: the speed in them was clamped before its
  first write, and a newer command cancels the retry.

## Consequences

- The connect budget grows from 12 s to 30 s, so that a full handshake budget fits inside it.
- A non-`KS-HD` FTMS belt with a vendor pair gets an unlock it does not understand, then waits
  10 s before carrying on with FTMS.
- The native kcal field (Treadmill Data flag bit 7) is still dropped. The reference says the
  Z1 does not send it. Another report says it does. `PadStatus` gains it only once a log
  settles which is true.
- The optional `0x77` vendor control tunnel is not implemented.
