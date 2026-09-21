# WHOOP 5.0/MG — Known Limitations

## Structural (cannot be solved by more protocol research)

1. **WHOOP's official Recovery %, Strain, Sleep %, and "WHOOP Age" scores are
   never transmitted over BLE in any form.** They are computed by WHOOP's
   cloud servers from raw sensor data plus population-scale modeling this
   project has no access to. The strap itself only ever sends raw sensor
   readings. Any equivalent this project produces will be an independently
   calculated estimate, not a reproduction of WHOOP's algorithm — this
   must always be labeled clearly, per the project's own stated principle
   of distinguishing WHOOP-derived data from app-calculated data.
2. **Advanced Labs bloodwork data** (used by WHOOP's real biological-age
   feature) is never available from the strap at all — it comes from an
   external lab integration on WHOOP's own platform.
3. **Web Bluetooth connections do not survive iOS backgrounding.** Every
   historical-offload run in this project's testing disconnected when the
   browser tab lost focus or the phone screen locked. This is a hard
   platform limitation of the *web* implementation specifically — whether
   native CoreBluetooth/Android BLE central-role code can maintain a
   connection through backgrounding is a genuinely open question this
   project has not tested, since it currently has no native implementation.

## Firmware-specific (observed on this specific strap, may not generalize)

4. **`REPORT_VERSION_INFO` (cmd=7) never responds**, even with payload
   variants (`[]`, `[0x01]`) that fixed the identical symptom for other
   commands per reference material. Root cause unconfirmed — could be
   firmware-version-specific, could be a permanently unsupported command
   on gen5, could need a payload variant not yet tried. Not blocking
   anything else; parked.
5. **gen5's documented "empty payload" convention for `GET_DATA_RANGE` and
   `SEND_HISTORICAL_DATA`** (per `OpenStrap/protocol`, marked there as
   unverified) **did not work on this strap** — `[0x00]` was required
   instead. Any new implementation should try both and not assume the
   published convention is correct for every gen5 firmware revision.

## Data-completeness limitations of the current implementation

6. **Interrupted historical-offload sessions permanently consume backlog
   data** (the strap's trim cursor advances on every ACK, deleting
   acknowledged records from its buffer) **without necessarily producing a
   complete decoded picture**, if the disconnect splits one continuous
   sleep period across multiple separate sync sessions before an
   auto-reconnect mechanism existed. This caused one real night's sleep to
   be under-reported (1.6h decoded vs. an unknown larger real value) during
   this project's initial backlog catch-up, before an auto-reconnect loop
   was added. Going forward (with auto-reconnect keeping a single logical
   sync attempt alive across BLE drops), this should not recur for new
   nights, but historical data lost this way cannot be recovered — it no
   longer exists on the strap.
7. **Only one record shape (`Gen5HistorySample`) has been decoded.** Real
   sleep staging detail beyond a single wake/still/sleep/up enum, real
   accelerometer/IMU data, optical waveforms, and respiratory rate all
   require decoding record shapes this project has not yet attempted (see
   `WHOOP5_DATA_DICTIONARY.md`).
8. **No native mobile implementation exists yet.** Everything documented
   here comes from a web-based (Web Bluetooth) client. A native
   CoreBluetooth/Android BLE implementation may encounter different
   behavior around bonding, background execution, and connection
   stability that this research cannot predict.

## Real incident: 60,000+ record sync lost entirely (2026-09-21, iOS, fixed)

A real historical offload run on the physical strap decoded 60,000+
records (confirmed via the Diagnostics packet counters) but saved
**zero nights** to the database — "Last synchronization: Never" after
it stopped. Root cause: nothing was persisted until the very end of a
sync (`finishSync()`), and the app had no `UIBackgroundModes`
declared, so iOS almost certainly suspended it when the screen locked
partway through the (multi-minute-plus) drain. The strap's own trim
cursor still advanced for real (the next run started at a much lower
record count, proving the ACKs landed) — so backlog progress was real,
but the sleep/vitals data extractable from that chunk of history is
gone permanently; it can't be re-requested from the strap.

**Fixed** by (1) declaring `bluetooth-central` in `UIBackgroundModes`
so an active sync is far less likely to be suspended by backgrounding,
and (2) checkpointing the session-extraction-and-save logic every
2,000 new samples instead of only at the very end, so a kill mid-sync
loses at most one checkpoint's worth of data. Not yet confirmed to
survive an actual real-world backgrounding/overnight test — that
still needs to happen before this is considered fully resolved.

## What this means for scoping future work

Given (3) and (8) above, the "phone doesn't need to be with the user all
day" requirement — a core goal of the wider platform vision — is
**genuinely untested** by anything built so far. It depends entirely on
native background BLE central-role behavior on iOS and Android, which this
project has zero direct experience with (the web implementation cannot
even survive simple backgrounding, let alone hours away from the phone).
This should be the first thing validated in any native implementation,
before investing in the rest of the platform.
