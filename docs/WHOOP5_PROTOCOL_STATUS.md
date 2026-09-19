# WHOOP 5.0/MG Protocol Research Status

Status as of 2026-09-19. This consolidates real, hardware-verified research
performed against the project owner's own WHOOP 5.0 strap (device name
`WHOOP 5AG0185866`) via a web-based BLE client (Pulse, this repo's existing
`index.html` + `whoop-protocol.js`), plus reference material from public
repositories. Every claim below is labeled by confidence. Nothing here is
invented — where something is unverified, it says so.

## Status legend

- **CONFIRMED** — directly observed against the real strap in this project, with evidence (byte-level capture, decoded and cross-checked).
- **PARTIALLY_CONFIRMED** — the shape/mechanism is confirmed, but not every detail (e.g. we know a field exists and roughly where, but not its full range or edge cases).
- **EXPERIMENTAL** — implemented and appears to work, but only tested a handful of times, not stress-tested.
- **UNKNOWN** — referenced in third-party research but not independently verified by this project.
- **NOT_CURRENTLY_POSSIBLE** — actively attempted and failed, or structurally blocked (e.g. requires WHOOP's cloud, not available over BLE at all).

## Reference repositories used

| Repository | URL | License | What we used it for |
|---|---|---|---|
| `7781291/noop` | github.com/7781291/noop | **None declared** (GitHub API reports no LICENSE file — all-rights-reserved by default) | Read `docs/PROTOCOL.md` (envelope format, command table, CRC algorithms) and `PostHooks.swift` (response field layouts for `GET_BATTERY_LEVEL`, `REPORT_VERSION_INFO`) for **protocol facts** only. No code from this repo was copied into this project — all JS in `whoop-protocol.js` is our own independent implementation, written from the documented byte-level facts, not transcribed from their Swift source. |
| `OpenStrap/protocol` | github.com/OpenStrap/protocol | **MIT** | Read `band.dart`, `commands.dart`, `constants.dart`, `control.dart`, `gen5_records.dart` directly (not through summarized fetches, to avoid transcription errors) for the gen5 envelope direction-marker semantics, command opcodes, `METADATA`/`HISTORY_END` field layout, and `Gen5HistorySample` sensor field offsets. Same as above: no Dart code was copied — all logic was re-implemented in JavaScript from the documented facts and byte offsets, with attribution here per MIT's requirements. |

**Note on `noop`'s missing license:** with no declared license, its code is not licensed for reuse or redistribution under copyright law by default. This project has not copied any of its source code — only used its written documentation of protocol *facts* (byte layouts, command numbers) as reference material, the same way one would use a technical article. If actual code reuse from `noop` is ever considered, its author should be contacted for explicit permission first.

## Capability status matrix

| Capability | Status | Evidence |
|---|---|---|
| BLE service/characteristic discovery (`fd4b0001-...` + 5 characteristics) | **CONFIRMED** | Enumerated live via Web Bluetooth on the real strap. |
| `CLIENT_HELLO` handshake (static 16-byte frame, cmd=`GET_HELLO`=0x91) | **CONFIRMED** | Strap responds with a valid, CRC-verified identity frame containing its own serial number in plaintext ASCII. |
| Envelope format (header, CRC16-Modbus, CRC32) | **CONFIRMED** | Our encoder reproduces the real `CLIENT_HELLO` frame byte-for-byte; decoder validates both CRCs on every real received frame. |
| Header "direction marker" bytes semantics | **CONFIRMED** | `[0x00,0x01]` outbound / `[0x01,0x00]` inbound, cross-checked against real captured response frames. |
| `GET_BATTERY_LEVEL` (cmd=26) | **CONFIRMED** | Real response decoded to a plausible battery percentage (9.9% at time of test). |
| `REPORT_VERSION_INFO` (cmd=7) | **NOT_CURRENTLY_POSSIBLE** (on this firmware, so far) | Tried with empty payload and `[0x01]` revision byte; strap gave zero response both times, on all 4 notify channels. Not blocking anything else. |
| `GET_DATA_RANGE` (cmd=0x22) | **CONFIRMED** | Works with `[0x00]` payload (not gen5's documented empty payload, which got silence). Decodes oldest/newest record timestamps. |
| `SEND_HISTORICAL_DATA` historical offload (start/chunks/ACK/complete) | **CONFIRMED** | Full state machine implemented and run to completion multiple times on the real strap; one run alone pulled 17,760+ records before disconnecting, later runs reached `HISTORY_COMPLETE`. |
| `HISTORICAL_DATA_RESULT` ACK with trim-cursor token | **CONFIRMED** | Strap explicitly confirms each ACK as accepted (`cmd=23 payload=[1,1,...]` = success) and advances to the next batch. |
| Historical sensor record decoding (`Gen5HistorySample`: timestamp, sleep state, skin temp, aux temps, optical status words) | **CONFIRMED** | Decoded real captured data; timestamp landed at a plausible real sleep time, sleep-state bit matched, skin temp was physiologically plausible, three optical status words showed channel indices 0/1/2 in sequence exactly as documented. |
| SpO2 | **PARTIALLY_CONFIRMED** | The byte position is known (`payload[71]` in our indexing), but the **encoding is not confirmed** — the OpenStrap/protocol source explicitly refuses to publish it as a percentage, and we follow the same caution. It is stored as a raw byte only. |
| Respiratory rate | **UNKNOWN** | Not located anywhere in the `gen5_records.dart` source consulted. No byte offset known. |
| Real-time HR toggle (`TOGGLE_REALTIME_HR`, cmd=3) | **UNKNOWN** | Referenced in `noop`'s command table; never attempted against the real strap. |
| IMU / accelerometer / gyroscope raw streams | **UNKNOWN** | `Gen5ImuBuffer`, `REALTIME_IMU_DATA_STREAM`/`HISTORICAL_IMU_DATA_STREAM` packet types exist in reference material; not attempted. |
| Optical waveform / raw PPG data | **UNKNOWN** | `Gen5PpgWaveform`, `Gen5OpticalBuffer` classes exist in reference material; not attempted. |
| VO2max / fitness age (WHOOP's own) | **NOT_CURRENTLY_POSSIBLE** | Computed server-side by WHOOP's cloud from a proprietary model; never transmitted over BLE in any form. Only an independently-calculated estimate is possible (see Pulse's own "Fitness age" feature, explicitly labeled as an estimate). |
| Recovery %/Strain/Sleep % (WHOOP's own official scores) | **NOT_CURRENTLY_POSSIBLE** | Same reason — cloud-computed, never sent to the strap or exposed over BLE. |
| Bonding/authentication over Web Bluetooth via Bluefy (iOS browser) | **NOT_CURRENTLY_POSSIBLE** | Bluefy could never complete the BLE authentication step needed even for the *standard* Bluetooth Heart Rate service on this strap (`ATT error 2` — Read Not Permitted — with no native OS pairing prompt ever surfacing). |
| Bonding/authentication over Web Bluetooth via WebBLE (iOS browser) | **CONFIRMED** | WebBLE completes the same connection cleanly, standard HR and the full proprietary channel both. |

## Gaps for native (Swift/Kotlin) implementation to investigate

These are things this project's Web Bluetooth implementation cannot answer,
because Web Bluetooth itself doesn't expose them — a native CoreBluetooth or
Android BLE implementation would need fresh investigation:

- Whether native BLE bonding (real OS-level pairing, not just an
  application-layer handshake) is required, optional, or irrelevant for the
  proprietary channel — Web Bluetooth has no bonding/pairing API at all, so
  this project has only ever used whatever ambient link security the OS
  already provides.
- Background/offline reconnection behavior (the "phone doesn't need to be
  nearby all day" requirement) — Web Bluetooth connections do not survive
  backgrounding at all on iOS (confirmed: our historical-offload runs
  disconnect when the browser tab is backgrounded), so this is an open
  question for native background BLE central-role code, not something this
  project can speak to from experience.
