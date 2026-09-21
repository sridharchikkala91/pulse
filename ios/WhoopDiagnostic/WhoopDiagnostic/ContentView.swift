import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var ble = WhoopBLEManager()
    @StateObject private var healthKit = WhoopHealthKitImporter()
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSessionRecord.dateKey, order: .reverse) private var sleepSessions: [SleepSessionRecord]
    @Query(sort: \DailyMetricsRecord.dateKey, order: .reverse) private var dailyMetrics: [DailyMetricsRecord]

    @State private var ageText: String = ""
    @State private var isImportingCSV = false
    @State private var importStatus: String = ""
    @State private var exportedCSVURL: URL?
    @State private var exportedJSONURL: URL?

    private var age: Double? { Double(ageText) }

    private var latest: DailyMetricsRecord? { dailyMetrics.first }

    private var hrvBaseline: WhoopAnalytics.RobustBaseline? {
        WhoopAnalytics.rollingBaseline(dailyMetrics.compactMap(\.hrv))
    }
    private var rhrBaseline: WhoopAnalytics.RobustBaseline? {
        WhoopAnalytics.rollingBaseline(dailyMetrics.compactMap(\.restingHeartRate))
    }

    private var ourRecoveryScore: Int? {
        guard let latest else { return nil }
        return WhoopAnalytics.recoveryScore(
            hrvToday: latest.hrv, rhrToday: latest.restingHeartRate,
            hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline, sleepHours: latest.sleepHours
        )
    }

    private var ourFitnessAge: Int? {
        guard let latest else { return nil }
        let maxHr = WhoopAnalytics.estimateMaxHeartRate(age: age)
        let vo2 = WhoopAnalytics.estimateVo2Max(restingHeartRate: latest.restingHeartRate, maxHeartRate: maxHr)
        return WhoopAnalytics.estimateFitnessAge(chronologicalAge: age, vo2Max: vo2, hrv: latest.hrv)
    }

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

                Section("Analytics (OUR_ALGORITHM — not WHOOP's real scores)") {
                    HStack {
                        Text("Your age (for fitness age estimate)")
                        Spacer()
                        TextField("e.g. 29", text: $ageText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    row("Recovery (ours)", ourRecoveryScore.map { "\($0)" } ?? "-- (needs synced/imported history)")
                    if let latest, let whoopRecovery = latest.recoveryScoreWhoop {
                        row("Recovery (WHOOP export)", "\(Int(whoopRecovery))%")
                    }
                    row("Fitness age estimate", ourFitnessAge.map { "\($0) yrs" } ?? "-- (needs age + HRV/RHR data)")
                    Text("Estimated wellness metric — not a medical measurement, and not WHOOP's proprietary algorithm.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("WHOOP data export (Phase 6)") {
                    Button("Import physiological_cycles.csv") { isImportingCSV = true }
                    if !importStatus.isEmpty {
                        Text(importStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("HealthKit — optional secondary source (Phase 37)") {
                    row("Available on this device", WhoopHealthKitImporter.isAvailableOnThisDevice ? "YES" : "NO")
                    row("Authorization", healthKit.authorizationStatus)
                    Button("Request HealthKit Access") {
                        Task { await healthKit.requestAuthorization() }
                    }
                    Button("Import last 7 days from HealthKit") {
                        Task { await healthKit.importRecentSamples(days: 7, context: modelContext) }
                    }
                    if !healthKit.lastImportStatus.isEmpty {
                        Text(healthKit.lastImportStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("WHOOP stays the primary source — this never overwrites WHOOP-sourced data, only adds HEALTHKIT-labeled rows alongside it.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                JournalSectionView()

                WorkoutSectionView(ble: ble, age: age, latestRestingHeartRate: latest?.restingHeartRate)

                Section("Export your data (Phase 41)") {
                    if let url = exportedCSVURL {
                        ShareLink("Export daily metrics as CSV", item: url)
                    } else {
                        Button("Export daily metrics as CSV") { exportedCSVURL = writeExportFile(csv: true) }
                    }
                    if let url = exportedJSONURL {
                        ShareLink("Export everything as JSON", item: url)
                    } else {
                        Button("Export everything as JSON") { exportedJSONURL = writeExportFile(csv: false) }
                    }
                }

                if !dailyMetrics.isEmpty {
                    Section("Daily metrics history") {
                        ForEach(dailyMetrics.prefix(14)) { day in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(day.dateKey).bold()
                                    Spacer()
                                    Text(day.source).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text([
                                    day.hrv.map { "HRV \(Int($0))ms" },
                                    day.restingHeartRate.map { "RHR \(Int($0))bpm" },
                                    day.sleepHours.map { String(format: "Sleep %.1fh", $0) },
                                    day.recoveryScoreWhoop.map { "WHOOP Recovery \(Int($0))%" }
                                ].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !sleepSessions.isEmpty {
                    Section("Sleep sessions (synced)") {
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
            .fileImporter(isPresented: $isImportingCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                switch result {
                case .success(let url):
                    importCSV(from: url)
                case .failure(let error):
                    importStatus = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func writeExportFile(csv: Bool) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        do {
            if csv {
                let url = tempDir.appendingPathComponent("whoop_daily_metrics.csv")
                try WhoopDataExport.exportDailyMetricsCSV(dailyMetrics).write(to: url, atomically: true, encoding: .utf8)
                return url
            } else {
                let url = tempDir.appendingPathComponent("whoop_export.json")
                let data = try WhoopDataExport.exportJSON(dailyMetrics: dailyMetrics, sleepSessions: sleepSessions)
                try data.write(to: url)
                return url
            }
        } catch {
            importStatus = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func importCSV(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            importStatus = "Could not access the selected file"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = WhoopCSVImport.importPhysiologicalCycles(csvText: text, context: modelContext)
            importStatus = "Imported \(result.rowsImported) day(s), skipped \(result.rowsSkipped) (unparsable or already WHOOP_EXPORT-protected)"
        } catch {
            importStatus = "Could not read file: \(error.localizedDescription)"
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
        .modelContainer(for: [
            SleepSessionRecord.self, DailyMetricsRecord.self, RawPacketRecord.self, SyncStateRecord.self,
            HealthSampleRecord.self, JournalEntryRecord.self, WorkoutRecord.self
        ])
}
