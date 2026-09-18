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
