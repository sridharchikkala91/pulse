# WHOOP 5.0/MG proprietary channel — handshake + decode spike (Slice 1)

## Goal

Determine whether Pulse can get any real data out of the WHOOP 5.0/MG
proprietary BLE channel (`fd4b0001-...`) by completing WHOOP's
`CLIENT_HELLO` handshake, and if so, decode whatever the strap sends
back. This is the first slice of the larger "port NOOP's proprietary
decoder" project — not the whole thing.

## What we already know (verified this session)

- The proprietary service and its 5 characteristics (`fd4b0002`
  through `fd4b0007`, skipping `0006`) are reachable via WebBLE — a
  debug probe confirmed `getPrimaryService()` /
  `getCharacteristics()` succeed with no authentication error, as
  long as `requestDevice` filters by the *advertised* Heart Rate
  service and lists the proprietary service in `optionalServices`
  (filtering directly by the proprietary UUID fails, since the strap
  doesn't advertise it).
- Per NOOP's protocol docs (`docs/PROTOCOL.md`) and source
  (`DeviceFamily.swift`, `Framing.swift`):
  - `…0002` = command write (app → strap)
  - `…0003`, `…0004`, `…0005`, `…0007` = notify channels (strap → app)
  - `CLIENT_HELLO` is a **static, hardcoded 16-byte frame** — not a
    per-session cryptographic handshake:
    `AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D`
  - The 5.0/MG envelope is `[0xAA][format][declLength u16
    LE][header 2 bytes][crc16 u16 LE][type][seq][cmd][payload][crc32
    u32 LE]`, with CRC16-Modbus (poly `0xA001`, init `0xFFFF`) over
    the 6 header bytes and CRC32 (zlib, poly `0xEDB88320`) over the
    inner `[type seq cmd payload]` record.

## Open question that changes scope

The two "header" bytes (offset 4–5, `0x00 0x01` in the hello) are
**undocumented** — NOOP's own source only ever writes the static
hello and never shows a function that builds an arbitrary outgoing
5.0 command frame. I checked `Framing.swift` and `DeviceFamily.swift`
directly; neither contains a WHOOP-5.0 frame *encoder*, only
decode/verify logic plus the hardcoded hello constant.

**Conclusion:** we cannot responsibly construct our own outgoing
5.0 commands yet (e.g. `GET_BATTERY_LEVEL`) — we'd be guessing at
those header bytes with no reference to check against. So Slice 1
does not attempt that.

## Scope for this slice

**In scope:**
1. Implement the three checksum functions (CRC8, CRC32-zlib,
   CRC16-Modbus) as small, independently-testable pure functions.
2. Implement a generic 5.0-envelope *decoder* (unpack: format,
   declLength, header bytes, crc16, type, seq, cmd, payload, crc32),
   verifying both CRCs and reporting mismatches rather than silently
   accepting corrupt frames.
3. Add a new debug action (alongside the existing proprietary-channel
   probe) that: connects, subscribes to all 4 notify characteristics,
   writes the static `CLIENT_HELLO` to `…0002`, and logs every
   notification it receives afterward — both raw hex and decoded
   fields — to the on-screen debug log.
4. Manually test on the real strap and observe: does the strap ACK
   the hello, start pushing data on its own, or reject/disconnect?

**Out of scope (deferred to later slices, pending what Slice 1
reveals):**
- Building/encoding any outgoing command frame other than the static
  hello (blocked on the open question above).
- Historical-data (type 47) offload — separate stateful
  start/end/complete + trim-cursor protocol, only worth designing
  once we know we can talk to the strap at all.
- SpO2 / skin temp / respiratory rate byte layouts — not in
  `docs/PROTOCOL.md`; would require pulling and decoding
  `whoop_protocol.json` from NOOP's repo, a separate research step.
- Wiring any of this into the real Today/Sleep UI — this stays
  debug-only until we have decoded, trustworthy data.

## Implementation approach

Single approach (no real alternatives worth weighing): port the
three checksum algorithms and the envelope shape faithfully from
NOOP's documented spec, as new functions in `index.html` alongside
the existing `probeProprietaryChannel`, gated behind the same Debug
card in the Connect screen. No new files, no build step — consistent
with the project's single-self-contained-HTML-file constraint.

## Error handling

Every notification received gets logged with both raw hex and (if it
parses as a valid envelope) decoded fields. If CRC verification
fails, log it as a CRC mismatch rather than throwing — malformed or
partial BLE notifications are expected during exploration, and a
throw would stop us from seeing subsequent frames.

## Result (on real hardware, 2026-09-19)

Slice 1 succeeded completely. On the real WHOOP 5AG0185866 strap, via
WebBLE:
1. `CLIENT_HELLO` was written to `…0002` with no error.
2. The strap responded with two notifications on `…0003`, both `cmd=145`
   (`0x91`, matching the hello's own cmd byte — a request/response echo).
3. Both frames passed CRC16 and CRC32 validation in our decoder
   (`crc16Valid=true`, `crc32Valid=true` on both) — proving the decoder
   is parsing real frames correctly, not accepting garbage.
4. The second frame's payload contains the strap's own serial number
   as plain ASCII (`5AG0185866`, bytes 53,65,71,48,49,56,53,56,54,54),
   plus what appears to be a longer hex-string device identifier and
   several trailing numeric fields (likely version/build info) whose
   exact schema is not yet known.

**Conclusion:** the proprietary channel is fully viable, not just
reachable. Next slice: fetch and decode `whoop_protocol.json` from
NOOP's repo to get the real field schema for this response (and
others), rather than guessing at the trailing numeric fields' meaning.

## Follow-on work done same session (beyond original Slice 1 scope)

- Resolved the header-bytes open question (see OpenStrap/protocol's
  `band.dart`): they're a direction marker, `[0x00,0x01]` outbound
  (host→strap COMMAND), `[0x01,0x00]` inbound (strap→host, any other
  packet type) — byte-verified by that project against 8 real
  fixtures, and independently cross-checked here against our own
  captured GET_HELLO responses (which do carry `[0x01,0x00]`).
- Built `encodeWhoop5Command(cmd, payload)` in `whoop-protocol.js`.
  Golden test: `encodeWhoop5Command(0x91,[1])` reproduces the real,
  hardware-verified `CLIENT_HELLO` byte-for-byte.
- **GET_BATTERY_LEVEL (cmd=26, payload=[0x00]) works** — verified on
  real hardware, returned 9.9%. Response field layout (payload[2] |
  payload[3]<<8, /10 = percent) sourced from NOOP's `PostHooks.swift`.
- **REPORT_VERSION_INFO (cmd=7) does NOT work** — tried both an empty
  payload and `[0x01]` (a documented gen5 fix for two OTHER commands
  with the same "empty payload silently rejected" bug, from
  OpenStrap/protocol's `commands.dart`). Both attempts got zero
  response on all 4 notify channels. No real captured fixture exists
  in that repo's test suite either. **Parked — not blocking anything
  else, low value (just a version string), do not re-attempt without
  new evidence** (a real packet capture, or another reference
  implementation that actually gets a response).

## Next real target: historical-data offload (bigger sub-project)

Real vitals (SpO2, skin temperature) are **not** available via a
simple live command — traced to `Gen5HistorySample` in
OpenStrap/protocol's `gen5_records.dart`, which extends
`Gen5HistoricalRecord`. They only arrive through WHOOP's
`HISTORICAL_DATA` (type 47) offload: a stateful multi-step protocol
(request a range via `GET_DATA_RANGE` → `SEND_HISTORICAL_DATA` →
strap streams chunked records → each chunk framed by `METADATA` (type
49) `HISTORY_START`/`HISTORY_END` markers → acknowledge each chunk
with `HISTORICAL_DATA_RESULT` carrying an 8-byte trim-cursor token
from the `HISTORY_END` marker → repeat until `HISTORY_COMPLETE`).

This deserves its own brainstorming → spec → plan cycle before
implementation, same as the original handshake work — it's a real
subsystem (stateful, multi-packet-type), not a one-off command. Field
layouts already known from `gen5_records.dart` (read directly, not
AI-summarized — trust level is high):
- Skin temp: signed int16 LE at `inner[65:67]` (= `payload[62:64]`
  once you strip our 3-byte type/seq/cmd prefix), ÷100 = °C. Sentinel
  -5000 (-50.00°C) means unavailable — must check for this before
  displaying.
- SpO2: single byte at `inner[74]` (= `payload[71]`) — encoding is
  **not fully pinned down even by the source project** (they
  deliberately refuse to publish it as a percentage). Treat as a raw
  diagnostic value only until more evidence exists, not a real SpO2%.
- `inner` offsets are relative to the frame's inner record starting at
  the `type` byte (frame-abs = inner + 8, since gen5's envelope header
  is exactly 8 bytes); our own `decoded.payload` already strips the
  3-byte `[type,seq,cmd]` prefix, so `payload[N] = inner[N+3]`.

Respiratory rate: not found anywhere in `gen5_records.dart` in this
session's research — still completely unlocated, separate research
task.

## Testing

There's no way to unit-test against real strap behavior. Verification
is:
1. Unit-level sanity: run the CRC16/CRC32 functions against the known
   `CLIENT_HELLO` frame and confirm they reproduce its embedded CRC16
   (`0x71E6`) and CRC32 (`0x8D5C3E36`) — this is a real, checkable
   assertion computable without hardware.
2. On-device: manual test in WebBLE on the real strap, reporting the
   log output back for review.
