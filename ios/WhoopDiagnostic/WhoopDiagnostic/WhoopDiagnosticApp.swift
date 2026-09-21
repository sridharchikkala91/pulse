import SwiftUI
import SwiftData

@main
struct WhoopDiagnosticApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            SleepSessionRecord.self,
            DailyMetricsRecord.self,
            RawPacketRecord.self,
            SyncStateRecord.self,
            HealthSampleRecord.self
        ])
    }
}
