import SwiftUI
import SwiftData

/// Phase 42: privacy controls. Local-only by construction (no cloud
/// exists yet — Phase 21 is explicitly deferred per the master prompt's
/// own "initially NO CLOUD" instruction), so this is really "delete my
/// data" + "forget the strap" rather than a cloud-sync toggle.
struct PrivacySectionView: View {
    @ObservedObject var ble: WhoopBLEManager
    @Environment(\.modelContext) private var modelContext

    @State private var showDeleteConfirmation = false
    @State private var deleteStatus = ""
    @State private var notificationStatus = ""

    var body: some View {
        Section("Notifications (Phase 43)") {
            Button("Enable notifications") {
                Task {
                    let granted = await WhoopNotifications.requestAuthorization()
                    notificationStatus = granted ? "Enabled" : "Denied or unavailable"
                }
            }
            if !notificationStatus.isEmpty {
                Text(notificationStatus).font(.footnote).foregroundStyle(.secondary)
            }
            Text("Only operational alerts (connected, sync complete/failed, low battery) — never medical alerts.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Privacy (Phase 42)") {
            Text("Local-only. No cloud, no account, no analytics, no ads — everything above is the complete list of what this app does with your data.")
                .font(.caption).foregroundStyle(.secondary)

            Button("Clear remembered strap (forget pairing)") {
                ble.forgetSavedPeripheral()
                deleteStatus = "Forgot the saved strap — next connect will need a fresh scan."
            }

            Button("Delete ALL local data", role: .destructive) {
                showDeleteConfirmation = true
            }

            if !deleteStatus.isEmpty {
                Text(deleteStatus).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Delete all local data? This removes every synced night, journal entry, workout, and imported record. This cannot be undone.",
            isPresented: $showDeleteConfirmation, titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) { deleteAllData() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func deleteAllData() {
        do {
            try modelContext.delete(model: SleepSessionRecord.self)
            try modelContext.delete(model: DailyMetricsRecord.self)
            try modelContext.delete(model: RawPacketRecord.self)
            try modelContext.delete(model: HealthSampleRecord.self)
            try modelContext.delete(model: JournalEntryRecord.self)
            try modelContext.delete(model: WorkoutRecord.self)
            try modelContext.delete(model: SyncStateRecord.self)
            try modelContext.save()
            deleteStatus = "All local data deleted."
        } catch {
            deleteStatus = "Delete failed: \(error.localizedDescription)"
        }
    }
}
