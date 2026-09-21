package com.pulsewhoop.whoopdiagnostic

import org.junit.Assert.*
import org.junit.Test

class WhoopProtocolTest {

    private val ascii123456789 = listOf(0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39)

    @Test fun `crc8 matches standard check value`() {
        assertEquals(0xF4, WhoopProtocol.crc8(ascii123456789))
    }

    @Test fun `crc32 matches standard check value`() {
        assertEquals(0xCBF43926L, WhoopProtocol.crc32(ascii123456789))
    }

    @Test fun `crc16Modbus matches standard check value`() {
        assertEquals(0x4B37, WhoopProtocol.crc16Modbus(ascii123456789))
    }

    @Test fun `CLIENT_HELLO is the documented static frame`() {
        assertEquals(
            listOf(0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71, 0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D),
            WhoopProtocol.CLIENT_HELLO
        )
    }

    @Test fun `decodeFrame parses CLIENT_HELLO with both CRCs valid`() {
        val decoded = WhoopProtocol.decodeFrame(WhoopProtocol.CLIENT_HELLO)
        assertNotNull(decoded)
        decoded!!
        assertEquals(0x01, decoded.format)
        assertEquals(8, decoded.declLength)
        assertEquals(listOf(0x00, 0x01), decoded.headerBytes)
        assertEquals(0x23, decoded.type)
        assertEquals(0x01, decoded.seq)
        assertEquals(0x91, decoded.cmd)
        assertEquals(listOf(0x01), decoded.payload)
        assertTrue(decoded.crc16Valid)
        assertTrue(decoded.crc32Valid)
    }

    @Test fun `decodeFrame returns null for too-short buffer`() {
        assertNull(WhoopProtocol.decodeFrame(listOf(0xAA, 0x01, 0x00)))
    }

    @Test fun `encodeCommand reproduces real CLIENT_HELLO byte-for-byte`() {
        // GET_HELLO's own request happens to carry a payload byte of 1 and
        // is the one frame independently verified against real hardware —
        // a genuine golden round-trip test, not a fabricated expectation.
        assertEquals(WhoopProtocol.CLIENT_HELLO, WhoopProtocol.encodeCommand(0x91, listOf(0x01)))
    }

    @Test fun `encodeCommand round-trips through decodeFrame`() {
        val frame = WhoopProtocol.encodeCommand(26, listOf(0x00)) // GET_BATTERY_LEVEL
        val decoded = WhoopProtocol.decodeFrame(frame)
        assertNotNull(decoded)
        decoded!!
        assertEquals(0x23, decoded.type)
        assertEquals(26, decoded.cmd)
        assertEquals(listOf(0x00), decoded.payload)
        assertTrue(decoded.crc16Valid)
        assertTrue(decoded.crc32Valid)
    }

    /** Real HISTORICAL_DATA chunk captured from this project's own WHOOP 5.0
     *  strap on 2026-09-19 — a genuine golden fixture, not synthesized data. */
    private val realHistoryChunk1 = listOf(
        0xe8, 0x01, 0x64, 0x01, 0x8e, 0x96, 0xad, 0x6a, 0x3d, 0x6a, 0x00, 0x3c, 0x01, 0xde, 0x03, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb0, 0x4f, 0x0d, 0x3c, 0x00, 0x00, 0xff, 0x00, 0xa3,
        0x8b, 0x3c, 0x29, 0xfc, 0xd5, 0x3d, 0x71, 0xed, 0x9e, 0x3e, 0xe1, 0xea, 0x74, 0x3f, 0x90, 0x02,
        0x7e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46, 0x01, 0x4e, 0x01, 0x66, 0x0d,
        0x00, 0x0b, 0x01, 0x0c, 0x06, 0x0c, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x55,
        0x4e, 0x2a, 0x2d, 0x00, 0x00, 0x00, 0xb6, 0xbf, 0xa8, 0xc0, 0x00, 0x00, 0x00
    )

    @Test fun `decodeHistorySample decodes a real captured chunk with plausible field values`() {
        val sample = WhoopProtocol.decodeHistorySample(realHistoryChunk1)
        assertNotNull(sample)
        sample!!
        assertEquals(1_789_761_166L, sample.timestamp) // 2026-09-18 19:52:46 UTC = ~1:22am IST
        assertEquals(2, sample.sleepState)
        assertEquals("sleep", sample.sleepStateName)
        assertEquals(34.3, sample.skinTempC!!, 0.001)
        assertEquals(0, sample.spo2CandidateRaw)
        // Three per-channel status words carrying channel indices 0/1/2 in
        // sequence — matches gen5_records.dart's documented bit layout.
        assertEquals(0, sample.statusWord0 and 0x3)
        assertEquals(1, sample.statusWord1 and 0x3)
        assertEquals(2, sample.statusWord2 and 0x3)
    }

    private fun sample(ts: Long, sleepState: Int, skinTemp: Double? = 34.0) = WhoopProtocol.HistorySample(
        timestamp = ts, tempAux1C = 32.0, tempAux2C = 33.0, skinTempC = skinTemp,
        statusWord0 = 0, statusWord1 = 1, statusWord2 = 2, sleepState = sleepState, spo2CandidateRaw = 0
    )

    @Test fun `extractSleepSessions merges short gaps and drops short runs`() {
        val samples = mutableListOf<WhoopProtocol.HistorySample>()
        var t = 0L
        while (t <= 2400) { samples.add(sample(t, 2)); t += 60 }
        t = 2520
        while (t <= 3600) { samples.add(sample(t, 2)); t += 60 }
        t = 10000
        while (t <= 10600) { samples.add(sample(t, 2)); t += 60 }

        val sessions = WhoopProtocol.extractSleepSessions(samples)
        assertEquals(1, sessions.size)
        assertEquals(0L, sessions[0].startTimestamp)
        assertEquals(3600L, sessions[0].endTimestamp)
    }

    @Test fun `extractSleepSessions returns empty for no qualifying data`() {
        val samples = listOf(sample(0, 2), sample(60, 2)) // only 60s, under the 30-min minimum
        assertTrue(WhoopProtocol.extractSleepSessions(samples).isEmpty())
    }
}
