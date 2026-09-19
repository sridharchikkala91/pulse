import Foundation
import CoreBluetooth

/// Phase 1 scope only: connect, complete the WHOOP 5.0 handshake, read
/// battery, read standard live heart rate. Historical offload (Phase 3) and
/// full sensor decoding are intentionally NOT implemented here — see
/// docs/WHOOP5_LIMITATIONS.md and the project's phased development order.
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

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdWriteCharacteristic: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func log(_ s: String) {
        DispatchQueue.main.async {
            self.lastLog = s
        }
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
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    private func sendCommand(_ cmd: UInt8, _ payload: [UInt8]) {
        guard let c = cmdWriteCharacteristic, let p = peripheral else { return }
        let frame = WhoopProtocol.encodeCommand(cmd, payload)
        p.writeValue(Data(frame), for: c, type: .withResponse)
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
                // Kick off the handshake as soon as the write characteristic is ready.
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
            return
        }
        guard decoded.crc16Valid, decoded.crc32Valid else {
            packetsRejected += 1
            return
        }

        if decoded.type == 36, decoded.cmd == 0x91 { // COMMAND_RESPONSE to GET_HELLO
            packetsDecoded += 1
            handshakeState = "SUCCESS"
            // Now that the handshake is confirmed, ask for battery.
            sendCommand(26, [0x00]) // GET_BATTERY_LEVEL
        } else if decoded.type == 36, decoded.cmd == 26, decoded.payload.count >= 4 { // GET_BATTERY_LEVEL response
            packetsDecoded += 1
            let raw = UInt16(decoded.payload[2]) | (UInt16(decoded.payload[3]) << 8)
            batteryPercent = Double(raw) / 10
        } else {
            packetsUnknown += 1
        }
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
