import XCTest
@testable import WhoopDiagnostic

final class WhoopJournalEngineTests: XCTestCase {

    func testCorrelateReturnsNilWithInsufficientData() {
        let factor = ["2026-01-01": true, "2026-01-02": false]
        let metric = ["2026-01-01": 50.0, "2026-01-02": 60.0]
        XCTAssertNil(WhoopJournalEngine.correlate(
            factorByDate: factor, metricByDate: metric, factorLabel: "caffeine", metricLabel: "HRV"
        ))
    }

    func testCorrelateComputesMedianDifferenceWithEnoughData() throws {
        let factor: [String: Bool] = [
            "d1": true, "d2": true, "d3": true,
            "d4": false, "d5": false, "d6": false
        ]
        let metric: [String: Double] = [
            "d1": 40, "d2": 42, "d3": 44,  // median 42, "with" group
            "d4": 60, "d5": 62, "d6": 64   // median 62, "without" group
        ]
        let result = try XCTUnwrap(WhoopJournalEngine.correlate(
            factorByDate: factor, metricByDate: metric, factorLabel: "poor sleep", metricLabel: "HRV"
        ))
        XCTAssertEqual(result.medianWithFactor, 42)
        XCTAssertEqual(result.medianWithoutFactor, 62)
        // (42-62)/62 * 100 = -32.258...
        XCTAssertEqual(result.percentDifference, -32.258064516129032, accuracy: 0.0001)
        XCTAssertEqual(result.daysWithFactor, 3)
        XCTAssertEqual(result.daysWithoutFactor, 3)
        XCTAssertTrue(result.summary.contains("lower"))
        XCTAssertTrue(result.summary.contains("poor sleep"))
        XCTAssertTrue(result.summary.contains("HRV"))
    }

    func testCorrelateSkipsDatesMissingFromEitherMap() {
        // Only 2 dates have both factor AND metric data -> still under minimum of 3 per group.
        let factor: [String: Bool] = ["d1": true, "d2": true, "d3": true, "d4": false, "d5": false, "d6": false]
        let metric: [String: Double] = ["d1": 40, "d2": 42, "d4": 60, "d5": 62] // d3, d6 missing metric data
        XCTAssertNil(WhoopJournalEngine.correlate(
            factorByDate: factor, metricByDate: metric, factorLabel: "x", metricLabel: "y"
        ))
    }
}
