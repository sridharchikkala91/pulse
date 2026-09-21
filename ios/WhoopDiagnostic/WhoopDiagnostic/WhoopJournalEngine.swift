import Foundation

/// Phase 31: journal correlation analysis. Deliberately conservative —
/// only reports a correlation when both groups (factor present/absent)
/// have enough days to be meaningful, and always reports it as an
/// association, never as causation (the master prompt's own explicit
/// instruction: "do not overstate correlation as causation").
enum WhoopJournalEngine {

    struct Correlation {
        let factorLabel: String
        let metricLabel: String
        let medianWithFactor: Double
        let medianWithoutFactor: Double
        let percentDifference: Double
        let daysWithFactor: Int
        let daysWithoutFactor: Int

        /// Plain-language summary in the interface's voice, per the
        /// master prompt's UX-copy principles: states the observed
        /// association directly, no causal language.
        var summary: String {
            let direction = percentDifference < 0 ? "lower" : "higher"
            return "On days you logged \(factorLabel), your median \(metricLabel) was "
                + String(format: "%.0f%% %@", abs(percentDifference), direction)
                + " (\(daysWithFactor) day(s) with, \(daysWithoutFactor) without)."
        }
    }

    /// Minimum days required in EACH group before a correlation is
    /// reported at all — "only show patterns when enough data exists."
    static let minimumDaysPerGroup = 3

    /// `factorByDate`: true/false per date key (e.g. "had caffeine").
    /// `metricByDate`: a numeric metric per date key (e.g. HRV).
    /// Returns nil if either group has fewer than minimumDaysPerGroup days.
    static func correlate(
        factorByDate: [String: Bool], metricByDate: [String: Double],
        factorLabel: String, metricLabel: String
    ) -> Correlation? {
        var withFactor: [Double] = []
        var withoutFactor: [Double] = []
        for (date, hasFactor) in factorByDate {
            guard let value = metricByDate[date] else { continue }
            if hasFactor { withFactor.append(value) } else { withoutFactor.append(value) }
        }
        guard withFactor.count >= minimumDaysPerGroup, withoutFactor.count >= minimumDaysPerGroup else { return nil }

        let medianWith = median(withFactor)
        let medianWithout = median(withoutFactor)
        guard medianWithout != 0 else { return nil }
        let percentDiff = ((medianWith - medianWithout) / medianWithout) * 100

        return Correlation(
            factorLabel: factorLabel, metricLabel: metricLabel,
            medianWithFactor: medianWith, medianWithoutFactor: medianWithout,
            percentDifference: percentDiff,
            daysWithFactor: withFactor.count, daysWithoutFactor: withoutFactor.count
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
