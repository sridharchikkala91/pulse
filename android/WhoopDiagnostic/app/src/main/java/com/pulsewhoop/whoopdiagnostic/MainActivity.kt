package com.pulsewhoop.whoopdiagnostic

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

class MainActivity : ComponentActivity() {

    private val requiredPermissions: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val ble = WhoopBleManager(applicationContext)

        setContent {
            var permissionsGranted by remember { mutableStateOf(false) }
            val launcher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestMultiplePermissions()
            ) { results -> permissionsGranted = results.values.all { it } }

            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    DiagnosticScreen(
                        ble = ble,
                        permissionsGranted = permissionsGranted,
                        onRequestPermissions = { launcher.launch(requiredPermissions) }
                    )
                }
            }
        }
    }
}

@Composable
fun DiagnosticScreen(ble: WhoopBleManager, permissionsGranted: Boolean, onRequestPermissions: () -> Unit) {
    val whoopFound by ble.whoopFound
    val connectionState by ble.connectionState
    val handshakeState by ble.handshakeState
    val battery by ble.batteryPercent
    val deviceName by ble.deviceName
    val firmware by ble.firmwareInfo
    val hr by ble.liveHeartRateBpm
    val received by ble.packetsReceived
    val decoded by ble.packetsDecoded
    val rejected by ble.packetsRejected
    val unknown by ble.packetsUnknown
    val lastLog by ble.lastLog

    val rows = listOf(
        "WHOOP" to if (whoopFound) "FOUND" else "NOT FOUND",
        "Connection" to connectionState,
        "Handshake" to handshakeState,
        "Device" to (deviceName ?: "--"),
        "Battery" to (battery?.let { "%.1f%%".format(it) } ?: "--"),
        "Firmware" to firmware,
        "HR" to (hr?.let { "$it bpm" } ?: "--"),
        "RR" to "Not available in Phase 2 — needs RR-interval parsing from the HR characteristic",
        "Packets received" to "$received",
        "Packets decoded" to "$decoded",
        "Packets rejected" to "$rejected",
        "Packets unknown" to "$unknown"
    )

    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("WHOOP 5.0 Diagnostic", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(16.dp))

        if (!permissionsGranted) {
            Button(onClick = onRequestPermissions) { Text("Grant Bluetooth Permissions") }
            Spacer(Modifier.height(16.dp))
        }

        LazyColumn(Modifier.weight(1f)) {
            items(rows) { (label, value) ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 6.dp),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text(label)
                    Text(value, textAlign = androidx.compose.ui.text.style.TextAlign.End, modifier = Modifier.weight(1f, fill = false))
                }
            }
            if (lastLog.isNotEmpty()) {
                item {
                    Spacer(Modifier.height(8.dp))
                    Text("Last log: $lastLog", style = MaterialTheme.typography.bodySmall)
                }
            }
        }

        Button(
            onClick = { if (connectionState == "DISCONNECTED") ble.startScan() else ble.disconnect() },
            enabled = permissionsGranted,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(if (connectionState == "DISCONNECTED") "Scan & Connect" else "Disconnect")
        }
    }
}
