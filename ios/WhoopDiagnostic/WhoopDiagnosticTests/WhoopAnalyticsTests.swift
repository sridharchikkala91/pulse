import XCTest
@testable import WhoopDiagnostic

final class WhoopAnalyticsTests: XCTestCase {

    // MARK: - RMSSD

    func testRmssdReturnsNilForFewerThanThreeIntervals() {
        XCTAssertNil(WhoopAnalytics.rmssd([800, 850]))
    }

    func testRmssdIsZeroForConstantIntervals() {
        XCTAssertEqual(WhoopAnalytics.rmssd([1000, 1000, 1000]), 0)
    }

    func testRmssdMatchesHandComputedValue() throws {
        let result = try XCTUnwrap(WhoopAnalytics.rmssd([800, 850, 780, 820]))
        XCTAssertEqual(result, 54.772255750516614, accuracy: 0.0000001)
    }

    // MARK: - Robust baseline (median/MAD)

    func testRollingBaselineNilForEmptyInput() {
        XCTAssertNil(WhoopAnalytics.rollingBaseline([]))
    }

    func testRollingBaselineMedianAndMAD() throws {
        let baseline = try XCTUnwrap(WhoopAnalytics.rollingBaseline([1, 2, 3, 4, 5]))
        XCTAssertEqual(baseline.median, 3)
        // deviations from median 3: [2,1,0,1,2] -> sorted [0,1,1,2,2] -> MAD = 1
        XCTAssertEqual(baseline.robustStdDev, 1 * 1.4826, accuracy: 0.0001)
        XCTAssertEqual(baseline.sampleCount, 5)
    }

    // MARK: - Recovery score (OUR_ALGORITHM)

    func testRecoveryScoreIsFiftyWhenTodayExactlyMatchesBaselineWithNeutralSleep() throws {
        let baseline = try XCTUnwrap(WhoopAnalytics.rollingBaseline([60, 60, 60, 60]))
        // A baseline of identical values has MAD=0/robustStdDev=0, which the
        // function explicitly guards against — use a baseline with real spread.
        let spreadBaseline = try XCTUnwrap(WhoopAnalytics.rollingBaseline([55, 60, 60, 65]))
        let score = WhoopAnalytics.recoveryScore(
            hrvToday: spreadBaseline.median, rhrToday: spreadBaseline.median,
            hrvBaseline: spreadBaseline, rhrBaseline: spreadBaseline, sleepHours: 7
        )
        XCTAssertEqual(score, 50)
        _ = baseline // silence unused-variable warning; kept to document the zero-MAD guard case below
    }

    func testRecoveryScoreNilWhenBaselineHasZeroSpread() throws {
        let baseline = try XCTUnwrap(WhoopAnalytics.rollingBaseline([60, 60, 60, 60]))
        XCTAssertEqual(baseline.robustStdDev, 0)
        let score = WhoopAnalytics.recoveryScore(
            hrvToday: 60, rhrToday: 60, hrvBaseline: baseline, rhrBaseline: baseline, sleepHours: 7
        )
        XCTAssertNil(score)
    }

    func testRecoveryScoreClampsToOneAndHundred() throws {
        let baseline = try XCTUnwrap(WhoopAnalytics.rollingBaseline([10, 20, 30, 40]))
        let highScore = WhoopAnalytics.recoveryScore(
            hrvToday: 1000, rhrToday: nil, hrvBaseline: baseline, rhrBaseline: nil, sleepHours: 9
        )
        XCTAssertEqual(highScore, 100)
    }

    // MARK: - Strain score

    func testStrainScoreZeroForEmptySamples() {
        XCTAssertEqual(WhoopAnalytics.strainScore(heartRateSamples: [], restingHeartRate: 60, maxHeartRate: 190), 0)
    }

    func testStrainScoreZeroWhenMaxNotAboveResting() {
        XCTAssertEqual(WhoopAnalytics.strainScore(heartRateSamples: [100, 110], restingHeartRate: 190, maxHeartRate: 190), 0)
    }

    func testStrainScoreStaysWithinDocumentedRange() {
        let samples = Array(repeating: 150.0, count: 1000)
        let strain = WhoopAnalytics.strainScore(heartRateSamples: samples, restingHeartRate: 55, maxHeartRate: 190)
        XCTAssertGreaterThan(strain, 0)
        XCTAssertLessThanOrEqual(strain, 21)
    }

    // MARK: - VO2max + Fitness Age (real numbers this project already validated on real hardware)

    func testEstimateVo2MaxMatchesHandComputedValue() throws {
        let maxHr = WhoopAnalytics.estimateMaxHeartRate(age: 27)
        XCTAssertEqual(maxHr, 189.1, accuracy: 0.001)
        let vo2 = try XCTUnwrap(WhoopAnalytics.estimateVo2Max(restingHeartRate: 58, maxHeartRate: maxHr))
        XCTAssertEqual(vo2, 49.88327586206896, accuracy: 0.0001)
    }

    /// Same real inputs (age 27, RHR 58, HRV 65) this project already used
    /// to validate the corrected fitness-age formula in the web app, after
    /// an earlier RHR-only version swung 8 years in the wrong direction.
    /// Expected to land younger than chronological age, matching that
    /// earlier real-world validation.
    func testEstimateFitnessAgeMatchesHandComputedValue() throws {
        let maxHr = WhoopAnalytics.estimateMaxHeartRate(age: 27)
        let vo2 = try XCTUnwrap(WhoopAnalytics.estimateVo2Max(restingHeartRate: 58, maxHeartRate: maxHr))
        let fitnessAge = try XCTUnwrap(WhoopAnalytics.estimateFitnessAge(chronologicalAge: 27, vo2Max: vo2, hrv: 65))
        XCTAssertEqual(fitnessAge, 25)
        XCTAssertLessThan(fitnessAge, 27, "should land younger than chronological age for these real inputs")
    }

    func testEstimateFitnessAgeNilWithoutRequiredInputs() {
        XCTAssertNil(WhoopAnalytics.estimateFitnessAge(chronologicalAge: nil, vo2Max: 50, hrv: 60))
        XCTAssertNil(WhoopAnalytics.estimateFitnessAge(chronologicalAge: 30, vo2Max: nil, hrv: 60))
    }

    // MARK: - Sleep duration score

    func testSleepDurationScoreNilWithoutBaseline() {
        XCTAssertNil(WhoopAnalytics.sleepDurationScore(lastNightHours: 7, recentNightsHours: []))
    }

    func testSleepDurationScoreHundredWhenMatchingBaseline() throws {
        let score = try XCTUnwrap(WhoopAnalytics.sleepDurationScore(lastNightHours: 7, recentNightsHours: [7, 7, 7, 7]))
        XCTAssertEqual(score, 100)
    }
}
