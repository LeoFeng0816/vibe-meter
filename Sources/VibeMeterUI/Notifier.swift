import Foundation
import UserNotifications

/// 每次發送前讀取目前授權。系統接受通知後才回報成功。
@MainActor
final class Notifier {
    typealias ReadStatus = @MainActor () async -> NotificationStatus
    typealias Deliver = @MainActor (String, String, String) async throws -> Void

    private let readStatus: ReadStatus
    private let deliver: Deliver

    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    init(readStatus: ReadStatus? = nil, deliver: Deliver? = nil) {
        self.readStatus = readStatus ?? {
            guard Self.available else { return .unavailable }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return switch settings.authorizationStatus {
            case .authorized, .ephemeral: .authorized
            case .provisional: .provisional
            case .denied: .denied
            case .notDetermined: .notDetermined
            @unknown default: .unknown
            }
        }
        self.deliver = deliver ?? { id, title, body in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    func status() async -> NotificationStatus { await readStatus() }

    func post(id: String, title: String, body: String, stillAllowed: @MainActor () -> Bool) async -> Bool {
        let status = await readStatus()
        guard (status == .authorized || status == .provisional), stillAllowed() else { return false }
        do {
            try await deliver(id, title, body)
            return true
        } catch {
            return false
        }
    }
}
