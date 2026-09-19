# WHOOP 5.0/MG Packet Framing & Types

Status: CONFIRMED for everything in this document unless marked otherwise —
verified by an encoder that reproduces a real captured frame byte-for-byte,
and a decoder that validates both checksums on every real frame received
from the strap. Implementation: `whoop-protocol.js` in this repo.

## Envelope

```
[0xAA][format][declLength u16 LE][direction marker, 2 bytes][crc16 u16 LE][type][seq][cmd][payload...][crc32 u32 LE]
  0     1        2        3        4              5           6      7     8     9    10    11...        last 4
```

- **`0xAA`** — start-of-frame byte, constant.
- **`format`** — observed constant `0x01` in every frame seen.
- **`declLength`** (u16, little-endian) — count of bytes from `type` through
  the end of `crc32`, inclusive. `innerEnd = 8 + declLength`.
- **Direction marker** (2 bytes) — CONFIRMED via `OpenStrap/protocol`'s
  `band.dart` (byte-verified there against 8 real fixtures) and
  independently cross-checked here against real captured response frames:
  - `[0x00, 0x01]` — every host→strap `COMMAND` frame.
  - `[0x01, 0x00]` — every strap→host frame of any other packet type
    (`METADATA`, `HISTORICAL_DATA`, `REALTIME_DATA`, `EVENT`,
    `COMMAND_RESPONSE`, `CONSOLE_LOGS`).
- **`crc16`** (u16, little-endian) — CRC-16/MODBUS (poly `0xA001` reflected
  form of `0x8005`, init `0xFFFF`, no final XOR) over bytes `[0:6]` (the
  6 bytes before it).
- **`type`** — packet type (see table below).
- **`seq`** — sequence byte. Only ever observed as `0x01` in this project's
  testing (every command sent used `seq=1`); unclear whether the strap
  requires incrementing values for longer sessions — not tested.
- **`cmd`** — command number (for `COMMAND`/`COMMAND_RESPONSE`) or a
  sub-type byte (for `METADATA`) — semantics depend on `type`.
- **`payload`** — variable length, `declLength - 7` bytes.
- **`crc32`** (u32, little-endian) — CRC-32/ISO-HDLC (zlib: poly
  `0xEDB88320` reflected, init `0xFFFFFFFF`, final XOR `0xFFFFFFFF`) over
  `[type, seq, cmd, ...payload]`.

## Checksum algorithms (all verified against independently-published standard test vectors, not invented)

| Algorithm | Parameters | Verified check value for ASCII "123456789" |
|---|---|---|
| CRC-8/SMBUS | poly `0x07`, init `0x00`, no reflection, no final XOR | `0xF4` |
| CRC-32/ISO-HDLC (zlib) | poly `0xEDB88320` (reflected), init `0xFFFFFFFF`, final XOR `0xFFFFFFFF` | `0xCBF43926` |
| CRC-16/MODBUS | poly `0xA001` (reflected form of `0x8005`), init `0xFFFF`, no final XOR | `0x4B37` |

CRC-8 is documented in `noop`'s reference material for the older WHOOP 4.0
envelope; this project's gen5-only implementation does not currently use it
(kept for completeness/future gen4 support).

## Packet types observed or documented

| Value | Name | Status |
|---:|---|---|
| 35 (`0x23`) | `COMMAND` | CONFIRMED — every command this project sends uses this. |
| 36 (`0x24`) | `COMMAND_RESPONSE` | CONFIRMED — `GET_HELLO`, `GET_BATTERY_LEVEL`, `GET_DATA_RANGE`, `HISTORICAL_DATA_RESULT` ACK responses. |
| 37 (`0x25`) | `PUFFIN_COMMAND` | UNKNOWN — battery-pack-specific, not attempted. |
| 38 (`0x26`) | `PUFFIN_COMMAND_RESPONSE` | UNKNOWN |
| 40 (`0x28`) | `REALTIME_DATA` | UNKNOWN — never attempted (would need `TOGGLE_REALTIME_HR` first per reference material). |
| 43 (`0x2B`) | `REALTIME_RAW_DATA` | UNKNOWN |
| 47 (`0x2F`) | `HISTORICAL_DATA` | CONFIRMED — this is the historical-offload payload carrying `Gen5HistorySample` records. |
| 48 (`0x30`) | `EVENT` | PARTIALLY_CONFIRMED — observed arriving unprompted during an offload run; contents not decoded. |
| 49 (`0x31`) | `METADATA` | CONFIRMED — sync markers for the historical offload (see below). |
| 50 (`0x32`) | `CONSOLE_LOGS` | UNKNOWN |
| 51 (`0x33`) | `REALTIME_IMU_DATA_STREAM` | UNKNOWN |
| 52 (`0x34`) | `HISTORICAL_IMU_DATA_STREAM` | UNKNOWN |
| 53-56 | Puffin/battery-pack related | UNKNOWN |

## `METADATA` (type 49) sync markers — historical offload control flow

`cmd` byte doubles as the sub-type:

| Sub-type | Name | Meaning | Status |
|---:|---|---|---|
| 1 | `HISTORY_START` | Informational — a new batch is starting. No action required. | CONFIRMED |
| 2 | `HISTORY_END` | End of a batch. Payload carries an 8-byte token (at `payload[10:18]` in this project's payload-after-cmd indexing) that must be echoed back via `HISTORICAL_DATA_RESULT` (cmd `0x17`, `[0x01, ...token]`) to advance the strap's trim cursor and receive the next batch. | CONFIRMED — every ACK sent this way was answered with an explicit success status by the strap. |
| 3 | `HISTORY_COMPLETE` | Offload finished. Do not ACK further. | CONFIRMED |

## Known command opcodes

| Code | Name | Payload used | Status |
|---:|---|---|---|
| 0x91 (145) | `GET_HELLO` | `[0x01]` (as a static full frame, `CLIENT_HELLO`) | CONFIRMED |
| 26 (0x1A) | `GET_BATTERY_LEVEL` | `[0x00]` | CONFIRMED — response payload `[status, status2?, batteryRaw_lo, batteryRaw_hi, ...]`, percent = `(payload[2] | payload[3]<<8) / 10`. |
| 7 | `REPORT_VERSION_INFO` | Tried `[]` and `[0x01]` | NOT_CURRENTLY_POSSIBLE on this firmware — zero response either way. |
| 0x22 (34) | `GET_DATA_RANGE` | `[0x00]` (gen5's documented empty payload got silence) | CONFIRMED — response decodes oldest/newest record unix timestamps. |
| 0x16 (22) | `SEND_HISTORICAL_DATA` | `[0x00]` (same empty-payload caveat as above) | CONFIRMED — starts the historical offload drain. |
| 0x17 (23) | `HISTORICAL_DATA_RESULT` | `[0x01, ...8-byte token]` | CONFIRMED — the batch ACK. |

**Open question, unresolved:** the empty payloads that `OpenStrap/protocol`
documents for gen5's `GET_DATA_RANGE`/`SEND_HISTORICAL_DATA` did not work on
this strap — `[0x00]` was required instead. That source's claim wasn't
marked as hardware-verified (unlike the hello, which has an explicit test),
so it may simply be wrong, or firmware-version-dependent. Any new
implementation should be prepared to try both.
