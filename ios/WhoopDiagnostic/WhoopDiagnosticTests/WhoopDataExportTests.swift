import XCTest
@testable import WhoopDiagnostic

final class WhoopDataExportTests: XCTestCase {

    func testExportDailyMetricsCSVIncludesHeaderAndRow() {
        let record = DailyMetricsRecord(dateKey: "2026-01-15")
        record.hrv = 65
        record.restingHeartRate = 58
        record.source = "WHOOP_EXPORT"
        record.recoveryScoreWhoop = 72

        let csv = WhoopDataExport.exportDailyMetricsCSV([record])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("date,source,"))
        XCTAssertTrue(lines[1].contains("2026-01-15,WHOOP_EXPORT"))
        XCTAssertTrue(lines[1].contains("65"))
        XCTAssertTrue(lines[1].contains("72"))
    }

    func testExportDailyMetricsCSVLeavesNilFieldsBlank() {
        let record = DailyMetricsRecord(dateKey: "2026-01-16")
        let csv = WhoopDataExport.exportDailyMetricsCSV([record])
        let dataLine = csv.split(separator: "\n")[1]
        // date,source,then 10 empty numeric fields -> 12 commas total, all trailing fields empty
        XCTAssertEqual(dataLine, "2026-01-16,OUR_ALGORITHM,,,,,,,,,,,")
    }

    func testExportSleepSessionsCSV() {
        let record = SleepSessionRecord(dateKey: "2026-01-15", startTimestamp: 1000, endTimestamp: 5000,
                                         durationHours: 1.111, averageSkinTempC: 34.5, source: "synced")
        let csv = WhoopDataExport.exportSleepSessionsCSV([record])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("2026-01-15,synced,1000,5000,1.111,34.5"))
    }

    func testExportJSONRoundTripsCorrectValues() throws {
        let daily = DailyMetricsRecord(dateKey: "2026-01-15")
        daily.hrv = 65
        let sleep = SleepSessionRecord(dateKey: "2026-01-15", startTimestamp: 1000, endTimestamp: 5000,
                                        durationHours: 1.5, averageSkinTempC: 34.0, source: "synced")

        let data = try WhoopDataExport.exportJSON(dailyMetrics: [daily], sleepSessions: [sleep])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WhoopDataExport.ExportBundle.self, from: data)

        XCTAssertEqual(decoded.dailyMetrics.count, 1)
        XCTAssertEqual(decoded.dailyMetrics[0].hrv, 65)
        XCTAssertEqual(decoded.sleepSessions.count, 1)
        XCTAssertEqual(decoded.sleepSessions[0].durationHours, 1.5)
    }
}
