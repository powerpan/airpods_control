import Foundation
import InteractionCore
import UserNotifications

/// Menu-bar summary of automatic privacy protection. "Not armed" is the case a
/// user cannot otherwise see: the toggle is on, but calibration or live data is
/// missing, so turning away would not shield.
enum PrivacyIndicator {
    case off, armed, notArmed, paused, shielded

    var symbol: String {
        switch self {
        case .off: "airpodspro"
        case .armed: "checkmark.shield"
        case .notArmed: "exclamationmark.shield"
        case .paused: "pause.circle"
        case .shielded: "eye.slash.fill"
        }
    }

    var title: String {
        switch self {
        case .off: "自動隱私保護已關閉"
        case .armed: "自動隱私保護已就緒"
        case .notArmed: "自動隱私保護未就緒，請校準"
        case .paused: "頸部活動期間暫停自動隱私保護"
        case .shielded: "隱私遮擋中"
        }
    }
}

extension InteractionStore {
    var privacyIndicator: PrivacyIndicator {
        if snapshot.privacy.isShielded { return .shielded }
        guard privacyEnabled else { return .off }
        if snapshot.automaticSuspended { return .paused }
        return snapshot.privacy.isArmed && snapshot.sensorReady ? .armed : .notArmed
    }
}

extension PrivacyIndicator {
    var alertObservation: DisarmAlertPolicy.Observation {
        switch self {
        case .off: .off
        case .armed: .armed
        case .notArmed: .notArmed
        case .paused, .shielded: .held
        }
    }
}

/// Posts a local notification when protection drops from armed to "on but not
/// armed" and stays there, so a lost calibration is never silent. Permission
/// is requested the first time protection is armed, not at launch.
@MainActor
final class DisarmNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var policy = DisarmAlertPolicy()
    private var authorizationRequested = false

    func observe(_ indicator: PrivacyIndicator, status: String) {
        if indicator == .armed { requestAuthorizationOnce() }
        guard policy.observe(indicator.alertObservation, at: ProcessInfo.processInfo.systemUptime) else { return }
        let content = UNMutableNotificationContent()
        content.title = "自動隱私保護未就緒"
        content.body = "轉頭目前不會觸發遮擋。請確認耳機已佩戴並連接，再重新校準。（\(status)）"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "privacy.not-armed", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func requestAuthorizationOnce() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Show the banner even while one of the app's windows is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
