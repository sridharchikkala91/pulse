import SwiftUI
import SwiftData
import Charts

/// Phase 33: trends over time. Reads whatever DailyMetricsRecord history
/// exists (synced, imported, or computed) — no live BLE dependency.
struct TrendsView: View {
    @Query(sort: \DailyMetricsRecord.dateKey, order: .forward) private var dailyMetrics: [DailyMetricsRecord]

    private enum Period: String, CaseIterable { case sevenDay = "7D", thirtyDay = "30D", all = "ALL" }
    @State private var period: Period = .thirtyDay

    private var windowed: [DailyMetricsRecord] {
        switch period {
        case .sevenDay: return Array(dailyMetrics.suffix(7))
        case .thirtyDay: return Array(dailyMetrics.suffix(30))
        case .all: return dailyMetrics
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if dailyMetrics.isEmpty {
                        Text("No history yet — sync your strap, import a WHOOP export, or log data to see trends here.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else {
                        trendChart("HRV (ms)", \.hrv, .purple)
                        trendChart("Resting HR (bpm)", \.restingHeartRate, .orange)
                        trendChart("Sleep (hours)", \.sleepHours, .blue)
                        trendChart("Strain", \.strain, .indigo)
                    }
                }
                .padding()
            }
            .navigationTitle("Trends")
        }
    }

    @ViewBuilder
    private func trendChart(_ title: String, _ keyPath: KeyPath<DailyMetricsRecord, Double?>, _ color: Color) -> some View {
        let points = windowed.compactMap { day -> (String, Double)? in
            guard let value = day[keyPath: keyPath] else { return nil }
            return (day.dateKey, value)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if points.isEmpty {
                Text("No data in this period").font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(points, id: \.0) { point in
                    LineMark(x: .value("Date", point.0), y: .value(title, point.1))
                        .foregroundStyle(color)
                    PointMark(x: .value("Date", point.0), y: .value(title, point.1))
                        .foregroundStyle(color)
                }
                .frame(height: 140)
                .chartXAxis(.hidden)
            }
        }
    }
}

#Preview {
    TrendsView()
        .modelContainer(for: [DailyMetricsRecord.self])
}
