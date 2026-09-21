import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var ble = WhoopBLEManager()
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSessionRecord.dateKey, order: .reverse) private var sleepSessions: [SleepSessionRecord]

    var body: some View {
        NavigationView {
            List {
                Section("Connection") {
                    row("Bluetooth", ble.bluetoothState)
                    row("WHOOP", ble.whoopFound ? "FOUND" : "NOT FOUND")
                    row("Connection", ble.connectionState)
                    row("Handshake", ble.handshakeState)
                    row("Device", ble.deviceName ?? "--")
                    row("Battery", ble.batteryPercent.map { String(format: "%.1f%%", $0) } ?? "--")
                    row("Firmware", ble.firmwareInfo)
                }
                Section("Live sensor data") {
                    row("HR", ble.liveHeartRateBPM.map { "\($0) bpm" } ?? "--")
                    row("RR", "Not available in Phase 1 — needs RR-interval parsing from the HR characteristic")
                    row("Temperature", "See Sleep History below — comes from historical offload (Phase 3), not live")
                }
                Section("Sync (Phase 3 — historical offload)") {
                    row("Status", ble.syncStatus)
                    row("Records this run", "\(ble.syncRecordsThisRun)")
                    row("Nights stored (all-time)", "\(ble.recordsStoredTotal)")
                    if let last = ble.lastSyncDate {
                        row("Last synchronization", last.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        row("Last synchronization", "Never")
                    }
                    Button("Sync History") { ble.startHistoricalSync() }
                        .disabled(ble.handshakeState != "SUCCESS")
                }
                if !sleepSessions.isEmpty {
                    Section("Sleep history (local database)") {
                        ForEach(sleepSessions.prefix(14)) { session in
                            HStack {
                                Text(session.dateKey)
                                Spacer()
                                Text(String(format: "%.1fh", session.durationHours))
                                    .foregroundStyle(.secondary)
                                if let temp = session.averageSkinTempC {
                                    Text(String(format: "%.1f°C", temp))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("Diagnostics") {
                    row("Packets received", "\(ble.packetsReceived)")
                    row("Packets decoded", "\(ble.packetsDecoded)")
                    row("Packets rejected", "\(ble.packetsRejected)")
                    row("Packets unknown", "\(ble.packetsUnknown)")
                }
                if !ble.lastLog.isEmpty {
                    Section("Last log line") {
                        Text(ble.lastLog).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(ble.connectionState == "DISCONNECTED" ? "Scan & Connect" : "Disconnect") {
                        if ble.connectionState == "DISCONNECTED" {
                            ble.startScan()
                        } else {
                            ble.disconnect()
                        }
                    }
                }
            }
            .navigationTitle("WHOOP 5.0 Diagnostic")
            .onAppear { ble.modelContext = modelContext }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [SleepSessionRecord.self, DailyMetricsRecord.self, RawPacketRecord.self, SyncStateRecord.self])
}
