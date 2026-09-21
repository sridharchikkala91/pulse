import SwiftUI
import SwiftData

/// Phase 34: calendar view. Each day is colored by OUR recovery score
/// (green/yellow/red, matching TodayDashboardView's own color mapping) —
/// never WHOOP's real algorithm. Tapping a day shows its full metrics.
struct CalendarView: View {
    @Query(sort: \DailyMetricsRecord.dateKey, order: .forward) private var dailyMetrics: [DailyMetricsRecord]
    @State private var selectedDay: DailyMetricsRecord?

    private var byDate: [String: DailyMetricsRecord] {
        Dictionary(uniqueKeysWithValues: dailyMetrics.map { ($0.dateKey, $0) })
    }

    private var hrvBaseline: WhoopAnalytics.RobustBaseline? {
        WhoopAnalytics.rollingBaseline(dailyMetrics.compactMap(\.hrv))
    }
    private var rhrBaseline: WhoopAnalytics.RobustBaseline? {
        WhoopAnalytics.rollingBaseline(dailyMetrics.compactMap(\.restingHeartRate))
    }

    private func recoveryScore(for day: DailyMetricsRecord) -> Int? {
        WhoopAnalytics.recoveryScore(
            hrvToday: day.hrv, rhrToday: day.restingHeartRate,
            hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline, sleepHours: day.sleepHours
        )
    }

    private func color(for score: Int?) -> Color {
        guard let score else { return Color.secondary.opacity(0.15) }
        if score >= 67 { return .green }
        if score >= 34 { return .yellow }
        return .red
    }

    private let columns = Array(repeating: GridItem(.flexible()), count: 7)

    var body: some View {
        NavigationView {
            ScrollView {
                if dailyMetrics.isEmpty {
                    Text("No history yet.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(dailyMetrics) { day in
                            Button {
                                selectedDay = day
                            } label: {
                                VStack(spacing: 2) {
                                    Text(dayNumber(day.dateKey))
                                        .font(.caption2)
                                    Circle()
                                        .fill(color(for: recoveryScore(for: day)))
                                        .frame(width: 10, height: 10)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Calendar")
            .sheet(item: $selectedDay) { day in
                DayDetailView(day: day, recoveryScore: recoveryScore(for: day))
            }
        }
    }

    private func dayNumber(_ dateKey: String) -> String {
        String(dateKey.suffix(2))
    }
}

private struct DayDetailView: View {
    let day: DailyMetricsRecord
    let recoveryScore: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    row("Recovery (ours)", recoveryScore.map { "\($0)" } ?? "--")
                    if let whoop = day.recoveryScoreWhoop { row("Recovery (WHOOP export)", "\(Int(whoop))%") }
                    row("Sleep", day.sleepHours.map { String(format: "%.1fh", $0) } ?? "--")
                    row("Strain", day.strain.map { String(format: "%.1f", $0) } ?? "--")
                    row("HRV", day.hrv.map { "\(Int($0))ms" } ?? "--")
                    row("RHR", day.restingHeartRate.map { "\(Int($0))bpm" } ?? "--")
                    row("Skin temp", day.skinTempC.map { String(format: "%.1f°C", $0) } ?? "--")
                    row("Source", day.source)
                }
            }
            .navigationTitle(day.dateKey)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    CalendarView()
        .modelContainer(for: [DailyMetricsRecord.self])
}
