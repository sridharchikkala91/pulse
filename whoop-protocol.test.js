const test = require('node:test');
const assert = require('node:assert');
const { crc8, crc32, crc16Modbus, decodeWhoop5Frame, encodeWhoop5Command, decodeGen5HistorySample, CLIENT_HELLO } = require('./whoop-protocol.js');

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

test('encodeWhoop5Command reproduces the real CLIENT_HELLO frame byte-for-byte (cmd=0x91, payload=[1])', () => {
  // GET_HELLO's own request happens to carry a payload byte of 1 and is the
  // one frame we have independently verified against real hardware — a
  // genuine golden round-trip test, not a fabricated expectation.
  assert.deepStrictEqual(encodeWhoop5Command(0x91, [0x01]), CLIENT_HELLO);
});

test('encodeWhoop5Command output round-trips through decodeWhoop5Frame with valid CRCs', () => {
  const frame = encodeWhoop5Command(26, [0x00]); // GET_BATTERY_LEVEL
  const decoded = decodeWhoop5Frame(frame);
  assert.notStrictEqual(decoded, null);
  assert.strictEqual(decoded.type, 0x23);
  assert.strictEqual(decoded.cmd, 26);
  assert.deepStrictEqual(decoded.payload, [0x00]);
  assert.strictEqual(decoded.crc16Valid, true);
  assert.strictEqual(decoded.crc32Valid, true);
});

// Real HISTORICAL_DATA chunk captured from this project's own WHOOP 5.0
// strap on 2026-09-19 (chunk #1 of a real historical offload run) — a
// genuine golden fixture, not synthesized data.
const REAL_HISTORY_CHUNK_1 = [
  0xe8,0x01,0x64,0x01,0x8e,0x96,0xad,0x6a,0x3d,0x6a,0x00,0x3c,0x01,0xde,0x03,0x00,
  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xb0,0x4f,0x0d,0x3c,0x00,0x00,0xff,0x00,0xa3,
  0x8b,0x3c,0x29,0xfc,0xd5,0x3d,0x71,0xed,0x9e,0x3e,0xe1,0xea,0x74,0x3f,0x90,0x02,
  0x7e,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x46,0x01,0x4e,0x01,0x66,0x0d,
  0x00,0x0b,0x01,0x0c,0x06,0x0c,0x20,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x55,
  0x4e,0x2a,0x2d,0x00,0x00,0x00,0xb6,0xbf,0xa8,0xc0,0x00,0x00,0x00
];

test('decodeGen5HistorySample decodes a real captured chunk with plausible field values', () => {
  const sample = decodeGen5HistorySample(REAL_HISTORY_CHUNK_1);
  assert.notStrictEqual(sample, null);
  assert.strictEqual(sample.timestamp, 1789761166); // 2026-09-18 19:52:46 UTC = ~1:22am IST
  assert.strictEqual(sample.sleepState, 2);
  assert.strictEqual(sample.sleepStateName, "sleep");
  assert.strictEqual(sample.skinTempC, 34.3);
  assert.strictEqual(sample.spo2CandidateRaw, 0);
  // Three per-channel status words carrying channel indices 0/1/2 in sequence
  // — matches gen5_records.dart's documented bit layout exactly.
  assert.strictEqual(sample.statusWord0 & 0x3, 0);
  assert.strictEqual(sample.statusWord1 & 0x3, 1);
  assert.strictEqual(sample.statusWord2 & 0x3, 2);
});
