import Foundation
import UserNotifications

/// Phase 43: local notifications. Deliberately limited to the operational
/// events the master prompt lists as reasonable (connected, sync
/// complete, sync failed, low battery, baseline deviation) — explicitly
/// NOT medical alerts, per that same section's instruction.
enum WhoopNotifications {

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func notifySyncComplete(nightsCount: Int, recordsCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "WHOOP sync complete"
        content.body = nightsCount > 0
            ? "Synced \(nightsCount) night(s) from \(recordsCount) records."
            : "Sync finished — no new sleep sessions found in \(recordsCount) records."
        schedule(content, identifier: "sync-complete")
    }

    static func notifySyncFailed(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "WHOOP sync incomplete"
        content.body = reason
        schedule(content, identifier: "sync-failed")
    }

    static func notifyLowBattery(percent: Double) {
        let content = UNMutableNotificationContent()
        content.title = "WHOOP strap battery low"
        content.body = String(format: "%.0f%% remaining — charge it soon.", percent)
        schedule(content, identifier: "low-battery")
    }

    static func notifyWhoopConnected(deviceName: String) {
        let content = UNMutableNotificationContent()
        content.title = "WHOOP connected"
        content.body = "\(deviceName) is connected."
        schedule(content, identifier: "whoop-connected")
    }

    private static func schedule(_ content: UNMutableNotificationContent, identifier: String) {
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil) // fire immediately
        UNUserNotificationCenter.current().add(request)
    }
}
