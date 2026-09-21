package com.pulsewhoop.whoopdiagnostic

/**
 * WHOOP 5.0/MG proprietary BLE protocol — ported from this project's
 * already hardware-verified implementations (whoop-protocol.js in the web
 * app, WhoopProtocol.swift in the iOS app), not re-derived. Every constant
 * and algorithm here has been checked against a real captured frame from
 * the project owner's own strap. See docs/WHOOP5_PACKET_TYPES.md in the
 * repo root for the full research writeup.
 */
object WhoopProtocol {

    // ---- Checksums ----

    /** CRC-8/SMBUS: poly 0x07, init 0x00, no reflection, no final XOR.
     *  Verified against the standard check value for ASCII "123456789": 0xF4. */
    fun crc8(bytes: List<Int>): Int {
        var crc = 0x00
        for (byte in bytes) {
            crc = crc xor (byte and 0xFF)
            repeat(8) {
                crc = if (crc and 0x80 != 0) ((crc shl 1) xor 0x07) and 0xFF else (crc shl 1) and 0xFF
            }
        }
        return crc
    }

    /** CRC-32/ISO-HDLC (zlib): poly 0xEDB88320 (reflected), init 0xFFFFFFFF,
     *  final XOR 0xFFFFFFFF. Verified against the standard check value for
     *  ASCII "123456789": 0xCBF43926. */
    fun crc32(bytes: List<Int>): Long {
        var crc = 0xFFFFFFFFL
        for (byte in bytes) {
            crc = crc xor (byte.toLong() and 0xFF)
            repeat(8) {
                crc = if (crc and 1L != 0L) (crc ushr 1) xor 0xEDB88320L else crc ushr 1
            }
        }
        return (crc xor 0xFFFFFFFFL) and 0xFFFFFFFFL
    }

    /** CRC-16/MODBUS: poly 0xA001 (reflected form of 0x8005), init 0xFFFF,
     *  no final XOR. Verified against the standard check value for ASCII
     *  "123456789": 0x4B37. */
    fun crc16Modbus(bytes: List<Int>): Int {
        var crc = 0xFFFF
        for (byte in bytes) {
            crc = crc xor (byte and 0xFF)
            repeat(8) {
                crc = if (crc and 1 != 0) (crc ushr 1) xor 0xA001 else crc ushr 1
            }
        }
        return crc and 0xFFFF
    }

    // ---- Static handshake ----

    /** The documented, hardware-verified 16-byte CLIENT_HELLO handshake
     *  frame (GET_HELLO = 0x91, payload [0x01]). */
    val CLIENT_HELLO: List<Int> = listOf(
        0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
        0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D
    )

    /** Direction marker at header bytes[4:6]. [0x00,0x01] on every
     *  host->strap COMMAND frame, [0x01,0x00] on every strap->host frame of
     *  any other packet type — confirmed against real captured response
     *  frames from the strap. */
    val OUTBOUND_DIRECTION_MARKER: List<Int> = listOf(0x00, 0x01)

    // ---- Envelope decode ----

    data class DecodedFrame(
        val startByte: Int, val format: Int, val declLength: Int, val headerBytes: List<Int>,
        val crc16Received: Int, val crc16Computed: Int,
        val type: Int, val seq: Int, val cmd: Int, val payload: List<Int>,
        val crc32Received: Long, val crc32Computed: Long
    ) {
        val crc16Valid: Boolean get() = crc16Received == crc16Computed
        val crc32Valid: Boolean get() = crc32Received == crc32Computed
    }

    /** WHOOP 5.0/MG envelope:
     *  [0xAA][format][declLength u16 LE][header 2 bytes][crc16 u16 LE][type][seq][cmd][payload...][crc32 u32 LE]
     *  declLength counts the bytes from `type` through the end of `crc32`, inclusive. */
    fun decodeFrame(bytes: List<Int>): DecodedFrame? {
        if (bytes.size < 8) return null
        val declLength = bytes[2] or (bytes[3] shl 8)
        val innerStart = 8
        val innerEnd = innerStart + declLength
        if (bytes.size < innerEnd || declLength < 7) return null

        val headerBytes = listOf(bytes[4], bytes[5])
        val crc16Received = bytes[6] or (bytes[7] shl 8)
        val crc16Computed = crc16Modbus(bytes.subList(0, 6))

        val type = bytes[innerStart]
        val seq = bytes[innerStart + 1]
        val cmd = bytes[innerStart + 2]
        val payload = bytes.subList(innerStart + 3, innerEnd - 4)
        val crc32Bytes = bytes.subList(innerEnd - 4, innerEnd)
        val crc32Received = (crc32Bytes[0].toLong() or (crc32Bytes[1].toLong() shl 8) or
            (crc32Bytes[2].toLong() shl 16) or (crc32Bytes[3].toLong() shl 24)) and 0xFFFFFFFFL
        val crc32Computed = crc32(bytes.subList(innerStart, innerEnd - 4))

        return DecodedFrame(
            bytes[0], bytes[1], declLength, headerBytes,
            crc16Received, crc16Computed, type, seq, cmd, payload,
            crc32Received, crc32Computed
        )
    }

    // ---- Envelope encode ----

    /** Builds an outgoing WHOOP 5.0/MG COMMAND frame (type=0x23) for the
     *  given cmd/payload. Verified: encodeCommand(0x91, [0x01]) reproduces
     *  CLIENT_HELLO byte-for-byte (see WhoopProtocolTest). */
    fun encodeCommand(cmd: Int, payload: List<Int>): List<Int> {
        val inner = listOf(0x23, 0x01, cmd) + payload // type=COMMAND(0x23), seq=1
        val c32 = crc32(inner)
        val crc32Bytes = listOf(
            (c32 and 0xFF).toInt(), ((c32 shr 8) and 0xFF).toInt(),
            ((c32 shr 16) and 0xFF).toInt(), ((c32 shr 24) and 0xFF).toInt()
        )
        val declLength = inner.size + 4
        val header = listOf(0xAA, 0x01, declLength and 0xFF, (declLength shr 8) and 0xFF) + OUTBOUND_DIRECTION_MARKER
        val c16 = crc16Modbus(header)
        val crc16Bytes = listOf(c16 and 0xFF, (c16 shr 8) and 0xFF)
        return header + crc16Bytes + inner + crc32Bytes
    }

    // ---- Historical sample (Gen5HistorySample) ----

    data class HistorySample(
        val timestamp: Long,
        val tempAux1C: Double,
        val tempAux2C: Double,
        val skinTempC: Double?,
        val statusWord0: Int,
        val statusWord1: Int,
        val statusWord2: Int,
        val sleepState: Int,
        val spo2CandidateRaw: Int
    ) {
        val sleepStateName: String get() = when (sleepState) {
            0 -> "wake"; 1 -> "still"; 2 -> "sleep"; 3 -> "up"; else -> "unknown"
        }
    }

    private fun i16(b: List<Int>, at: Int): Int {
        val v = b[at] or (b[at + 1] shl 8)
        return if (v >= 0x8000) v - 0x10000 else v
    }
    private fun u16(b: List<Int>, at: Int): Int = b[at] or (b[at + 1] shl 8)
    private fun u32(b: List<Int>, at: Int): Long =
        (b[at].toLong() or (b[at + 1].toLong() shl 8) or (b[at + 2].toLong() shl 16) or (b[at + 3].toLong() shl 24)) and 0xFFFFFFFFL

    /** Decodes a Gen5HistorySample from HISTORICAL_DATA (type 47) payload
     *  bytes (the array already has the 3-byte [type,seq,cmd] prefix
     *  stripped). See docs/WHOOP5_DATA_DICTIONARY.md for field provenance
     *  and confidence levels — direct port of the already-verified JS/Swift
     *  decoders. */
    fun decodeHistorySample(payload: List<Int>): HistorySample? {
        if (payload.size < 72) return null
        val timestamp = u32(payload, 4)
        val tempAux1C = i16(payload, 58) / 10.0
        val tempAux2C = i16(payload, 60) / 10.0
        val skinTempRaw = i16(payload, 62)
        val skinTempAvailable = skinTempRaw != -5000
        val statusWord0 = u16(payload, 64)
        val statusWord1 = u16(payload, 66)
        val statusWord2 = u16(payload, 68)
        val sleepStateByte = payload[70]
        val sleepState = (sleepStateByte shr 4) and 0x3
        val spo2CandidateRaw = payload[71]
        return HistorySample(
            timestamp, tempAux1C, tempAux2C,
            if (skinTempAvailable) skinTempRaw / 100.0 else null,
            statusWord0, statusWord1, statusWord2, sleepState, spo2CandidateRaw
        )
    }

    // ---- Sleep session extraction (ported from the web/iOS proven algorithm) ----

    data class SleepSession(
        var startTimestamp: Long,
        var endTimestamp: Long,
        val skinTemps: MutableList<Double> = mutableListOf()
    )

    /** Merges contiguous sleepState=="sleep" samples into sessions, bridging
     *  gaps up to 5 minutes (brief dropped samples/BLE hiccups), and drops
     *  anything under 30 minutes (noise, not a real sleep period). */
    fun extractSleepSessions(samples: List<HistorySample>): List<SleepSession> {
        val sorted = samples.sortedBy { it.timestamp }
        val gapMergeSeconds = 300L
        val sessions = mutableListOf<SleepSession>()
        var current: SleepSession? = null

        for (s in sorted) {
            if (s.sleepState == 2) {
                val cur = current
                if (cur != null && s.timestamp - cur.endTimestamp <= gapMergeSeconds) {
                    cur.endTimestamp = s.timestamp
                    s.skinTempC?.let { cur.skinTemps.add(it) }
                } else {
                    cur?.let { sessions.add(it) }
                    current = SleepSession(s.timestamp, s.timestamp).also { session ->
                        s.skinTempC?.let { session.skinTemps.add(it) }
                    }
                }
            } else {
                val cur = current
                if (cur != null && s.timestamp - cur.endTimestamp > gapMergeSeconds) {
                    sessions.add(cur)
                    current = null
                }
            }
        }
        current?.let { sessions.add(it) }
        return sessions.filter { it.endTimestamp - it.startTimestamp >= 1800 }
    }
}
