# Pulse — WHOOP companion app (context for Claude Code)

## Goal
Chikku's WHOOP subscription ended. He owns a WHOOP 5.0/MG strap and wants a
personal (not public) web app replicating WHOOP's recovery/strain/sleep/HRV
features, usable on his iPhone.

## Constraints discovered so far
- iOS Safari does not support the Web Bluetooth API at all (WebKit limitation).
  The only way to get BLE working on iPhone as a *web app* is a third-party
  browser like Bluefy or WebBLE (both free on the App Store), which polyfill
  `navigator.bluetooth`.
- WHOOP's proprietary framed BLE protocol (needed for auto sleep staging,
  historical offload straight off the strap, SpO2/skin temp/resp rate over BLE)
  is reverse-engineered by the open-source NOOP project: https://github.com/7781291/noop
  Full protocol spec pulled from that repo's docs/PROTOCOL.md:
  - WHOOP 4.0 service `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` (CRC8 header, CRC32 payload)
  - WHOOP 5.0/MG service `fd4b0001-cce1-4033-93ce-002d5875f58a` (CRC16-Modbus header)
  - Standard BLE Heart Rate service `180D` / characteristic `2A37` works UNBONDED
    on both generations — this is what Pulse currently uses for live HR + R-R intervals.
  - WHOOP 5.0 bonding for the deeper proprietary channel is the hard part: the strap
    holds one Bluetooth bond at a time, must be freed from the official app first.
- Current Pulse app (`index.html`) does NOT implement the full proprietary frame
  decoder — only standard BLE Heart Rate + local IndexedDB storage + published-method
  analytics (RMSSD HRV, Karvonen %HRR strain, z-score recovery). This was a deliberate
  choice to avoid shipping an unverified/guessed byte-level decoder.

## What's built (index.html — single self-contained file)
- Web Bluetooth connect via standard Heart Rate (180D/2A37) + Battery (180F/2A19) services
- Local IndexedDB storage (hrSamples, dailyMetrics, settings) — nothing leaves the device
- Recovery score: HRV/RHR z-score vs rolling 30-day baseline + sleep bonus
- Strain: Karvonen %HRR accumulated through the day, log-scaled 0-21
- Manual sleep start/stop with HR-based overnight curve (no accelerometer access)
- WHOOP CSV export importer (Settings > Data > Import WHOOP export) — parses
  physiological_cycles.csv columns exactly as WHOOP names them (verified against
  Chikku's real 317-day export)
- Recovery ring, strain gauge, sparklines, 30-day trends — dark/light theme aware

## Known gaps / good next steps for Claude Code
1. Port the actual WhoopProtocol frame decoder (Swift, in NOOP's repo under
   Packages/WhoopProtocol/) to JS for the proprietary channel — full byte layout,
   CRC tables, and command list are documented in NOOP's docs/PROTOCOL.md.
2. Real accelerometer-based sleep staging requires that proprietary HISTORICAL_DATA
   (type 47) stream — currently out of scope, sleep is HR-curve + manual timing only.
3. WHOOP 5.0/MG bonding flow (freeing the strap from the official app, CLIENT_HELLO
   handshake) is the trickiest part if pursuing #1.
4. Currently hosted as a Claude "Artifact" (claude.ai link) which caused a blank-page
   issue inside the Bluefy browser after login — self-hosting on GitHub Pages
   (upload index.html, enable Pages) was the working fallback.

## Distribution
- Must be opened via Bluefy or WebBLE on iPhone (not Safari) for BLE to work at all.
- Zero ongoing cost: Bluefy/WebBLE are free, GitHub Pages hosting is free,
  IndexedDB storage is free/local.
