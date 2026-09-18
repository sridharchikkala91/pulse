# WHOOP 5.0 Handshake + Decode Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove whether Pulse can complete WHOOP's `CLIENT_HELLO` handshake on the proprietary 5.0/MG BLE channel and decode whatever the strap sends back, without guessing at any undocumented protocol details.

**Architecture:** Pull the checksum math and frame decoder into a new standalone file, `whoop-protocol.js`, so it's testable with Node's built-in test runner (no DOM/Bluetooth needed for these pure functions). `index.html` loads it via `<script src="whoop-protocol.js">` and adds one new debug action that uses it against the real strap.

**Tech Stack:** Vanilla JS, no build step, no dependencies. Node's built-in `node:test`/`node:assert` for the checksum/decoder tests (Node v18+ required; this machine runs v26). Manual on-device testing in WebBLE for the final BLE step (no way to automate real hardware).

**Spec:** `docs/superpowers/specs/2026-09-18-whoop-5-handshake-design.md`

## Global Constraints

- Single self-contained-app distribution model: no build step, no bundler, no npm dependency added to the shipped app — `whoop-protocol.js` is a plain script file, not a module requiring a build.
- Do not implement any outgoing WHOOP 5.0 command frame other than the static `CLIENT_HELLO` — the header-byte semantics for other commands are undocumented (see spec's "Open question" section).
- All checksum/decoder logic must be verified against real, independently-documented CRC test vectors, not invented numbers.

---

## Task 1: Checksum primitives (CRC8, CRC32, CRC16-Modbus)

**Files:**
- Create: `whoop-protocol.js`
- Test: `whoop-protocol.test.js`

**Interfaces:**
- Produces: `WhoopProtocol.crc8(bytes)`, `WhoopProtocol.crc32(bytes)`, `WhoopProtocol.crc16Modbus(bytes)` — each takes an `Array<number>` or `Uint8Array` of byte values (0-255) and returns a single unsigned integer (crc8: 0-255, crc32: 0-4294967295, crc16Modbus: 0-65535).

- [ ] **Step 1: Write the failing test**

Create `whoop-protocol.test.js`:

```js
const test = require('node:test');
const assert = require('node:assert');
const { crc8, crc32, crc16Modbus } = require('./whoop-protocol.js');

const ASCII_123456789 = [0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38,0x39];

test('crc8 matches the standard CRC-8/SMBUS check value for "123456789"', () => {
  assert.strictEqual(crc8(ASCII_123456789), 0xF4);
});

test('crc32 matches the standard CRC-32/ISO-HDLC (zlib) check value for "123456789"', () => {
  assert.strictEqual(crc32(ASCII_123456789), 0xCBF43926);
});

test('crc16Modbus matches the standard CRC-16/MODBUS check value for "123456789"', () => {
  assert.strictEqual(crc16Modbus(ASCII_123456789), 0x4B37);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test whoop-protocol.test.js`
Expected: FAIL — `whoop-protocol.js` doesn't exist yet, so the `require` throws `MODULE_NOT_FOUND`.

- [ ] **Step 3: Write minimal implementation**

Create `whoop-protocol.js`:

```js
(function(root){
  "use strict";

  // CRC-8/SMBUS: poly 0x07, init 0x00, no reflection, no final XOR.
  function crc8(bytes){
    let crc = 0x00;
    for(const byte of bytes){
      crc ^= byte;
      for(let i=0;i<8;i++){
        crc = (crc & 0x80) ? ((crc<<1) ^ 0x07) & 0xFF : (crc<<1) & 0xFF;
      }
    }
    return crc;
  }

  // CRC-32/ISO-HDLC (zlib): poly 0xEDB88320 (reflected), init 0xFFFFFFFF, final XOR 0xFFFFFFFF.
  function crc32(bytes){
    let crc = 0xFFFFFFFF;
    for(const byte of bytes){
      crc ^= byte;
      for(let i=0;i<8;i++){
        crc = (crc & 1) ? ((crc >>> 1) ^ 0xEDB88320) : (crc >>> 1);
      }
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  // CRC-16/MODBUS: poly 0xA001 (reflected form of 0x8005), init 0xFFFF, no final XOR.
  function crc16Modbus(bytes){
    let crc = 0xFFFF;
    for(const byte of bytes){
      crc ^= byte;
      for(let i=0;i<8;i++){
        crc = (crc & 1) ? ((crc >>> 1) ^ 0xA001) : (crc >>> 1);
      }
    }
    return crc & 0xFFFF;
  }

  const api = { crc8, crc32, crc16Modbus };
  if(typeof module !== "undefined" && module.exports){
    module.exports = api;
  } else {
    root.WhoopProtocol = api;
  }
})(typeof window !== "undefined" ? window : globalThis);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test whoop-protocol.test.js`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
cd "/Users/sridharchikkala/Downloads/pulse whoop"
git add whoop-protocol.js whoop-protocol.test.js
git commit -m "Add CRC8/CRC32/CRC16-Modbus primitives for WHOOP protocol, verified against standard test vectors"
```

---

## Task 2: WHOOP 5.0 envelope decoder + static CLIENT_HELLO constant

**Files:**
- Modify: `whoop-protocol.js`
- Test: `whoop-protocol.test.js`

**Interfaces:**
- Consumes: `crc32(bytes)`, `crc16Modbus(bytes)` from Task 1 (same file, same module scope).
- Produces: `WhoopProtocol.CLIENT_HELLO` — a plain `Array<number>` of the 16 static handshake bytes. `WhoopProtocol.decodeWhoop5Frame(bytes)` — takes an `Array<number>` or `Uint8Array`, returns `null` if the buffer is too short to be a valid envelope, otherwise returns an object:
  `{ startByte, format, declLength, headerBytes: [b4, b5], crc16Received, crc16Computed, crc16Valid, type, seq, cmd, payload: Array<number>, crc32Received, crc32Computed, crc32Valid }`.

- [ ] **Step 1: Write the failing test**

Append to `whoop-protocol.test.js`:

```js
const { decodeWhoop5Frame, CLIENT_HELLO } = require('./whoop-protocol.js');

test('CLIENT_HELLO is the documented 16-byte static handshake frame', () => {
  assert.deepStrictEqual(CLIENT_HELLO, [
    0xAA,0x01,0x08,0x00,0x00,0x01,0xE6,0x71,
    0x23,0x01,0x91,0x01,0x36,0x3E,0x5C,0x8D
  ]);
});

test('decodeWhoop5Frame parses CLIENT_HELLO with both CRCs valid', () => {
  const decoded = decodeWhoop5Frame(CLIENT_HELLO);
  assert.notStrictEqual(decoded, null);
  assert.strictEqual(decoded.format, 0x01);
  assert.strictEqual(decoded.declLength, 8);
  assert.deepStrictEqual(decoded.headerBytes, [0x00, 0x01]);
  assert.strictEqual(decoded.type, 0x23);
  assert.strictEqual(decoded.seq, 0x01);
  assert.strictEqual(decoded.cmd, 0x91);
  assert.deepStrictEqual(decoded.payload, [0x01]);
  assert.strictEqual(decoded.crc16Valid, true);
  assert.strictEqual(decoded.crc32Valid, true);
});

test('decodeWhoop5Frame returns null for a buffer shorter than the minimum envelope', () => {
  assert.strictEqual(decodeWhoop5Frame([0xAA, 0x01, 0x00]), null);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test whoop-protocol.test.js`
Expected: FAIL — `decodeWhoop5Frame` and `CLIENT_HELLO` are undefined (destructuring from `require` returns `undefined` for missing keys, so calling `decodeWhoop5Frame(...)` throws `TypeError: decodeWhoop5Frame is not a function`).

- [ ] **Step 3: Write minimal implementation**

In `whoop-protocol.js`, add inside the IIFE (after the three CRC functions, before `const api = ...`):

```js
  const CLIENT_HELLO = [
    0xAA,0x01,0x08,0x00,0x00,0x01,0xE6,0x71,
    0x23,0x01,0x91,0x01,0x36,0x3E,0x5C,0x8D
  ];

  // WHOOP 5.0/MG envelope:
  // [0xAA][format][declLength u16 LE][header 2 bytes][crc16 u16 LE][type][seq][cmd][payload...][crc32 u32 LE]
  // declLength counts the bytes from `type` through the end of `crc32`, inclusive.
  function decodeWhoop5Frame(bytes){
    const b = Array.from(bytes);
    if(b.length < 8) return null;
    const declLength = b[2] | (b[3] << 8);
    const innerStart = 8;
    const innerEnd = innerStart + declLength;
    if(b.length < innerEnd || declLength < 7) return null;

    const headerBytes = [b[4], b[5]];
    const crc16Received = b[6] | (b[7] << 8);
    const crc16Computed = crc16Modbus(b.slice(0, 6));

    const type = b[innerStart];
    const seq = b[innerStart + 1];
    const cmd = b[innerStart + 2];
    const payload = b.slice(innerStart + 3, innerEnd - 4);
    const crc32Bytes = b.slice(innerEnd - 4, innerEnd);
    const crc32Received = (crc32Bytes[0] | (crc32Bytes[1] << 8) | (crc32Bytes[2] << 16) | (crc32Bytes[3] << 24)) >>> 0;
    const crc32Computed = crc32(b.slice(innerStart, innerEnd - 4));

    return {
      startByte: b[0], format: b[1], declLength, headerBytes,
      crc16Received, crc16Computed, crc16Valid: crc16Received === crc16Computed,
      type, seq, cmd, payload,
      crc32Received, crc32Computed, crc32Valid: crc32Received === crc32Computed
    };
  }
```

Update the `api` object at the bottom of the file:

```js
  const api = { crc8, crc32, crc16Modbus, decodeWhoop5Frame, CLIENT_HELLO };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test whoop-protocol.test.js`
Expected: PASS (6 tests total)

- [ ] **Step 5: Commit**

```bash
cd "/Users/sridharchikkala/Downloads/pulse whoop"
git add whoop-protocol.js whoop-protocol.test.js
git commit -m "Add WHOOP 5.0 envelope decoder and static CLIENT_HELLO constant"
```

---

## Task 3: Wire the handshake test into Pulse's debug UI

**Files:**
- Modify: `index.html`

**Interfaces:**
- Consumes: `WhoopProtocol.CLIENT_HELLO`, `WhoopProtocol.decodeWhoop5Frame(bytes)` (global `WhoopProtocol` object from `whoop-protocol.js`, loaded via `<script src>` before the main inline `<script>` block). Reuses the existing `WHOOP_PROPRIETARY_SERVICE` constant already defined in `index.html`'s inline script.
- Produces: nothing consumed elsewhere — this is a terminal debug action.

- [ ] **Step 1: Load `whoop-protocol.js` in `index.html`**

Find this line near the top of `index.html`:

```html
<script src="https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js"></script>
```

Add immediately after it:

```html
<script src="whoop-protocol.js"></script>
```

- [ ] **Step 2: Add the debug UI**

Find the existing debug card in the Connect screen:

```html
  <div class="section-title">Debug — proprietary channel probe</div>
  <div class="card">
    <p class="small muted" style="margin-bottom:10px;">Throwaway diagnostic. Tests whether the proprietary WHOOP service is reachable at all — not real functionality.</p>
    <button class="btn secondary" id="probeBtn">Test proprietary channel</button>
    <pre id="probeLog" class="small" style="white-space:pre-wrap; margin-top:10px; max-height:220px; overflow:auto; background:var(--surface-2); border-radius:10px; padding:10px;"></pre>
  </div>
```

Add a second card immediately after it:

```html
  <div class="section-title">Debug — CLIENT_HELLO handshake</div>
  <div class="card">
    <p class="small muted" style="margin-bottom:10px;">Throwaway diagnostic. Sends WHOOP's static CLIENT_HELLO frame and logs every notification received afterward, decoded where possible.</p>
    <button class="btn secondary" id="helloBtn">Test CLIENT_HELLO handshake</button>
    <pre id="helloLog" class="small" style="white-space:pre-wrap; margin-top:10px; max-height:280px; overflow:auto; background:var(--surface-2); border-radius:10px; padding:10px;"></pre>
  </div>
```

- [ ] **Step 3: Add the handshake test function**

In the inline `<script>` block, find:

```js
  function onDisconnected(){
```

Add immediately before it:

```js
  const toHex = bytes => Array.from(bytes).map(b => b.toString(16).padStart(2,"0")).join(" ");

  async function testClientHelloHandshake(){
    const log = $("helloLog");
    const line = s => { log.textContent += s + "\n"; log.scrollTop = log.scrollHeight; };
    log.textContent = "";
    line("Starting handshake test at " + new Date().toLocaleTimeString());
    try{
      line("Requesting device (filter: HR service)...");
      const device = await navigator.bluetooth.requestDevice({
        filters: [{ services:[HR_SERVICE] }],
        optionalServices: [BATTERY_SERVICE, WHOOP_PROPRIETARY_SERVICE]
      });
      line("Device picked: " + device.name);
      const server = await device.gatt.connect();
      line("GATT connected. Getting proprietary service...");
      const service = await server.getPrimaryService(WHOOP_PROPRIETARY_SERVICE);
      const notifyUuids = [
        "fd4b0003-cce1-4033-93ce-002d5875f58a",
        "fd4b0004-cce1-4033-93ce-002d5875f58a",
        "fd4b0005-cce1-4033-93ce-002d5875f58a",
        "fd4b0007-cce1-4033-93ce-002d5875f58a"
      ];
      for(const uuid of notifyUuids){
        try{
          const c = await service.getCharacteristic(uuid);
          await c.startNotifications();
          c.addEventListener("characteristicvaluechanged", (e)=>{
            const bytes = new Uint8Array(e.target.value.buffer);
            line("NOTIFY " + uuid.slice(0,8) + " raw: " + toHex(bytes));
            const decoded = WhoopProtocol.decodeWhoop5Frame(bytes);
            if(decoded){
              line("  decoded: type=" + decoded.type + " seq=" + decoded.seq + " cmd=" + decoded.cmd +
                   " payload=[" + decoded.payload.join(",") + "] crc16Valid=" + decoded.crc16Valid +
                   " crc32Valid=" + decoded.crc32Valid);
            } else {
              line("  (did not parse as a WHOOP 5.0 envelope)");
            }
          });
          line("Subscribed to notifications on " + uuid.slice(0,8));
        }catch(e){
          line("Could not subscribe to " + uuid.slice(0,8) + ": " + (e.message||e));
        }
      }
      const cmdChar = await service.getCharacteristic("fd4b0002-cce1-4033-93ce-002d5875f58a");
      line("Writing CLIENT_HELLO: " + toHex(WhoopProtocol.CLIENT_HELLO));
      await cmdChar.writeValueWithResponse(new Uint8Array(WhoopProtocol.CLIENT_HELLO));
      line("CLIENT_HELLO written. Waiting for notifications (leave this open)...");
    }catch(e){
      line("HANDSHAKE TEST FAILED: " + (e && e.name ? e.name + ": " : "") + (e && e.message ? e.message : e));
      console.error(e);
    }
  }
```

- [ ] **Step 4: Wire the button**

Find:

```js
    $("probeBtn").addEventListener("click", probeProprietaryChannel);
```

Add immediately after it:

```js
    $("helloBtn").addEventListener("click", testClientHelloHandshake);
```

- [ ] **Step 5: Verify no console/page errors and correct wiring with a headless browser**

Run this Node script (adjust the path to your scratchpad if different) to load `index.html` from disk and confirm it initializes cleanly with the new script include and button present:

```bash
cd "/Users/sridharchikkala/Downloads/pulse whoop"
node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  let hadError = false;
  page.on('pageerror', err => { hadError = true; console.log('PAGEERROR', err.message); });
  await page.goto('file://' + process.cwd() + '/index.html', { waitUntil: 'networkidle' });
  await page.waitForTimeout(500);
  await page.click('.tab-btn[data-screen=\"settings\"]');
  await page.waitForTimeout(200);
  const hasHelloBtn = await page.evaluate(() => !!document.getElementById('helloBtn'));
  const hasProtocol = await page.evaluate(() => typeof window.WhoopProtocol === 'object' && typeof window.WhoopProtocol.decodeWhoop5Frame === 'function');
  console.log('helloBtn exists:', hasHelloBtn);
  console.log('WhoopProtocol loaded:', hasProtocol);
  console.log('had page errors:', hadError);
  await browser.close();
})();
"
```

Expected output: `helloBtn exists: true`, `WhoopProtocol loaded: true`, `had page errors: false`. If Playwright isn't installed in this environment, run `npm install playwright && npx playwright install chromium` first (in a scratch directory, not this repo — it's a dev-only verification tool, not a project dependency).

- [ ] **Step 6: Commit**

```bash
cd "/Users/sridharchikkala/Downloads/pulse whoop"
git add index.html
git commit -m "Wire WHOOP 5.0 CLIENT_HELLO handshake test into Connect debug UI"
git push
```

- [ ] **Step 7: Manual on-device test (cannot be automated)**

Wait for GitHub Pages to rebuild (`gh api repos/sridharchikkala91/pulse/pages/builds/latest --jq '.status'` until it says `built`), then:

1. Open WebBLE on the iPhone, reload https://sridharchikkala91.github.io/pulse/
2. Connect tab → Debug — CLIENT_HELLO handshake → tap **Test CLIENT_HELLO handshake**
3. Pick the strap in the device picker
4. Watch the log for a `CLIENT_HELLO written` line, then wait ~10-15 seconds for any `NOTIFY ...` lines to appear
5. Report back the exact log contents (screenshot is fine) — this is the real go/no-go signal for whether the strap accepts the hello and starts sending data, and it's not something that can be verified without the physical strap.

---

## Self-Review

**Spec coverage:**
- Checksum functions (CRC8, CRC32, CRC16-Modbus) — Task 1. ✓
- Generic envelope decoder with CRC verification, no throwing on malformed input — Task 2 (`decodeWhoop5Frame` returns `null` rather than throwing on a too-short buffer; malformed-but-long-enough buffers just report `crc16Valid`/`crc32Valid: false` instead of throwing). ✓
- Debug action that connects, subscribes to all 4 notify channels, writes the static hello, logs raw hex + decoded fields — Task 3. ✓
- Explicitly does not build any outgoing command frame other than the static hello — Task 3's `testClientHelloHandshake` only ever writes `WhoopProtocol.CLIENT_HELLO`, never a constructed frame. ✓
- Historical data offload, vitals byte layout, UI wiring beyond debug — explicitly out of scope per spec, no task implements them. ✓
- Manual on-device verification — Task 3, Step 7. ✓

**Placeholder scan:** No TBD/TODO markers; every step has literal code or an exact command to run.

**Type consistency:** `decodeWhoop5Frame` is defined once (Task 2) and consumed with the same shape (`.type`, `.seq`, `.cmd`, `.payload`, `.crc16Valid`, `.crc32Valid`) in both its own tests and Task 3's notification handler. `CLIENT_HELLO` is a plain array in both its definition and every consumer (`Array.from`, `new Uint8Array(...)`, `.join(",")` all work on it as defined).
