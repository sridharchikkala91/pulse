import XCTest
@testable import WhoopDiagnostic

final class WhoopProtocolTests: XCTestCase {

    private let ascii123456789: [UInt8] = [0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39]

    func testCRC8MatchesStandardCheckValue() {
        XCTAssertEqual(WhoopProtocol.crc8(ascii123456789), 0xF4)
    }

    func testCRC32MatchesStandardCheckValue() {
        XCTAssertEqual(WhoopProtocol.crc32(ascii123456789), 0xCBF43926)
    }

    func testCRC16ModbusMatchesStandardCheckValue() {
        XCTAssertEqual(WhoopProtocol.crc16Modbus(ascii123456789), 0x4B37)
    }

    func testClientHelloIsTheDocumentedStaticFrame() {
        XCTAssertEqual(WhoopProtocol.clientHello, [
            0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
            0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D
        ])
    }

    func testDecodeFrameParsesClientHelloWithBothCRCsValid() throws {
        let decoded = try XCTUnwrap(WhoopProtocol.decodeFrame(WhoopProtocol.clientHello))
        XCTAssertEqual(decoded.format, 0x01)
        XCTAssertEqual(decoded.declLength, 8)
        XCTAssertEqual(decoded.headerBytes, [0x00, 0x01])
        XCTAssertEqual(decoded.type, 0x23)
        XCTAssertEqual(decoded.seq, 0x01)
        XCTAssertEqual(decoded.cmd, 0x91)
        XCTAssertEqual(decoded.payload, [0x01])
        XCTAssertTrue(decoded.crc16Valid)
        XCTAssertTrue(decoded.crc32Valid)
    }

    func testDecodeFrameReturnsNilForTooShortBuffer() {
        XCTAssertNil(WhoopProtocol.decodeFrame([0xAA, 0x01, 0x00]))
    }

    func testEncodeCommandReproducesRealClientHelloByteForByte() {
        // GET_HELLO's own request happens to carry a payload byte of 1 and
        // is the one frame independently verified against real hardware —
        // a genuine golden round-trip test, not a fabricated expectation.
        XCTAssertEqual(WhoopProtocol.encodeCommand(0x91, [0x01]), WhoopProtocol.clientHello)
    }

    func testEncodeCommandRoundTripsThroughDecodeFrame() throws {
        let frame = WhoopProtocol.encodeCommand(26, [0x00]) // GET_BATTERY_LEVEL
        let decoded = try XCTUnwrap(WhoopProtocol.decodeFrame(frame))
        XCTAssertEqual(decoded.type, 0x23)
        XCTAssertEqual(decoded.cmd, 26)
        XCTAssertEqual(decoded.payload, [0x00])
        XCTAssertTrue(decoded.crc16Valid)
        XCTAssertTrue(decoded.crc32Valid)
    }

    /// Real HISTORICAL_DATA chunk captured from this project's own WHOOP 5.0
    /// strap on 2026-09-19 — a genuine golden fixture, not synthesized data.
    /// Generated programmatically from the original captured hex string
    /// (not hand-transcribed) to avoid the transcription bug caught in the
    /// JS test suite for this same fixture.
    private static let realHistoryChunk1: [UInt8] = [
        0xe8, 0x01, 0x64, 0x01, 0x8e, 0x96, 0xad, 0x6a, 0x3d, 0x6a, 0x00, 0x3c, 0x01, 0xde, 0x03, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb0, 0x4f, 0x0d, 0x3c, 0x00, 0x00, 0xff, 0x00, 0xa3,
        0x8b, 0x3c, 0x29, 0xfc, 0xd5, 0x3d, 0x71, 0xed, 0x9e, 0x3e, 0xe1, 0xea, 0x74, 0x3f, 0x90, 0x02,
        0x7e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46, 0x01, 0x4e, 0x01, 0x66, 0x0d,
        0x00, 0x0b, 0x01, 0x0c, 0x06, 0x0c, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x55,
        0x4e, 0x2a, 0x2d, 0x00, 0x00, 0x00, 0xb6, 0xbf, 0xa8, 0xc0, 0x00, 0x00, 0x00
    ]

    // MARK: - Sleep session extraction

    private func sample(_ ts: UInt32, sleepState: UInt8, skinTemp: Double? = 34.0) -> WhoopProtocol.HistorySample {
        WhoopProtocol.HistorySample(
            timestamp: ts, tempAux1C: 32, tempAux2C: 33, skinTempC: skinTemp,
            statusWord0: 0, statusWord1: 1, statusWord2: 2, sleepState: sleepState, spo2CandidateRaw: 0
        )
    }

    func testExtractSleepSessionsMergesShortGapsAndDropsShortRuns() {
        var samples: [WhoopProtocol.HistorySample] = []
        // A 40-minute sleep run (2400s), one real session.
        for t in stride(from: UInt32(0), through: 2400, by: 60) {
            samples.append(sample(t, sleepState: 2))
        }
        // A 2-minute gap (under the 5-minute merge threshold) then more sleep — should merge into the same session.
        for t in stride(from: UInt32(2520), through: 3600, by: 60) {
            samples.append(sample(t, sleepState: 2))
        }
        // A brief 10-minute "sleep" blip, isolated by long gaps on both sides — too short to count on its own.
        for t in stride(from: UInt32(10000), through: 10600, by: 60) {
            samples.append(sample(t, sleepState: 2))
        }

        let sessions = WhoopProtocol.extractSleepSessions(samples)
        XCTAssertEqual(sessions.count, 1, "the merged run should be one session; the 10-minute blip should be dropped")
        XCTAssertEqual(sessions[0].startTimestamp, 0)
        XCTAssertEqual(sessions[0].endTimestamp, 3600)
    }

    func testExtractSleepSessionsIgnoresNonSleepStates() {
        let samples = (0...100).map { i in sample(UInt32(i * 60), sleepState: i % 2 == 0 ? 2 : 0) }
        // Alternating sleep/wake every minute never sustains 30 minutes of
        // contiguous "sleep" state, but IS within the 5-minute merge gap
        // each time, so it should still merge into one long session overall.
        let sessions = WhoopProtocol.extractSleepSessions(samples)
        XCTAssertEqual(sessions.count, 1)
    }

    func testExtractSleepSessionsReturnsEmptyForNoQualifyingData() {
        let samples = [sample(0, sleepState: 2), sample(60, sleepState: 2)] // only 60s, under the 30-min minimum
        XCTAssertTrue(WhoopProtocol.extractSleepSessions(samples).isEmpty)
    }

    func testDecodeHistorySampleOnRealCapturedChunk() throws {
        let sample = try XCTUnwrap(WhoopProtocol.decodeHistorySample(Self.realHistoryChunk1))
        XCTAssertEqual(sample.timestamp, 1_789_761_166) // 2026-09-18 19:52:46 UTC = ~1:22am IST
        XCTAssertEqual(sample.sleepState, 2)
        XCTAssertEqual(sample.sleepStateName, "sleep")
        let skinTemp = try XCTUnwrap(sample.skinTempC)
        XCTAssertEqual(skinTemp, 34.3, accuracy: 0.001)
        XCTAssertEqual(sample.spo2CandidateRaw, 0)
        // Three per-channel status words carrying channel indices 0/1/2 in
        // sequence — matches gen5_records.dart's documented bit layout.
        XCTAssertEqual(sample.statusWord0 & 0x3, 0)
        XCTAssertEqual(sample.statusWord1 & 0x3, 1)
        XCTAssertEqual(sample.statusWord2 & 0x3, 2)
    }
}
