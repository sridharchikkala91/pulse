import SwiftUI
import SwiftData

/// Root tab view: a real dashboard (Phase 32) alongside the original
/// diagnostic screen (Phase 1), sharing one WhoopBLEManager/
/// WhoopHealthKitImporter instance so there's only ever one BLE
/// connection and one HealthKit authorization flow, regardless of which
/// tab is showing.
struct ContentView: View {
    @StateObject private var ble = WhoopBLEManager()
    @StateObject private var healthKit = WhoopHealthKitImporter()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            TodayDashboardView(ble: ble)
                .tabItem { Label("Today", systemImage: "heart.fill") }

            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }

            DiagnosticsView(ble: ble, healthKit: healthKit)
                .tabItem { Label("Diagnostics", systemImage: "wrench.and.screwdriver") }
        }
        .onAppear { ble.modelContext = modelContext }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            SleepSessionRecord.self, DailyMetricsRecord.self, RawPacketRecord.self, SyncStateRecord.self,
            HealthSampleRecord.self, JournalEntryRecord.self, WorkoutRecord.self
        ])
}
