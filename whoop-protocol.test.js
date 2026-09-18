const test = require('node:test');
const assert = require('node:assert');
const { crc8, crc32, crc16Modbus, decodeWhoop5Frame, CLIENT_HELLO } = require('./whoop-protocol.js');

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
