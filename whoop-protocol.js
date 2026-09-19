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

  // Direction marker at header bytes[4:6]. Source: OpenStrap/protocol's band.dart
  // (byte-verified against real gen5 fixtures) — [0x00,0x01] on every host->strap
  // COMMAND frame, [0x01,0x00] on every strap->host frame of any other packet type.
  // Confirmed independently against our own captured GET_HELLO response frames,
  // which carry [0x01,0x00] exactly as documented.
  const OUTBOUND_DIRECTION_MARKER = [0x00, 0x01];

  // Builds an outgoing WHOOP 5.0/MG COMMAND frame (type=0x23) for the given cmd/payload.
  function encodeWhoop5Command(cmd, payload){
    const pay = payload || [];
    const inner = [0x23, 0x01, cmd, ...pay]; // type=COMMAND(0x23), seq=1 (only sequence value seen in captures so far)
    const crc32Bytes = [];
    const c32 = crc32(inner);
    crc32Bytes.push(c32 & 0xFF, (c32>>>8)&0xFF, (c32>>>16)&0xFF, (c32>>>24)&0xFF);
    const declLength = inner.length + 4;
    const header = [0xAA, 0x01, declLength & 0xFF, (declLength>>>8)&0xFF, ...OUTBOUND_DIRECTION_MARKER];
    const c16 = crc16Modbus(header);
    return [...header, c16 & 0xFF, (c16>>>8)&0xFF, ...inner, ...crc32Bytes];
  }

  function i16(b, at){ const v = b[at] | (b[at+1]<<8); return v >= 0x8000 ? v - 0x10000 : v; }
  function u16(b, at){ return b[at] | (b[at+1]<<8); }
  function u32(b, at){ return (b[at] | (b[at+1]<<8) | (b[at+2]<<16) | (b[at+3]<<24)) >>> 0; }

  const SLEEP_STATE_NAMES = ["wake", "still", "sleep", "up"];

  // Decodes a Gen5HistorySample from HISTORICAL_DATA (type 47) payload bytes
  // (the array already has the 3-byte [type,seq,cmd] prefix stripped, so
  // payload[N] here = gen5_records.dart's documented `inner[N+3]`).
  //
  // Field offsets and scales sourced from OpenStrap/protocol's
  // gen5_records.dart (read directly, not summarized) and verified against
  // real captured data from this strap on 2026-09-19: the decoded timestamp
  // landed at ~1:22am local time with sleepState="sleep" and a plausible
  // 34.3C skin temperature, and the three per-channel status words showed
  // channel indices 0/1/2 in sequence exactly as documented.
  //
  // SpO2 is deliberately left as a raw byte, not a percentage — the source
  // project explicitly states the encoding isn't pinned down and refuses to
  // publish it as a real SpO2 value. Do the same here.
  function decodeGen5HistorySample(payload){
    if(payload.length < 72) return null;
    const timestamp = u32(payload, 4);
    const tempAux1C = i16(payload, 58) / 10;
    const tempAux2C = i16(payload, 60) / 10;
    const skinTempRaw = i16(payload, 62);
    const skinTempAvailable = skinTempRaw !== -5000;
    const statusWord0 = u16(payload, 64);
    const statusWord1 = u16(payload, 66);
    const statusWord2 = u16(payload, 68);
    const sleepStateByte = payload[70];
    const sleepState = (sleepStateByte >> 4) & 0x3;
    const spo2CandidateRaw = payload[71];
    return {
      timestamp,
      tempAux1C, tempAux2C,
      skinTempC: skinTempAvailable ? skinTempRaw / 100 : null,
      statusWord0, statusWord1, statusWord2,
      sleepState, sleepStateName: SLEEP_STATE_NAMES[sleepState] || "unknown",
      spo2CandidateRaw
    };
  }

  const api = {
    crc8, crc32, crc16Modbus, decodeWhoop5Frame, encodeWhoop5Command,
    decodeGen5HistorySample, CLIENT_HELLO, OUTBOUND_DIRECTION_MARKER
  };
  if(typeof module !== "undefined" && module.exports){
    module.exports = api;
  } else {
    root.WhoopProtocol = api;
  }
})(typeof window !== "undefined" ? window : globalThis);
