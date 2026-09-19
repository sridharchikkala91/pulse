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

## What this means for scoping future work

Given (3) and (8) above, the "phone doesn't need to be with the user all
day" requirement — a core goal of the wider platform vision — is
**genuinely untested** by anything built so far. It depends entirely on
native background BLE central-role behavior on iOS and Android, which this
project has zero direct experience with (the web implementation cannot
even survive simple backgrounding, let alone hours away from the phone).
This should be the first thing validated in any native implementation,
before investing in the rest of the platform.
