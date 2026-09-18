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
