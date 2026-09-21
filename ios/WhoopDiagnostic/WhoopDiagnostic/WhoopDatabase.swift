import Foundation
import SwiftData

/// Phase 5 local database — SwiftData models. Kept deliberately normalized
/// per the project's own stated principle (section 15 of the master
/// prompt): the database is NOT coupled to WHOOP's raw packet structure.
/// Raw decode failures are preserved (never thrown away) so future
/// protocol research doesn't need a fresh capture.

@Model
final class SleepSessionRecord {
    /// Date key, matching the web app's convention: the "sleep day" the
    /// user woke up on (attributed to wake time, not bedtime).
    var dateKey: String
    var startTimestamp: Int
    var endTimestamp: Int
    var durationHours: Double
    var averageSkinTempC: Double?
    /// "synced" (from this offload), "manual", or "whoop_export" — see
    /// docs/WHOOP5_LIMITATIONS.md and the web app's identical convention;
    /// never overwrite a WHOOP_EXPORT record's own historical values.
    var source: String
    var createdAt: Date

    init(dateKey: String, startTimestamp: Int, endTimestamp: Int, durationHours: Double,
         averageSkinTempC: Double?, source: String) {
        self.dateKey = dateKey
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.durationHours = durationHours
        self.averageSkinTempC = averageSkinTempC
        self.source = source
        self.createdAt = Date()
    }
}

@Model
final class DailyMetricsRecord {
    @Attribute(.unique) var dateKey: String
    var sleepHours: Double?
    var skinTempC: Double?
    var restingHeartRate: Double?
    var hrv: Double?
    var strain: Double?
    var spo2Percent: Double?
    var respiratoryRate: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    /// Our own algorithmic estimate — NEVER WHOOP's real score. See
    /// section 25/16 of the master prompt: WHOOP_EXPORT-sourced recovery
    /// must never be overwritten by our algorithm.
    var recoveryScoreOurs: Double?
    /// WHOOP's own real recovery %, ONLY ever populated from a CSV export
    /// import — never computed by this app. Kept as a separate field from
    /// recoveryScoreOurs specifically so the two can never collide.
    var recoveryScoreWhoop: Double?
    /// "OUR_ALGORITHM" | "WHOOP_EXPORT" | "synced" | "manual" — which
    /// source most recently wrote the bulk of this record's fields.
    var source: String

    init(dateKey: String) {
        self.dateKey = dateKey
        self.source = "OUR_ALGORITHM"
    }
}

/// If a packet can't currently be decoded, it is NEVER thrown away — see
/// section 10 of the master prompt. This is what lets future protocol
/// research work from already-captured data instead of needing a fresh
/// capture from the strap.
@Model
final class RawPacketRecord {
    var timestampReceived: Date
    var characteristicUUID: String
    var payloadHex: String
    var packetType: Int?
    /// "DECODED" | "PARTIAL" | "UNKNOWN" | "INVALID"
    var decodeStatus: String
    var errorReason: String?

    init(characteristicUUID: String, payloadHex: String, packetType: Int?,
         decodeStatus: String, errorReason: String? = nil) {
        self.timestampReceived = Date()
        self.characteristicUUID = characteristicUUID
        self.payloadHex = payloadHex
        self.packetType = packetType
        self.decodeStatus = decodeStatus
        self.errorReason = errorReason
    }
}

/// Phase 15: normalized data model, decoupled from any single source's
/// raw structure — section 15/39 of the master prompt: if WHOOP BLE says
/// HR=70 and HealthKit says HR=71 for the same moment, both are stored;
/// nothing is silently overwritten. The analytics engine picks a source
/// itself when it needs one value.
@Model
final class HealthSampleRecord {
    var timestamp: Date
    var metricType: String // e.g. "heart_rate", "hrv", "resting_heart_rate", "respiratory_rate", "body_temperature", "vo2_max"
    var value: Double
    var unit: String
    /// "WHOOP_BLE" | "WHOOP_EXPORT" | "HEALTHKIT" | "HEALTH_CONNECT" | "USER"
    var source: String
    /// "GOOD" | "LOW" | "UNKNOWN" | "INVALID"
    var quality: String

    init(timestamp: Date, metricType: String, value: Double, unit: String, source: String, quality: String = "GOOD") {
        self.timestamp = timestamp
        self.metricType = metricType
        self.value = value
        self.unit = unit
        self.source = source
        self.quality = quality
    }
}

@Model
final class SyncStateRecord {
    var lastConnected: Date?
    var lastSyncCompleted: Date?
    var lastSyncStatus: String // "SUCCESS" | "PARTIAL" | "FAILED" | "NEVER_RUN"
    var recordsStoredTotal: Int

    init() {
        self.lastSyncStatus = "NEVER_RUN"
        self.recordsStoredTotal = 0
    }
}
