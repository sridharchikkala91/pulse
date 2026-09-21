package com.pulsewhoop.whoopdiagnostic

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import java.util.UUID

/**
 * Phase 2 scope only (mirrors iOS Phase 1 exactly): connect, complete the
 * WHOOP 5.0 handshake, read battery, read standard live heart rate.
 * Historical offload/full sensor decoding are NOT implemented here yet —
 * see docs/WHOOP5_LIMITATIONS.md.
 */
@SuppressLint("MissingPermission") // permission checks are done by the caller (MainActivity) before any method here is invoked
class WhoopBleManager(private val context: Context) {

    companion object {
        val HEART_RATE_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val HEART_RATE_MEASUREMENT: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        val PROPRIETARY_SERVICE: UUID = UUID.fromString("fd4b0001-cce1-4033-93ce-002d5875f58a")
        val CMD_WRITE_CHAR: UUID = UUID.fromString("fd4b0002-cce1-4033-93ce-002d5875f58a")
        val CMD_RESPONSE_CHAR: UUID = UUID.fromString("fd4b0003-cce1-4033-93ce-002d5875f58a")
        val EVENTS_CHAR: UUID = UUID.fromString("fd4b0004-cce1-4033-93ce-002d5875f58a")
        val DATA_CHAR: UUID = UUID.fromString("fd4b0005-cce1-4033-93ce-002d5875f58a")
        val MEMFAULT_CHAR: UUID = UUID.fromString("fd4b0007-cce1-4033-93ce-002d5875f58a")
        val CLIENT_CHARACTERISTIC_CONFIG: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    // ---- Observable diagnostic state (Compose reads these directly) ----
    val whoopFound = mutableStateOf(false)
    val connectionState = mutableStateOf("DISCONNECTED")
    val handshakeState = mutableStateOf("NOT ATTEMPTED")
    val batteryPercent = mutableStateOf<Double?>(null)
    val deviceName = mutableStateOf<String?>(null)
    val firmwareInfo = mutableStateOf(
        "Not available (REPORT_VERSION_INFO gets no response on this firmware — see docs/WHOOP5_LIMITATIONS.md)"
    )
    val liveHeartRateBpm = mutableStateOf<Int?>(null)
    val packetsReceived = mutableStateOf(0)
    val packetsDecoded = mutableStateOf(0)
    val packetsRejected = mutableStateOf(0)
    val packetsUnknown = mutableStateOf(0)
    val lastLog = mutableStateOf("")
    val log: SnapshotStateList<String> = SnapshotStateList()

    private var bluetoothGatt: BluetoothGatt? = null
    private var cmdWriteCharacteristic: BluetoothGattCharacteristic? = null

    private fun logLine(s: String) {
        lastLog.value = s
    }

    private val bluetoothAdapter: BluetoothAdapter?
        get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            bluetoothAdapter?.bluetoothLeScanner?.stopScan(this)
            whoopFound.value = true
            deviceName.value = result.device.name
            connectionState.value = "CONNECTING"
            bluetoothGatt = result.device.connectGatt(context, false, gattCallback)
        }

        override fun onScanFailed(errorCode: Int) {
            logLine("Scan failed: error $errorCode")
        }
    }

    fun startScan() {
        val scanner = bluetoothAdapter?.bluetoothLeScanner
        if (scanner == null) {
            logLine("Cannot scan — Bluetooth adapter/scanner unavailable")
            return
        }
        connectionState.value = "SCANNING"
        val filter = ScanFilter.Builder().setServiceUuid(android.os.ParcelUuid(HEART_RATE_SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(filter), settings, scanCallback)
    }

    fun disconnect() {
        bluetoothGatt?.disconnect()
    }

    private fun sendCommand(cmd: Int, payload: List<Int>) {
        val characteristic = cmdWriteCharacteristic ?: return
        val frame = WhoopProtocol.encodeCommand(cmd, payload)
        writeBytes(characteristic, frame)
    }

    private fun writeBytes(characteristic: BluetoothGattCharacteristic, bytes: List<Int>) {
        val byteArray = ByteArray(bytes.size) { bytes[it].toByte() }
        val gatt = bluetoothGatt ?: return
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(characteristic, byteArray, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
        } else {
            @Suppress("DEPRECATION")
            characteristic.value = byteArray
            @Suppress("DEPRECATION")
            gatt.writeCharacteristic(characteristic)
        }
    }

    private fun enableNotifications(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        gatt.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(CLIENT_CHARACTERISTIC_CONFIG) ?: return
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(descriptor)
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectionState.value = "CONNECTED"
                gatt.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                connectionState.value = "DISCONNECTED"
                handshakeState.value = "NOT ATTEMPTED"
                cmdWriteCharacteristic = null
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            gatt.getService(HEART_RATE_SERVICE)?.getCharacteristic(HEART_RATE_MEASUREMENT)?.let {
                enableNotifications(gatt, it)
            }
            gatt.getService(PROPRIETARY_SERVICE)?.let { service ->
                listOf(CMD_RESPONSE_CHAR, EVENTS_CHAR, DATA_CHAR, MEMFAULT_CHAR).forEach { uuid ->
                    service.getCharacteristic(uuid)?.let { enableNotifications(gatt, it) }
                }
                service.getCharacteristic(CMD_WRITE_CHAR)?.let { characteristic ->
                    cmdWriteCharacteristic = characteristic
                    handshakeState.value = "IN PROGRESS"
                    writeBytes(characteristic, WhoopProtocol.CLIENT_HELLO)
                }
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            handleCharacteristicUpdate(characteristic.uuid, value)
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            // Called instead of the 3-arg overload on API < 33.
            characteristic.value?.let { handleCharacteristicUpdate(characteristic.uuid, it) }
        }
    }

    private fun handleCharacteristicUpdate(uuid: UUID, value: ByteArray) {
        val bytes = value.map { it.toInt() and 0xFF }

        if (uuid == HEART_RATE_MEASUREMENT) {
            liveHeartRateBpm.value = parseHeartRate(bytes)
            return
        }

        packetsReceived.value++
        val decoded = WhoopProtocol.decodeFrame(bytes)
        if (decoded == null) {
            packetsRejected.value++
            return
        }
        if (!decoded.crc16Valid || !decoded.crc32Valid) {
            packetsRejected.value++
            return
        }

        when {
            decoded.type == 36 && decoded.cmd == 0x91 -> { // COMMAND_RESPONSE to GET_HELLO
                packetsDecoded.value++
                handshakeState.value = "SUCCESS"
                sendCommand(26, listOf(0x00)) // GET_BATTERY_LEVEL
            }
            decoded.type == 36 && decoded.cmd == 26 && decoded.payload.size >= 4 -> { // GET_BATTERY_LEVEL response
                packetsDecoded.value++
                val raw = decoded.payload[2] or (decoded.payload[3] shl 8)
                batteryPercent.value = raw / 10.0
            }
            else -> packetsUnknown.value++
        }
    }

    /** Standard Bluetooth Heart Rate Measurement (0x2A37) parser. NOTE: bit
     *  2 (0x04, Sensor Contact Status) is a status-only flag and consumes
     *  zero payload bytes — a bug in this project's own earlier JS
     *  implementation treated it as consuming a byte, which corrupted
     *  RR-interval parsing. Not repeating that mistake here. */
    private fun parseHeartRate(bytes: List<Int>): Int {
        val flags = bytes[0]
        return if (flags and 0x01 != 0) {
            bytes[1] or (bytes[2] shl 8)
        } else {
            bytes[1]
        }
    }
}
