import XCTest
import SwiftData
@testable import WhoopDiagnostic

@MainActor
final class WhoopCSVImportTests: XCTestCase {

    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([SleepSessionRecord.self, DailyMetricsRecord.self, RawPacketRecord.self, SyncStateRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private let sampleCSV = """
    Cycle start time,Wake onset,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Day Strain,Asleep duration (min),Skin temp (celsius),Blood oxygen %,Respiratory rate (rpm),Average HR (bpm),Max HR (bpm)
    2026-01-14 22:00:00,2026-01-15 06:32:00,72,58,65,11.8,420,33.7,96.5,13.3,68,142
    """

    func testParseCSVProducesOneRowWithCorrectFields() {
        let rows = WhoopCSVImport.parseCSV(sampleCSV)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["Recovery score %"], "72")
        XCTAssertEqual(rows[0]["Resting heart rate (bpm)"], "58")
    }

    func testImportCreatesWhoopExportRecordWithCorrectValues() throws {
        let context = try makeInMemoryContext()
        let result = WhoopCSVImport.importPhysiologicalCycles(csvText: sampleCSV, context: context)
        XCTAssertEqual(result.rowsImported, 1)
        XCTAssertEqual(result.rowsSkipped, 0)

        let records = try context.fetch(FetchDescriptor<DailyMetricsRecord>())
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.dateKey, "2026-01-15")
        XCTAssertEqual(record.source, "WHOOP_EXPORT")
        XCTAssertEqual(record.recoveryScoreWhoop, 72)
        XCTAssertEqual(record.restingHeartRate, 58)
        XCTAssertEqual(record.hrv, 65)
        XCTAssertEqual(record.strain, 11.8)
        let sleepHours = try XCTUnwrap(record.sleepHours)
        XCTAssertEqual(sleepHours, 7, accuracy: 0.001) // 420 min / 60
        XCTAssertEqual(record.skinTempC, 33.7)
        XCTAssertEqual(record.spo2Percent, 96.5)
        XCTAssertEqual(record.respiratoryRate, 13.3)
    }

    /// HARD RULE: a WHOOP_EXPORT record's real recovery score must never
    /// be overwritten — not by our algorithm, not even by a re-import with
    /// different values.
    func testReimportDoesNotOverwriteExistingWhoopExportValues() throws {
        let context = try makeInMemoryContext()
        _ = WhoopCSVImport.importPhysiologicalCycles(csvText: sampleCSV, context: context)

        let differentCSV = """
        Cycle start time,Wake onset,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Day Strain,Asleep duration (min),Skin temp (celsius),Blood oxygen %,Respiratory rate (rpm),Average HR (bpm),Max HR (bpm)
        2026-01-14 22:00:00,2026-01-15 06:32:00,99,40,120,20,600,30.0,80.0,10.0,50,100
        """
        let secondResult = WhoopCSVImport.importPhysiologicalCycles(csvText: differentCSV, context: context)
        XCTAssertEqual(secondResult.rowsSkipped, 1, "the existing WHOOP_EXPORT row should be protected, not overwritten")

        let records = try context.fetch(FetchDescriptor<DailyMetricsRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].recoveryScoreWhoop, 72, "original value must survive the re-import attempt")
    }

    func testImportSkipsRowsWithUnparsableTimestamp() {
        let badCSV = """
        Cycle start time,Wake onset,Recovery score %
        not-a-date,,72
        """
        let context = try! makeInMemoryContext()
        let result = WhoopCSVImport.importPhysiologicalCycles(csvText: badCSV, context: context)
        XCTAssertEqual(result.rowsImported, 0)
        XCTAssertEqual(result.rowsSkipped, 1)
    }
}
