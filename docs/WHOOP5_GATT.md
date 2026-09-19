# WHOOP 5.0/MG GATT Layout

Status: CONFIRMED — enumerated live against the real strap via Web Bluetooth
(`getPrimaryService` / `getCharacteristics`), and 4 of the 5 characteristics
have been actively read from/written to and produced valid responses.

## Standard services (also present, unrelated to the proprietary channel)

| Service | UUID | Status |
|---|---|---|
| Heart Rate | `0000180d-...` (0x180D) | CONFIRMED — this is the *advertised* service; `requestDevice` must filter on this, since the proprietary service is not advertised. |
| Battery | `0000180f-...` (0x180F) | UNKNOWN — declared as an optional service in this project's code but never actually exercised; battery is instead read via the proprietary `GET_BATTERY_LEVEL` command. |

## Proprietary service: `fd4b0001-cce1-4033-93ce-002d5875f58a`

Not advertised — must be requested via `optionalServices` after connecting
via a filter on the advertised Heart Rate service.

| Characteristic | UUID | Direction | Status |
|---|---|---|---|
| Command write | `fd4b0002-cce1-4033-93ce-002d5875f58a` | App → strap | CONFIRMED — used for `CLIENT_HELLO`, `GET_BATTERY_LEVEL`, `GET_DATA_RANGE`, `SEND_HISTORICAL_DATA`, `HISTORICAL_DATA_RESULT` (ACK). All via `writeValueWithResponse`. |
| Command-response notify | `fd4b0003-cce1-4033-93ce-002d5875f58a` | Strap → app | CONFIRMED — `GET_HELLO` and `GET_BATTERY_LEVEL` responses (`COMMAND_RESPONSE`, packet type 36) observed here. |
| Events notify | `fd4b0004-cce1-4033-93ce-002d5875f58a` | Strap → app | PARTIALLY_CONFIRMED — subscribed successfully; observed occasional `EVENT` (packet type 48) notifications during a historical offload run, contents not decoded. |
| Data notify | `fd4b0005-cce1-4033-93ce-002d5875f58a` | Strap → app | CONFIRMED — `HISTORICAL_DATA` (packet type 47) chunks and `METADATA` (packet type 49) sync markers both observed here during offload. |
| Memfault/battery-pack notify | `fd4b0007-cce1-4033-93ce-002d5875f58a` | Strap → app | UNKNOWN — subscribed successfully, no notifications observed on it in this project's testing. |

## Discovery gotcha (important for any implementation, not just this one)

`requestDevice`-style filtering by *advertised* service UUIDs will find
nothing if you filter directly on the proprietary service — the strap does
not advertise it. You must filter on the Heart Rate service (which *is*
advertised) and put the proprietary service UUID in `optionalServices` to
unlock GATT-level access to it after connecting. This is a Web Bluetooth
API characteristic, but the underlying fact — the proprietary service isn't
in the advertisement payload — is a property of the strap itself and will
matter for any BLE central implementation (native included), which is why
it's recorded here rather than filed as a web-only quirk.
