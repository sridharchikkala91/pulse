import Foundation

/// Phase 11 (HRV/RHR analytics), Phase 12 (Recovery), Phase 13 (Strain),
/// Phase 30 (Fitness/Biological Age), Phase 36 (Personal Baselines).
///
/// EVERYTHING here is OUR OWN algorithm, built from published, generally-
/// accepted formulas (RMSSD, Karvonen %HRR, Tanaka max-HR, the
/// Uth-Sørensen-Overgaard-Pedersen non-exercise VO2max estimate). None of
/// it reproduces WHOOP's actual proprietary scoring — see
/// docs/WHOOP5_LIMITATIONS.md for why that's not achievable, and section
/// 16/25 of the master prompt for why WHOOP_EXPORT-sourced historical
/// scores must never be overwritten by this engine.
enum WhoopAnalytics {

    // MARK: - Phase 36: Personal baseline engine

    /// A robust baseline using median + MAD (median absolute deviation)
    /// rather than mean/stddev, per the master prompt's explicit
    /// preference (section 36) for statistics that don't assume a
    /// population-normal distribution is appropriate for one individual.
    /// This is a genuine upgrade over the web app's original mean/stddev
    /// approach, not a straight port.
    struct RobustBaseline {
        let median: Double
        /// MAD scaled by 1.4826 so it estimates a standard deviation for
        /// normally-distributed data — the standard consistency constant,
        /// not an invented one.
        let robustStdDev: Double
        let sampleCount: Int
    }

    static func rollingBaseline(_ values: [Double]) -> RobustBaseline? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let median = Self.median(of: sorted)
        let deviations = values.map { abs($0 - median) }.sorted()
        let mad = Self.median(of: deviations)
        return RobustBaseline(median: median, robustStdDev: mad * 1.4826, sampleCount: values.count)
    }

    private static func median(of sorted: [Double]) -> Double {
        let n = sorted.count
        guard n > 0 else { return 0 }
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    // MARK: - Phase 11: HRV

    /// RMSSD from a sequence of RR intervals in milliseconds — the
    /// standard root-mean-square-of-successive-differences HRV metric.
    static func rmssd(_ rrIntervalsMs: [Double]) -> Double? {
        guard rrIntervalsMs.count >= 3 else { return nil }
        var sumSquares = 0.0
        for i in 1..<rrIntervalsMs.count {
            let diff = rrIntervalsMs[i] - rrIntervalsMs[i - 1]
            sumSquares += diff * diff
        }
        return (sumSquares / Double(rrIntervalsMs.count - 1)).squareRoot()
    }

    /// Tanaka et al. (2001) age-predicted max heart rate: 208 - 0.7 * age.
    static func estimateMaxHeartRate(age: Double?) -> Double {
        guard let age else { return 190 }
        return 208 - 0.7 * age
    }

    // MARK: - Phase 12: Recovery (OUR_ALGORITHM only)

    /// A recovery score (1-100) from HRV/RHR deviation against a robust
    /// personal baseline, plus a modest sleep-duration adjustment. This
    /// is explicitly OUR_ALGORITHM — never label this as WHOOP's score.
    static func recoveryScore(hrvToday: Double?, rhrToday: Double?, hrvBaseline: RobustBaseline?,
                               rhrBaseline: RobustBaseline?, sleepHours: Double?) -> Int? {
        guard let hrvToday, let hrvBaseline, hrvBaseline.robustStdDev > 0 else { return nil }
        let hrvZ = (hrvToday - hrvBaseline.median) / hrvBaseline.robustStdDev
        var rhrZ = 0.0
        if let rhrToday, let rhrBaseline, rhrBaseline.robustStdDev > 0 {
            rhrZ = (rhrToday - rhrBaseline.median) / rhrBaseline.robustStdDev
        }
        var score = 50 + 22 * hrvZ - 13 * rhrZ
        if let sleepHours {
            score += min(max((sleepHours - 7) * 3, -10), 10)
        }
        return min(max(Int(score.rounded()), 1), 100)
    }

    // MARK: - Phase 13: Strain (OUR_ALGORITHM only)

    /// Karvonen %HRR (heart-rate reserve) accumulated across a sequence of
    /// heart-rate samples, log-scaled onto WHOOP's approximate 0-21 range.
    /// Direct port of the web app's strainFromSamples, already in
    /// production use there.
    static func strainScore(heartRateSamples: [Double], restingHeartRate: Double?, maxHeartRate: Double) -> Double {
        guard !heartRateSamples.isEmpty, let restingHeartRate, maxHeartRate > restingHeartRate else { return 0 }
        var accumulatedHRR = 0.0
        for hr in heartRateSamples {
            let hrr = max(0, (hr - restingHeartRate) / (maxHeartRate - restingHeartRate))
            accumulatedHRR += hrr
        }
        let normalized = accumulatedHRR / Double(heartRateSamples.count)
        // log-scale so a whole day's accumulated load maps onto a 0-21 range
        // roughly matching WHOOP's own displayed scale (approximate only).
        let scaled = log(1 + normalized * Double(heartRateSamples.count) / 100) * 8
        return min(max(scaled, 0), 21)
    }

    // MARK: - Phase 30: Fitness / Biological Age (explicitly an estimate)

    /// Uth-Sørensen-Overgaard-Pedersen (2004) non-exercise VO2max estimate:
    /// VO2max ≈ 15.3 × (HRmax / HRrest). A recognized published formula,
    /// not invented — carries real error margins, see docs.
    static func estimateVo2Max(restingHeartRate: Double?, maxHeartRate: Double) -> Double? {
        guard let restingHeartRate, restingHeartRate > 0 else { return nil }
        return 15.3 * (maxHeartRate / restingHeartRate)
    }

    /// An estimated fitness/biological age — NOT a medical measurement.
    /// Blends two signals: (1) VO2max vs. a rough population-average
    /// decline curve, and (2) HRV vs. Nunan, Sandercock & Brodie (2010),
    /// a real meta-analysis of 21,438 healthy adults (mean short-term
    /// RMSSD 42ms, range 19-75ms — used here as an approximate SD via
    /// (75-19)/4 = 14ms). HRV is weighted more heavily since it is the
    /// better-validated aging biomarker of the two. This exact approach
    /// (and its weighting) was already corrected once in the web app
    /// after an RHR-only version swung 8 years in the wrong direction
    /// for this project's own test subject — see docs/superpowers/specs
    /// in the repo root for that history. Always label this output as an
    /// estimate to the end user.
    static func estimateFitnessAge(chronologicalAge: Double?, vo2Max: Double?, hrv: Double?) -> Int? {
        guard let chronologicalAge, let vo2Max else { return nil }
        let avgVo2MaxForAge = 55 - 0.35 * (chronologicalAge - 20)
        let ageAdjustFromVo2Max = (avgVo2MaxForAge - vo2Max) / 0.35

        var adjust = ageAdjustFromVo2Max
        if let hrv {
            let hrvZ = (hrv - 42) / 14
            let ageAdjustFromHrv = -4 * hrvZ
            adjust = 0.35 * ageAdjustFromVo2Max + 0.65 * ageAdjustFromHrv
        }
        let age = chronologicalAge + adjust
        return min(max(Int(age.rounded()), 10), 90)
    }

    // MARK: - Phase 27: Sleep Score

    /// Duration component: how last night compares to a personal
    /// sleep-need baseline (median of recent nights). Stage-based
    /// components (REM/light/deep proportions) are NOT implemented — they
    /// need data this project hasn't decoded (see
    /// docs/WHOOP5_LIMITATIONS.md: only a coarse wake/still/sleep/up enum
    /// is available, not true accelerometer-derived sleep architecture).
    /// Returns nil rather than a fabricated full score when there isn't
    /// enough history to establish a personal need baseline.
    static func sleepDurationScore(lastNightHours: Double, recentNightsHours: [Double]) -> Int? {
        guard let baseline = rollingBaseline(recentNightsHours), baseline.median > 0 else { return nil }
        let ratio = lastNightHours / baseline.median
        let score = min(max(ratio * 100, 0), 100)
        return Int(score.rounded())
    }

    /// Consistency component: how stable recent bedtimes have been.
    /// `startHoursSincePreviousNoon` should already be normalized to avoid
    /// the midnight wraparound discontinuity — e.g. an 11pm bedtime is 11,
    /// a 1am bedtime is 13 (noon-anchored, not midnight-anchored), so
    /// consecutive late-evening/post-midnight bedtimes stay comparable on
    /// one continuous scale instead of jumping between ~23 and ~1.
    /// Uses the robust MAD baseline: tight MAD (consistent bedtimes) scores
    /// high, wide MAD (erratic bedtimes) scores low. 2 hours of spread
    /// (MAD) is treated as the point where the score bottoms out at 0 —
    /// this specific threshold is this project's own reasonable choice,
    /// not a WHOOP- or research-derived constant.
    static func sleepConsistencyScore(startHoursSincePreviousNoon: [Double]) -> Int? {
        guard let baseline = rollingBaseline(startHoursSincePreviousNoon) else { return nil }
        let maxSpreadHours = 2.0
        let score = (1 - (baseline.robustStdDev / maxSpreadHours)) * 100
        return min(max(Int(score.rounded()), 0), 100)
    }

    /// Sleep debt: cumulative shortfall (in hours) against a personal
    /// sleep-need baseline over the given nights, floored at 0 per night
    /// (oversleeping one night doesn't create "negative debt" that offsets
    /// a shortfall on another — each night's shortfall is independent).
    static func sleepDebtHours(recentNightsHours: [Double], sleepNeedHours: Double) -> Double {
        recentNightsHours.reduce(0.0) { total, hours in total + max(0, sleepNeedHours - hours) }
    }
}
