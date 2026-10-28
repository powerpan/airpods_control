import Foundation
import InteractionCore

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
