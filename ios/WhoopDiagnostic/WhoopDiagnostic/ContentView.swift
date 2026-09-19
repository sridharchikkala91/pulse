import SwiftUI

struct ContentView: View {
    @StateObject private var ble = WhoopBLEManager()

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
                    row("Temperature", "Not available in Phase 1 — requires historical offload (Phase 3)")
                }
                Section("Diagnostics") {
                    row("Packets received", "\(ble.packetsReceived)")
                    row("Packets decoded", "\(ble.packetsDecoded)")
                    row("Packets rejected", "\(ble.packetsRejected)")
                    row("Packets unknown", "\(ble.packetsUnknown)")
                    row("Last synchronization", "N/A — Phase 1 has no historical sync")
                    row("Records stored", "0 — Phase 1 has no local database yet")
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
}
