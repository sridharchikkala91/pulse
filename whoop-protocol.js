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

  const api = { crc8, crc32, crc16Modbus, decodeWhoop5Frame, CLIENT_HELLO };
  if(typeof module !== "undefined" && module.exports){
    module.exports = api;
  } else {
    root.WhoopProtocol = api;
  }
})(typeof window !== "undefined" ? window : globalThis);
