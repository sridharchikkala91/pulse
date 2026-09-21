import Foundation
import CoreBluetooth
import SwiftData

/// Phase 1 (diagnostic connect/handshake/battery/live HR) + Phase 3
/// (historical offload) + Phase 5 (local persistence via SwiftData).
/// Full sensor decoding beyond Gen5HistorySample and background sync
/// (Phase 7) are NOT implemented here — see docs/WHOOP5_LIMITATIONS.md.
final class WhoopBLEManager: NSObject, ObservableObject {

    // MARK: - GATT UUIDs (see docs/WHOOP5_GATT.md)

    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateMeasurement = CBUUID(string: "2A37")
    private static let proprietaryService = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a")
    private static let cmdWriteChar = CBUUID(string: "fd4b0002-cce1-4033-93ce-002d5875f58a")
    private static let cmdResponseChar = CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a")
    private static let eventsChar = CBUUID(string: "fd4b0004-cce1-4033-93ce-002d5875f58a")
    private static let dataChar = CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a")
    private static let memfaultChar = CBUUID(string: "fd4b0007-cce1-4033-93ce-002d5875f58a")

    // MARK: - Published diagnostic state

    @Published var bluetoothState: String = "UNKNOWN"
    @Published var whoopFound: Bool = false
    @Published var connectionState: String = "DISCONNECTED"
    /// "Bonding" here means the WHOOP application-layer CLIENT_HELLO
    /// handshake succeeding, NOT an OS-level BLE bond — this project has
    /// never established that the strap requires or performs one over
    /// CoreBluetooth. See docs/WHOOP5_LIMITATIONS.md.
    @Published var handshakeState: String = "NOT ATTEMPTED"
    @Published var batteryPercent: Double?
    @Published var deviceName: String?
    @Published var firmwareInfo: String = "Not available (REPORT_VERSION_INFO gets no response on this firmware — see docs/WHOOP5_LIMITATIONS.md)"
    @Published var liveHeartRateBPM: Int?
    @Published var packetsReceived: Int = 0
    @Published var packetsDecoded: Int = 0
    @Published var packetsRejected: Int = 0
    @Published var packetsUnknown: Int = 0
    @Published var lastLog: String = ""

    // MARK: - Published sync state (Phase 3)

    @Published var syncStatus: String = "NEVER RUN"
    @Published var syncRecordsThisRun: Int = 0
    @Published var lastSyncDate: Date?
    @Published var recordsStoredTotal: Int = 0

    /// Set by the view once a SwiftData context is available. Persistence
    /// is skipped (with a log line) if this is never set.
    var modelContext: ModelContext?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdWriteCharacteristic: CBCharacteristic?

    private var isSyncing = false
    private var syncReconnectAttempts = 0
    private let maxSyncReconnectAttempts = 30
    private var historicalSamples: [WhoopProtocol.HistorySample] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func log(_ s: String) {
        lastLog = s
    }

    func startScan() {
        guard central.state == .poweredOn else {
            log("Cannot scan — Bluetooth state is \(bluetoothState)")
            return
        }
        connectionState = "SCANNING"
        central.scanForPeripherals(withServices: [Self.heartRateService], options: nil)
    }

    func disconnect() {
        isSyncing = false
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    /// Starts the Phase 3 historical offload. Requires an existing
    /// successful handshake (uses the same connection/characteristics).
    func startHistoricalSync() {
        guard handshakeState == "SUCCESS", cmdWriteCharacteristic != nil else {
            log("Cannot sync — handshake not established yet")
            return
        }
        isSyncing = true
        syncReconnectAttempts = 0
        historicalSamples = []
        syncRecordsThisRun = 0
        syncStatus = "Starting sync..."
        beginOffloadCommands()
    }

    private func beginOffloadCommands() {
        syncStatus = "Requesting data range..."
        sendCommand(0x22, [0x00]) // GET_DATA_RANGE
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isSyncing else { return }
            self.syncStatus = "Draining history... \(self.syncRecordsThisRun) records so far"
            self.sendCommand(0x16, [0x00]) // SEND_HISTORICAL_DATA
        }
    }

    private func sendCommand(_ cmd: UInt8, _ payload: [UInt8]) {
        guard let c = cmdWriteCharacteristic, let p = peripheral else { return }
        let frame = WhoopProtocol.encodeCommand(cmd, payload)
        p.writeValue(Data(frame), for: c, type: .withResponse)
    }

    // MARK: - Sync completion & persistence (Phase 5)

    private func finishSync(reason: String) {
        guard isSyncing else { return }
        isSyncing = false
        syncStatus = "Processing \(historicalSamples.count) records..."

        let sessions = WhoopProtocol.extractSleepSessions(historicalSamples)
        var byDate: [String: (durationHours: Double, avgTemp: Double?, start: UInt32, end: UInt32)] = [:]
        for session in sessions {
            let hours = Double(session.endTimestamp - session.startTimestamp) / 3600
            let date = Date(timeIntervalSince1970: TimeInterval(session.endTimestamp))
            let dateKey = Self.sleepDayKey(for: date)
            let avgTemp = session.skinTemps.isEmpty ? nil : session.skinTemps.reduce(0, +) / Double(session.skinTemps.count)
            if byDate[dateKey] == nil || byDate[dateKey]!.durationHours < hours {
                byDate[dateKey] = (hours, avgTemp, session.startTimestamp, session.endTimestamp)
            }
        }

        if let context = modelContext {
            for (dateKey, info) in byDate {
                let record = SleepSessionRecord(
                    dateKey: dateKey, startTimestamp: Int(info.start), endTimestamp: Int(info.end),
                    durationHours: info.durationHours, averageSkinTempC: info.avgTemp, source: "synced"
                )
                context.insert(record)
            }
            try? context.save()
        } else {
            log("No ModelContext set — sync results were NOT persisted")
        }

        recordsStoredTotal += byDate.count
        lastSyncDate = Date()
        let suffix = reason == "complete" ? " — fully caught up!" : " — stopped after \(syncReconnectAttempts) reconnect attempts, run Sync again to continue"
        if byDate.isEmpty {
            syncStatus = "Sync finished: no qualifying sleep sessions in \(historicalSamples.count) records\(suffix)"
        } else {
            let summary = byDate.map { "\($0.key) (\(String(format: "%.1f", $0.value.durationHours))h)" }.joined(separator: ", ")
            syncStatus = "Synced \(byDate.count) night(s): \(summary)\(suffix)"
        }
    }

    /// Matches the web app's "sleep day rolls over at 6am, not midnight" convention.
    private static func sleepDayKey(for date: Date) -> String {
        let adjusted = date.addingTimeInterval(-6 * 3600)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: adjusted)
    }
}

// MARK: - CBCentralManagerDelegate

extension WhoopBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bluetoothState = "ON"
        case .poweredOff: bluetoothState = "OFF"
        case .unauthorized: bluetoothState = "UNAUTHORIZED"
        case .unsupported: bluetoothState = "UNSUPPORTED"
        case .resetting: bluetoothState = "RESETTING"
        default: bluetoothState = "UNKNOWN"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        whoopFound = true
        deviceName = peripheral.name
        self.peripheral = peripheral
        central.stopScan()
        connectionState = "CONNECTING"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = "CONNECTED"
        peripheral.delegate = self
        peripheral.discoverServices([Self.heartRateService, Self.proprietaryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = "DISCONNECTED"
        log("Connect failed: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionState = "DISCONNECTED"
        handshakeState = "NOT ATTEMPTED"
        cmdWriteCharacteristic = nil

        if isSyncing {
            syncReconnectAttempts += 1
            if syncReconnectAttempts >= maxSyncReconnectAttempts {
                finishSync(reason: "gave up")
                return
            }
            syncStatus = "Connection dropped, reconnecting (\(syncRecordsThisRun) records so far)..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.isSyncing else { return }
                self.connectionState = "CONNECTING"
                self.central.connect(peripheral, options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension WhoopBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == Self.heartRateService {
                peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
            } else if service.uuid == Self.proprietaryService {
                peripheral.discoverCharacteristics(
                    [Self.cmdWriteChar, Self.cmdResponseChar, Self.eventsChar, Self.dataChar, Self.memfaultChar],
                    for: service
                )
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == Self.heartRateMeasurement {
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == Self.cmdWriteChar {
                cmdWriteCharacteristic = characteristic
                // Kick off (or resume, if this is a mid-sync reconnect) the handshake.
                handshakeState = "IN PROGRESS"
                peripheral.writeValue(Data(WhoopProtocol.clientHello), for: characteristic, type: .withResponse)
            } else if [Self.cmdResponseChar, Self.eventsChar, Self.dataChar, Self.memfaultChar].contains(characteristic.uuid) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }

        if characteristic.uuid == Self.heartRateMeasurement {
            liveHeartRateBPM = Self.parseHeartRate(data)
            return
        }

        // Proprietary channel notifications.
        packetsReceived += 1
        let bytes = [UInt8](data)
        guard let decoded = WhoopProtocol.decodeFrame(bytes) else {
            packetsRejected += 1
            persistRawPacket(characteristic.uuid, bytes: bytes, status: "INVALID", reason: "failed to parse envelope")
            return
        }
        guard decoded.crc16Valid, decoded.crc32Valid else {
            packetsRejected += 1
            persistRawPacket(characteristic.uuid, bytes: bytes, packetType: Int(decoded.type),
                              status: "INVALID", reason: "CRC mismatch")
            return
        }

        if decoded.type == 36, decoded.cmd == 0x91 { // COMMAND_RESPONSE to GET_HELLO
            packetsDecoded += 1
            handshakeState = "SUCCESS"
            if isSyncing {
                // This is a resume-after-reconnect handshake; pick the offload back up.
                beginOffloadCommands()
            } else {
                sendCommand(26, [0x00]) // GET_BATTERY_LEVEL, normal (non-sync) flow
            }
        } else if decoded.type == 36, decoded.cmd == 26, decoded.payload.count >= 4 { // GET_BATTERY_LEVEL response
            packetsDecoded += 1
            let raw = UInt16(decoded.payload[2]) | (UInt16(decoded.payload[3]) << 8)
            batteryPercent = Double(raw) / 10
        } else if decoded.type == 49 { // METADATA
            handleMetadata(decoded)
        } else if decoded.type == 47 { // HISTORICAL_DATA
            packetsDecoded += 1
            if let sample = WhoopProtocol.decodeHistorySample(decoded.payload) {
                historicalSamples.append(sample)
                syncRecordsThisRun += 1
                if syncRecordsThisRun % 200 == 0 {
                    syncStatus = "Draining history... \(syncRecordsThisRun) records so far"
                }
            } else {
                persistRawPacket(characteristic.uuid, bytes: bytes, packetType: 47,
                                  status: "PARTIAL", reason: "payload too short to decode Gen5HistorySample")
            }
        } else {
            packetsUnknown += 1
            persistRawPacket(characteristic.uuid, bytes: bytes, packetType: Int(decoded.type),
                              status: "UNKNOWN", reason: nil)
        }
    }

    private func handleMetadata(_ decoded: WhoopProtocol.DecodedFrame) {
        let sub = decoded.cmd
        switch sub {
        case 1: // HISTORY_START — informational, no action needed.
            packetsDecoded += 1
        case 2: // HISTORY_END
            if decoded.payload.count >= 18 {
                let token = Array(decoded.payload[10..<18])
                sendCommand(0x17, [0x01] + token) // HISTORICAL_DATA_RESULT ACK
                packetsDecoded += 1
            } else {
                packetsRejected += 1
            }
        case 3: // HISTORY_COMPLETE
            packetsDecoded += 1
            finishSync(reason: "complete")
        default:
            packetsUnknown += 1
        }
    }

    private func persistRawPacket(_ uuid: CBUUID, bytes: [UInt8], packetType: Int? = nil, status: String, reason: String?) {
        guard let context = modelContext else { return }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let record = RawPacketRecord(characteristicUUID: uuid.uuidString, payloadHex: hex,
                                      packetType: packetType, decodeStatus: status, errorReason: reason)
        context.insert(record)
        // Not saving on every single packet to avoid excessive disk I/O during
        // a large offload — SwiftData autosaves periodically; an explicit
        // save happens at sync completion in finishSync().
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("Write failed for \(characteristic.uuid): \(error.localizedDescription)")
        }
    }

    /// Standard Bluetooth Heart Rate Measurement (0x2A37) parser.
    /// NOTE: bit 2 (0x04, Sensor Contact Status) is a status-only flag and
    /// consumes zero payload bytes — a bug in this project's own earlier
    /// JS implementation treated it as consuming a byte, which corrupted
    /// RR-interval parsing. Not repeating that mistake here.
    private static func parseHeartRate(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        let flags = bytes[0]
        var idx = 1
        var bpm = 0
        if flags & 0x01 != 0 {
            bpm = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2
        } else {
            bpm = Int(bytes[idx])
            idx += 1
        }
        return bpm
    }
}
