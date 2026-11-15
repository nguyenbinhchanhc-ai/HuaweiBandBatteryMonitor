import Foundation
import UserNotifications

/// Manages local notifications for full-charge reminders and low-battery warnings,
/// deduplicated per battery session to avoid repetitive alerts.
final class NotificationManager {
    static let shared = NotificationManager()

    private var notifiedChargeSessions: Set<UUID> = []
    private var notifiedLowSessions: Set<UUID> = []

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func sendChargeTargetAlertIfNeeded(sessionID: UUID, level: Int, target: Int) {
        guard !notifiedChargeSessions.contains(sessionID) else { return }
        notifiedChargeSessions.insert(sessionID)

        let title = level >= 100 ? "Huawei Band 11 đã sạc đầy 100%" : "Huawei Band 11 đã đạt \(level)%"
        let body = "Bạn có thể rút đế sạc nam châm (ngưỡng nhắc: \(target)%)."
        scheduleImmediate(identifier: "charge-\(sessionID.uuidString)", title: title, body: body)
    }

    func sendLowBatteryAlertIfNeeded(sessionID: UUID, level: Int) {
        guard !notifiedLowSessions.contains(sessionID) else { return }
        notifiedLowSessions.insert(sessionID)

        let title = "Pin Huawei Band 11 còn \(level)%"
        let body = "Sắp hết pin — hãy chuẩn bị sạc cho vòng đeo tay."
        scheduleImmediate(identifier: "low-\(sessionID.uuidString)", title: title, body: body)
    }

    private func scheduleImmediate(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
