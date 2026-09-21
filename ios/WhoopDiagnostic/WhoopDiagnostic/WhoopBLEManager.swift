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

    // MARK: - Manual workout tracking (Phase 19)

    @Published var isWorkoutActive: Bool = false
    @Published var workoutSampleCount: Int = 0
    private var workoutHRSamples: [Double] = []
    private var workoutStart: Date?

    func startWorkout() {
        isWorkoutActive = true
        workoutHRSamples = []
        workoutSampleCount = 0
        workoutStart = Date()
    }

    /// Ends the workout, computes strain from the HR samples collected
    /// during it (WhoopAnalytics.strainScore — OUR_ALGORITHM, not
    /// WHOOP's real number), and saves a WorkoutRecord.
    func endWorkout(activityType: String, restingHeartRate: Double?, age: Double?) {
        guard let start = workoutStart else { return }
        isWorkoutActive = false
        let end = Date()
        let record = WorkoutRecord(activityType: activityType, startTimestamp: start, endTimestamp: end)
        record.averageHeartRate = workoutHRSamples.isEmpty ? nil : workoutHRSamples.reduce(0, +) / Double(workoutHRSamples.count)
        record.maxHeartRate = workoutHRSamples.max()
        let maxHr = WhoopAnalytics.estimateMaxHeartRate(age: age)
        record.strainOurs = WhoopAnalytics.strainScore(
            heartRateSamples: workoutHRSamples, restingHeartRate: restingHeartRate, maxHeartRate: maxHr
        )
        if let context = modelContext {
            context.insert(record)
            try? context.save()
        }
        workoutStart = nil
        workoutHRSamples = []
        workoutSampleCount = 0
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdWriteCharacteristic: CBCharacteristic?

    private var isSyncing = false
    private var syncReconnectAttempts = 0
    private let maxSyncReconnectAttempts = 30
    private var historicalSamples: [WhoopProtocol.HistorySample] = []

    // MARK: - Automatic reconnection (Phase 7/13)

    /// UserDefaults key for the last-connected peripheral's identifier, so
    /// a later launch (including a background relaunch triggered by
    /// CBCentralManagerOptionRestoreIdentifierKey) can find the SAME
    /// strap again via retrievePeripherals(withIdentifiers:) without a
    /// fresh scan+picker.
    private static let lastPeripheralIDKey = "WhoopBLEManager.lastPeripheralID"
    /// A fixed restoration identifier lets iOS relaunch this app in the
    /// background to handle BLE events (e.g. the strap reconnecting) even
    /// after the app was fully terminated by the system — the actual
    /// mechanism behind "the phone doesn't need to be with the user all
    /// day" (master prompt section 2). NOT the same as surviving a
    /// user-initiated force-quit; iOS does not restore apps the user
    /// explicitly killed, only ones the SYSTEM terminated for resources.
    private static let restorationIdentifier = "com.pulsewhoop.WhoopDiagnostic.centralManager"

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier]
        )
    }

    /// Tries to reconnect to whichever peripheral we connected to last
    /// time, without a fresh scan or device picker. Call once Bluetooth is
    /// confirmed powered on. Falls through silently (does nothing) if no
    /// peripheral was ever connected before, or it's no longer known to
    /// the system (e.g. unpaired) — startScan() remains the fallback.
    func tryAutoReconnect() {
        guard central.state == .poweredOn else { return }
        guard let idString = UserDefaults.standard.string(forKey: Self.lastPeripheralIDKey),
              let id = UUID(uuidString: idString) else { return }
        let known = central.retrievePeripherals(withIdentifiers: [id])
        guard let found = known.first else { return }
        peripheral = found
        whoopFound = true
        deviceName = found.name
        connectionState = "CONNECTING"
        central.connect(found, options: nil)
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
        samplesSavedUpTo = 0
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

    /// How many NEW samples accumulate before we checkpoint-save, so a
    /// mid-sync kill (backgrounding suspension, crash, user force-quit)
    /// loses at most one checkpoint's worth of data instead of the entire
    /// run. A real run lost 60,000+ decoded records this way before this
    /// fix existed — see docs/WHOOP5_LIMITATIONS.md.
    private let checkpointInterval = 2000
    private var samplesSavedUpTo = 0

    /// Extracts sleep sessions from ALL samples accumulated so far (not
    /// just the ones since the last checkpoint — extractSleepSessions
    /// needs full context to merge across gaps correctly) and saves/
    /// updates the resulting SleepSessionRecord rows. Safe to call
    /// repeatedly and mid-sync: SwiftData upserts by re-inserting, and a
    /// later checkpoint with more data simply produces longer/more
    /// accurate sessions for the same dates.
    @discardableResult
    private func persistCurrentSamples() -> Int {
        guard let context = modelContext else {
            log("No ModelContext set — sync results were NOT persisted")
            return 0
        }
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
        for (dateKey, info) in byDate {
            let record = SleepSessionRecord(
                dateKey: dateKey, startTimestamp: Int(info.start), endTimestamp: Int(info.end),
                durationHours: info.durationHours, averageSkinTempC: info.avgTemp, source: "synced"
            )
            context.insert(record)
        }
        try? context.save()
        samplesSavedUpTo = historicalSamples.count
        return byDate.count
    }

    private func checkpointIfDue() {
        guard historicalSamples.count - samplesSavedUpTo >= checkpointInterval else { return }
        let saved = persistCurrentSamples()
        recordsStoredTotal = saved
        syncStatus = "Draining history... \(syncRecordsThisRun) records so far (checkpoint saved, \(saved) night(s) so far)"
    }

    private func finishSync(reason: String) {
        guard isSyncing else { return }
        isSyncing = false
        syncStatus = "Processing \(historicalSamples.count) records..."

        let nightsCount = persistCurrentSamples()
        recordsStoredTotal = nightsCount
        lastSyncDate = Date()
        let suffix = reason == "complete" ? " — fully caught up!" : " — stopped after \(syncReconnectAttempts) reconnect attempts, run Sync again to continue"
        if nightsCount == 0 {
            syncStatus = "Sync finished: no qualifying sleep sessions in \(historicalSamples.count) records\(suffix)"
        } else {
            syncStatus = "Synced \(nightsCount) night(s) from \(historicalSamples.count) records\(suffix)"
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
        case .poweredOn:
            bluetoothState = "ON"
            if connectionState == "DISCONNECTED" { tryAutoReconnect() }
        case .poweredOff: bluetoothState = "OFF"
        case .unauthorized: bluetoothState = "UNAUTHORIZED"
        case .unsupported: bluetoothState = "UNSUPPORTED"
        case .resetting: bluetoothState = "RESETTING"
        default: bluetoothState = "UNKNOWN"
        }
    }

    /// Called when iOS relaunches this app in the background to hand back
    /// a CBCentralManager whose scan/connections were still active at
    /// termination — the actual mechanism for surviving the app being
    /// killed by the SYSTEM (not a user force-quit) while still connected
    /// or reconnecting to the strap.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            peripheral = restored
            restored.delegate = self
            deviceName = restored.name
            whoopFound = true
            connectionState = restored.state == .connected ? "CONNECTED" : "CONNECTING"
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
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralIDKey)
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
            let bpm = Self.parseHeartRate(data)
            liveHeartRateBPM = bpm
            if isWorkoutActive {
                workoutHRSamples.append(Double(bpm))
                workoutSampleCount = workoutHRSamples.count
            }
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
                checkpointIfDue()
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
