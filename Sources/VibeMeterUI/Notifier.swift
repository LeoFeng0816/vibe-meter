import Foundation
import UserNotifications

/// 系統通知。只有以 .app 形式執行（有 bundle id）時才可用；`swift run` 時改為只記錄。
@MainActor
final class Notifier {
    private var authorized: Bool?

    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func post(id: String, title: String, body: String) {
        guard available else {
            print("[通知] \(title) — \(body)")
            return
        }
        let center = UNUserNotificationCenter.current()
        Task {
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
