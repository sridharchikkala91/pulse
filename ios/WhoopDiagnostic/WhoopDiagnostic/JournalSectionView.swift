import SwiftUI
import SwiftData

/// Phase 31: journal entries + correlation analysis. Manual entry only —
/// see WhoopDatabase.swift's JournalEntryRecord doc comment for why this
/// project doesn't import WHOOP's journal_entries.csv export (unverified
/// column headers).
struct JournalSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JournalEntryRecord.dateKey, order: .reverse) private var entries: [JournalEntryRecord]
    @Query(sort: \DailyMetricsRecord.dateKey, order: .reverse) private var dailyMetrics: [DailyMetricsRecord]

    @State private var hadCaffeineToday = false
    @State private var hadAlcoholToday = false
    @State private var hadLateExerciseToday = false
    @State private var feltIllToday = false
    @State private var notesToday = ""

    private var todayKey: String {
        // Matches the rest of the app's "sleep day rolls over at 6am" convention.
        let adjusted = Date().addingTimeInterval(-6 * 3600)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: adjusted)
    }

    private var hrvByDate: [String: Double] {
        Dictionary(uniqueKeysWithValues: dailyMetrics.compactMap { day in
            day.hrv.map { (day.dateKey, $0) }
        })
    }

    private var caffeineByDate: [String: Bool] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.dateKey, $0.hadCaffeine) })
    }
    private var alcoholByDate: [String: Bool] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.dateKey, $0.hadAlcohol) })
    }

    private var caffeineCorrelation: WhoopJournalEngine.Correlation? {
        WhoopJournalEngine.correlate(factorByDate: caffeineByDate, metricByDate: hrvByDate, factorLabel: "caffeine", metricLabel: "HRV")
    }
    private var alcoholCorrelation: WhoopJournalEngine.Correlation? {
        WhoopJournalEngine.correlate(factorByDate: alcoholByDate, metricByDate: hrvByDate, factorLabel: "alcohol", metricLabel: "HRV")
    }

    var body: some View {
        Section("Journal (Phase 31)") {
            Toggle("Caffeine today", isOn: $hadCaffeineToday)
            Toggle("Alcohol today", isOn: $hadAlcoholToday)
            Toggle("Late exercise today", isOn: $hadLateExerciseToday)
            Toggle("Felt ill today", isOn: $feltIllToday)
            TextField("Notes", text: $notesToday)
            Button("Save today's entry") { saveTodayEntry() }
        }

        if caffeineCorrelation != nil || alcoholCorrelation != nil {
            Section("Correlations (association only, not causation)") {
                if let c = caffeineCorrelation {
                    Text(c.summary).font(.footnote)
                }
                if let c = alcoholCorrelation {
                    Text(c.summary).font(.footnote)
                }
            }
        }
    }

    private func saveTodayEntry() {
        let entry = JournalEntryRecord(dateKey: todayKey)
        entry.hadCaffeine = hadCaffeineToday
        entry.hadAlcohol = hadAlcoholToday
        entry.hadLateExercise = hadLateExerciseToday
        entry.feltIll = feltIllToday
        entry.notes = notesToday
        modelContext.insert(entry)
        try? modelContext.save()
    }
}
