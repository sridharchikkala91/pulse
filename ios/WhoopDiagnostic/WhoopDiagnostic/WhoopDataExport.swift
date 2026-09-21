import Foundation

/// Phase 41: data export. The user owns their data — export everything
/// stored locally as CSV or JSON, no cloud round-trip required.
enum WhoopDataExport {

    static func exportDailyMetricsCSV(_ records: [DailyMetricsRecord]) -> String {
        var lines = ["date,source,sleep_hours,skin_temp_c,resting_hr,hrv,strain,spo2_percent,respiratory_rate,avg_hr,max_hr,recovery_ours,recovery_whoop"]
        for r in records.sorted(by: { $0.dateKey < $1.dateKey }) {
            let fields: [String] = [
                r.dateKey, r.source,
                csvNum(r.sleepHours), csvNum(r.skinTempC), csvNum(r.restingHeartRate), csvNum(r.hrv),
                csvNum(r.strain), csvNum(r.spo2Percent), csvNum(r.respiratoryRate),
                csvNum(r.averageHeartRate), csvNum(r.maxHeartRate),
                csvNum(r.recoveryScoreOurs), csvNum(r.recoveryScoreWhoop)
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func exportSleepSessionsCSV(_ records: [SleepSessionRecord]) -> String {
        var lines = ["date,source,start_timestamp,end_timestamp,duration_hours,avg_skin_temp_c"]
        for r in records.sorted(by: { $0.dateKey < $1.dateKey }) {
            let fields: [String] = [
                r.dateKey, r.source, String(r.startTimestamp), String(r.endTimestamp),
                String(format: "%.3f", r.durationHours), csvNum(r.averageSkinTempC)
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    struct ExportBundle: Codable {
        struct DailyMetric: Codable {
            let date: String, source: String
            let sleepHours, skinTempC, restingHeartRate, hrv, strain, spo2Percent, respiratoryRate,
                averageHeartRate, maxHeartRate, recoveryScoreOurs, recoveryScoreWhoop: Double?
        }
        struct SleepSession: Codable {
            let date: String, source: String
            let startTimestamp, endTimestamp: Int
            let durationHours: Double
            let averageSkinTempC: Double?
        }
        let exportedAt: Date
        let dailyMetrics: [DailyMetric]
        let sleepSessions: [SleepSession]
    }

    static func exportJSON(dailyMetrics: [DailyMetricsRecord], sleepSessions: [SleepSessionRecord]) throws -> Data {
        let bundle = ExportBundle(
            exportedAt: Date(),
            dailyMetrics: dailyMetrics.map {
                .init(date: $0.dateKey, source: $0.source, sleepHours: $0.sleepHours, skinTempC: $0.skinTempC,
                      restingHeartRate: $0.restingHeartRate, hrv: $0.hrv, strain: $0.strain,
                      spo2Percent: $0.spo2Percent, respiratoryRate: $0.respiratoryRate,
                      averageHeartRate: $0.averageHeartRate, maxHeartRate: $0.maxHeartRate,
                      recoveryScoreOurs: $0.recoveryScoreOurs, recoveryScoreWhoop: $0.recoveryScoreWhoop)
            },
            sleepSessions: sleepSessions.map {
                .init(date: $0.dateKey, source: $0.source, startTimestamp: $0.startTimestamp,
                      endTimestamp: $0.endTimestamp, durationHours: $0.durationHours,
                      averageSkinTempC: $0.averageSkinTempC)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    private static func csvNum(_ v: Double?) -> String {
        guard let v else { return "" }
        return String(v)
    }
}
