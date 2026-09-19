# WHOOP 5.0/MG Data Dictionary

Status: fields below are from `Gen5HistorySample`, decoded out of
`HISTORICAL_DATA` (packet type 47) records, the only record shape decoded
so far. All offsets are relative to `payload[N]`, where `payload` already
has the 3-byte `[type, seq, cmd]` prefix stripped (i.e. `payload[N]` =
`inner[N+3]` in `OpenStrap/protocol`'s `gen5_records.dart` notation).
Record length observed: 109 bytes.

Implementation: `decodeGen5HistorySample()` in `whoop-protocol.js`, with a
golden test in `whoop-protocol.test.js` built from a real captured record.

| Field | Offset | Type | Scale | Status | Notes |
|---|---|---|---|---|---|
| Per-record sequence index | `payload[0:2]` | u16 LE | raw | EXPERIMENTALLY_CONFIRMED | Increments by 1 per record in observed captures; not yet wired into the decoder function, only noticed during manual analysis. |
| (constant tag, `0x64,0x01` observed) | `payload[2:4]` | 2 bytes | — | UNKNOWN | Constant across every record seen so far; meaning not determined (possibly a record-type/version tag). |
| `timestamp` | `payload[4:8]` | u32 LE | unix seconds | CONFIRMED | Verified: decoded to a real, plausible sleep time (~1:22am local) matching the actual night the data was captured. Increments by ~1 per record, consistent with a 1Hz sampling rate. |
| `tempAux1C` | `payload[58:60]` | i16 LE | ÷10 = °C | PARTIALLY_CONFIRMED | Labeled "fuel-gauge cell temperature" in reference material; plausible values observed (~32.6°C) but not independently cross-checked against a known-good reading. |
| `tempAux2C` | `payload[60:62]` | i16 LE | ÷10 = °C | PARTIALLY_CONFIRMED | Labeled "fuel-gauge ambient temperature"; same caveat as above. |
| `skinTempC` | `payload[62:64]` | i16 LE, **signed** | ÷100 = °C | CONFIRMED | Verified: 34.3°C observed, physiologically plausible for worn skin contact. Sentinel `-5000` raw (-50.00°C) means unavailable/error — must be checked before displaying (see `skinTempAvailable` in the reference material and this project's `decodeGen5HistorySample`). |
| `statusWord0` | `payload[64:66]` | u16 LE | bitfield | CONFIRMED | Bits 0-1 = channel index, bits 8-11 = LED-current index, bits 12-15 = saturation-majority flags. Verified: three consecutive status words (`statusWord0/1/2`) showed channel indices 0, 1, 2 in sequence exactly as documented — strong structural confirmation. |
| `statusWord1` | `payload[66:68]` | u16 LE | bitfield | CONFIRMED | Same layout as `statusWord0`, channel index 1. |
| `statusWord2` | `payload[68:70]` | u16 LE | bitfield | CONFIRMED | Same layout as `statusWord0`, channel index 2. |
| `sleepStateByte` | `payload[70]` | u8 | bitfield | CONFIRMED | Bits 4-5 = sleep state enum (see below); bits 0-1 and 2-3 have other documented meanings (primary-flags snapshot, passive strap-fit classifier) not yet surfaced in this project's decoder. |
| `sleepState` (0=wake, 1=still, 2=sleep, 3=up) | derived from `sleepStateByte` bits 4-5 | enum | — | CONFIRMED | Verified: value 2 ("sleep") observed at a real ~1:22am timestamp. |
| `spo2CandidateRaw` | `payload[71]` | u8 | raw, **not a percentage** | PARTIALLY_CONFIRMED | The *existence* of this byte and its rough behavior (mostly 0, occasionally 95-99 during sleep) is documented and matches what was observed (0 in the one real record checked). The actual encoding to a real SpO2 percentage is explicitly **not confirmed** by any source consulted — do not surface this as a real SpO2 value. |
| `pdMeanB`, `pdMeanA` | `payload[95]`, `payload[96]` | u8 each | raw | UNKNOWN | Referenced in source material as "quantized photodiode mean diagnostics," no established physical unit; not implemented in this project's decoder yet. |

## Not yet located at all

- **Respiratory rate** — no byte offset found in any source consulted.
- **HRV / RR-intervals within historical records** — this project's
  historical decoder does not currently extract heart-rate-related fields
  from `Gen5HistorySample`; unclear whether they're present in this record
  shape or a different one (`Gen5OpticalBuffer`, `Gen5PpgWaveform`, etc.,
  referenced in `gen5_records.dart` but not decoded here).
- **Steps / calories / activity classification** — not investigated.

## Other record shapes referenced but NOT decoded by this project

`OpenStrap/protocol`'s `gen5_records.dart` documents several other
versioned record decoders that this project has not implemented or
verified against real data:

- `Gen5OpticalBlock` / `Gen5OpticalBuffer` — raw optical sensor blocks.
- `Gen5ImuBuffer` — accelerometer/gyroscope data.
- `Gen5PpgReconstruction` / `Gen5PpgWaveform` — reconstructed PPG waveform.
- `Gen5ResearchOpticalWindow` / `Gen5ResearchRecord` — explicitly documented
  there as "research telemetry, not a locally decoded health metric."
- Version-specific decoders `Gen5V18Decoder`, `Gen5V20Decoder`,
  `Gen5V21Decoder`, `Gen5V22Decoder`, `Gen5V26Decoder` — different record
  schema versions; this project has only encountered and decoded whatever
  version corresponds to the 109-byte `Gen5HistorySample` shape above.

All of these are UNKNOWN from this project's own perspective — referenced,
not verified.
