import SwiftUI
import SwiftData

/// Phase 32: a real glance-able dashboard, not just the diagnostic list.
/// Every score here is OUR_ALGORITHM unless explicitly marked otherwise —
/// see WhoopAnalytics.swift for the formulas and their provenance.
struct TodayDashboardView: View {
    @ObservedObject var ble: WhoopBLEManager
    @Query(sort: \DailyMetricsRecord.dateKey, order: .reverse) private var dailyMetrics: [DailyMetricsRecord]
    @AppStorage("userAge") private var ageText: String = ""

    private var age: Double? { Double(ageText) }
    private var latest: DailyMetricsRecord? { dailyMetrics.first }

    private var hrvBaseline: WhoopAnalytics.RobustBaseline? {
        WhoopAnalytics.rollingBaseline(dailyMetrics.compactMap(\.hrv))
    }
    private var rhrBaseline: WhoopAnalytics.RobustBaseline? {
        WhoopAnalytics.rollingBaseline(dailyMetrics.compactMap(\.restingHeartRate))
    }

    private var recoveryScore: Int? {
        guard let latest else { return nil }
        return WhoopAnalytics.recoveryScore(
            hrvToday: latest.hrv, rhrToday: latest.restingHeartRate,
            hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline, sleepHours: latest.sleepHours
        )
    }

    private var sleepNeedBaseline: WhoopAnalytics.RobustBaseline? {
        WhoopAnalytics.rollingBaseline(dailyMetrics.compactMap(\.sleepHours))
    }
    /// Sleep debt over the last 7 nights against a personal need baseline
    /// (median of recent nights) — see WhoopAnalytics.sleepDebtHours.
    private var sleepDebtHours: Double? {
        guard let need = sleepNeedBaseline?.median, need > 0 else { return nil }
        let recent = dailyMetrics.prefix(7).compactMap(\.sleepHours)
        guard !recent.isEmpty else { return nil }
        return WhoopAnalytics.sleepDebtHours(recentNightsHours: Array(recent), sleepNeedHours: need)
    }

    private var recoveryColor: Color {
        guard let recoveryScore else { return .gray }
        if recoveryScore >= 67 { return .green }
        if recoveryScore >= 34 { return .yellow }
        return .red
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    recoveryRing

                    HStack(spacing: 12) {
                        statTile("Sleep", latest?.sleepHours.map { String(format: "%.1fh", $0) } ?? "--", .blue)
                        statTile("Strain", latest?.strain.map { String(format: "%.1f", $0) } ?? "--", .indigo)
                    }
                    HStack(spacing: 12) {
                        statTile("HRV", latest?.hrv.map { "\(Int($0))ms" } ?? "--", .purple)
                        statTile("RHR", latest?.restingHeartRate.map { "\(Int($0))bpm" } ?? "--", .orange)
                    }
                    if let debt = sleepDebtHours {
                        statTile("Sleep debt (7d)", String(format: "%.1fh", debt), debt > 0 ? .red : .green)
                    }
                    if ble.liveHeartRateBPM != nil || ble.connectionState == "CONNECTED" {
                        statTile("Live HR", ble.liveHeartRateBPM.map { "\($0) bpm" } ?? "connecting...", .red)
                    }

                    Text("Recovery, Strain, and HRV shown here are estimates computed on-device from published methods — not WHOOP's proprietary algorithm.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            }
            .navigationTitle("Today")
        }
    }

    private var recoveryRing: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 14)
            Circle()
                .trim(from: 0, to: CGFloat(recoveryScore ?? 0) / 100)
                .stroke(recoveryColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack {
                Text(recoveryScore.map { "\($0)" } ?? "--")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text("RECOVERY")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 180, height: 180)
        .padding(.top, 20)
    }

    private func statTile(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    TodayDashboardView(ble: WhoopBLEManager())
        .modelContainer(for: [DailyMetricsRecord.self])
}
