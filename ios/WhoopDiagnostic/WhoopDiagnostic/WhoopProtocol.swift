import Foundation

/// WHOOP 5.0/MG proprietary BLE protocol — ported from this project's
/// already hardware-verified JavaScript implementation (`whoop-protocol.js`
/// in the repo root), not re-derived. Every constant and algorithm here has
/// been checked against a real captured frame from the project owner's own
/// strap. See docs/WHOOP5_PACKET_TYPES.md for the full research writeup.
enum WhoopProtocol {

    // MARK: - Checksums

    /// CRC-8/SMBUS: poly 0x07, init 0x00, no reflection, no final XOR.
    /// Verified against the standard check value for ASCII "123456789": 0xF4.
    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0x00
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }

    /// CRC-32/ISO-HDLC (zlib): poly 0xEDB88320 (reflected), init 0xFFFFFFFF,
    /// final XOR 0xFFFFFFFF. Verified against the standard check value for
    /// ASCII "123456789": 0xCBF43926.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// CRC-16/MODBUS: poly 0xA001 (reflected form of 0x8005), init 0xFFFF,
    /// no final XOR. Verified against the standard check value for ASCII
    /// "123456789": 0x4B37.
    static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    // MARK: - Static handshake

    /// The documented, hardware-verified 16-byte CLIENT_HELLO handshake
    /// frame (GET_HELLO = 0x91, payload [0x01]).
    static let clientHello: [UInt8] = [
        0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
        0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D
    ]

    /// Direction marker at header bytes[4:6]. `[0x00,0x01]` on every
    /// host->strap COMMAND frame, `[0x01,0x00]` on every strap->host frame
    /// of any other packet type — confirmed against real captured response
    /// frames from the strap (see docs/WHOOP5_PACKET_TYPES.md).
    static let outboundDirectionMarker: [UInt8] = [0x00, 0x01]

    // MARK: - Envelope decode

    struct DecodedFrame {
        let startByte: UInt8
        let format: UInt8
        let declLength: UInt16
        let headerBytes: [UInt8]
        let crc16Received: UInt16
        let crc16Computed: UInt16
        let type: UInt8
        let seq: UInt8
        let cmd: UInt8
        let payload: [UInt8]
        let crc32Received: UInt32
        let crc32Computed: UInt32

        var crc16Valid: Bool { crc16Received == crc16Computed }
        var crc32Valid: Bool { crc32Received == crc32Computed }
    }

    /// WHOOP 5.0/MG envelope:
    /// [0xAA][format][declLength u16 LE][header 2 bytes][crc16 u16 LE][type][seq][cmd][payload...][crc32 u32 LE]
    /// declLength counts the bytes from `type` through the end of `crc32`, inclusive.
    static func decodeFrame(_ bytes: [UInt8]) -> DecodedFrame? {
        guard bytes.count >= 8 else { return nil }
        let declLength = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        let innerStart = 8
        let innerEnd = innerStart + Int(declLength)
        guard bytes.count >= innerEnd, declLength >= 7 else { return nil }

        let headerBytes = [bytes[4], bytes[5]]
        let crc16Received = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        let crc16Computed = crc16Modbus(Array(bytes[0..<6]))

        let type = bytes[innerStart]
        let seq = bytes[innerStart + 1]
        let cmd = bytes[innerStart + 2]
        let payload = Array(bytes[(innerStart + 3)..<(innerEnd - 4)])
        let crc32Bytes = Array(bytes[(innerEnd - 4)..<innerEnd])
        let crc32Received = UInt32(crc32Bytes[0]) | (UInt32(crc32Bytes[1]) << 8)
            | (UInt32(crc32Bytes[2]) << 16) | (UInt32(crc32Bytes[3]) << 24)
        let crc32Computed = crc32(Array(bytes[innerStart..<(innerEnd - 4)]))

        return DecodedFrame(
            startByte: bytes[0], format: bytes[1], declLength: declLength, headerBytes: headerBytes,
            crc16Received: crc16Received, crc16Computed: crc16Computed,
            type: type, seq: seq, cmd: cmd, payload: payload,
            crc32Received: crc32Received, crc32Computed: crc32Computed
        )
    }

    // MARK: - Envelope encode

    /// Builds an outgoing WHOOP 5.0/MG COMMAND frame (type=0x23) for the
    /// given cmd/payload. Verified: encodeCommand(0x91, [0x01]) reproduces
    /// `clientHello` byte-for-byte (see WhoopProtocolTests).
    static func encodeCommand(_ cmd: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let inner: [UInt8] = [0x23, 0x01, cmd] + payload // type=COMMAND(0x23), seq=1
        let c32 = crc32(inner)
        let crc32Bytes: [UInt8] = [
            UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF),
            UInt8((c32 >> 16) & 0xFF), UInt8((c32 >> 24) & 0xFF)
        ]
        let declLength = UInt16(inner.count + 4)
        let header: [UInt8] = [0xAA, 0x01, UInt8(declLength & 0xFF), UInt8((declLength >> 8) & 0xFF)]
            + outboundDirectionMarker
        let c16 = crc16Modbus(header)
        let crc16Bytes: [UInt8] = [UInt8(c16 & 0xFF), UInt8((c16 >> 8) & 0xFF)]
        return header + crc16Bytes + inner + crc32Bytes
    }

    // MARK: - Historical sample (Gen5HistorySample)

    struct HistorySample {
        let timestamp: UInt32
        let tempAux1C: Double
        let tempAux2C: Double
        let skinTempC: Double?
        let statusWord0: UInt16
        let statusWord1: UInt16
        let statusWord2: UInt16
        let sleepState: UInt8
        let spo2CandidateRaw: UInt8

        var sleepStateName: String {
            switch sleepState {
            case 0: return "wake"
            case 1: return "still"
            case 2: return "sleep"
            case 3: return "up"
            default: return "unknown"
            }
        }
    }

    private static func i16(_ b: [UInt8], _ at: Int) -> Int16 {
        Int16(bitPattern: UInt16(b[at]) | (UInt16(b[at + 1]) << 8))
    }
    private static func u16(_ b: [UInt8], _ at: Int) -> UInt16 {
        UInt16(b[at]) | (UInt16(b[at + 1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | (UInt32(b[at + 1]) << 8) | (UInt32(b[at + 2]) << 16) | (UInt32(b[at + 3]) << 24)
    }

    // MARK: - Sleep session extraction (ported from the web app's proven algorithm)

    struct SleepSession {
        var startTimestamp: UInt32
        var endTimestamp: UInt32
        var skinTemps: [Double]
    }

    /// Merges contiguous sleepState=="sleep" samples into sessions, bridging
    /// gaps up to 5 minutes (brief dropped samples/BLE hiccups), and drops
    /// anything under 30 minutes (noise, not a real sleep period). Direct
    /// port of `extractSleepSessions` in the web app's index.html, already
    /// proven against real multi-thousand-record captures.
    static func extractSleepSessions(_ samples: [HistorySample]) -> [SleepSession] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let gapMergeSeconds: UInt32 = 300
        var sessions: [SleepSession] = []
        var current: SleepSession?

        for s in sorted {
            if s.sleepState == 2 {
                if var cur = current, s.timestamp - cur.endTimestamp <= gapMergeSeconds {
                    cur.endTimestamp = s.timestamp
                    if let t = s.skinTempC { cur.skinTemps.append(t) }
                    current = cur
                } else {
                    if let cur = current { sessions.append(cur) }
                    current = SleepSession(startTimestamp: s.timestamp, endTimestamp: s.timestamp,
                                            skinTemps: s.skinTempC.map { [$0] } ?? [])
                }
            } else if let cur = current, s.timestamp - cur.endTimestamp > gapMergeSeconds {
                sessions.append(cur)
                current = nil
            }
        }
        if let cur = current { sessions.append(cur) }
        return sessions.filter { $0.endTimestamp - $0.startTimestamp >= 1800 }
    }

    /// Decodes a Gen5HistorySample from HISTORICAL_DATA (type 47) payload
    /// bytes (the array already has the 3-byte [type,seq,cmd] prefix
    /// stripped). See docs/WHOOP5_DATA_DICTIONARY.md for field provenance
    /// and confidence levels — this is a direct port of the JS decoder
    /// already verified against real captured data from the strap.
    static func decodeHistorySample(_ payload: [UInt8]) -> HistorySample? {
        guard payload.count >= 72 else { return nil }
        let timestamp = u32(payload, 4)
        let tempAux1C = Double(i16(payload, 58)) / 10
        let tempAux2C = Double(i16(payload, 60)) / 10
        let skinTempRaw = i16(payload, 62)
        let skinTempAvailable = skinTempRaw != -5000
        let statusWord0 = u16(payload, 64)
        let statusWord1 = u16(payload, 66)
        let statusWord2 = u16(payload, 68)
        let sleepStateByte = payload[70]
        let sleepState = (sleepStateByte >> 4) & 0x3
        let spo2CandidateRaw = payload[71]
        return HistorySample(
            timestamp: timestamp,
            tempAux1C: tempAux1C, tempAux2C: tempAux2C,
            skinTempC: skinTempAvailable ? Double(skinTempRaw) / 100 : nil,
            statusWord0: statusWord0, statusWord1: statusWord1, statusWord2: statusWord2,
            sleepState: sleepState,
            spo2CandidateRaw: spo2CandidateRaw
        )
    }
}
