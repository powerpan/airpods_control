import Foundation

public struct PrivacySettings: Codable, Sendable, Equatable {
    public var triggerAngle: Double
    public var returnAngle: Double
    public var triggerDelay: TimeInterval
    public var returnDelay: TimeInterval
    public var departureDetectionEnabled: Bool
    /// Losing headphone data while armed raises a shield instead of quietly disarming.
    public var shieldOnDataLossEnabled: Bool

    public init(triggerAngle: Double = 35, returnAngle: Double = 20,
                triggerDelay: TimeInterval = 0.6, returnDelay: TimeInterval = 0.5,
                departureDetectionEnabled: Bool = true, shieldOnDataLossEnabled: Bool = true) {
        self.triggerAngle = triggerAngle
        self.returnAngle = returnAngle
        self.triggerDelay = triggerDelay
        self.returnDelay = returnDelay
        self.departureDetectionEnabled = departureDetectionEnabled
        self.shieldOnDataLossEnabled = shieldOnDataLossEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case triggerAngle, returnAngle, triggerDelay, returnDelay, departureDetectionEnabled, shieldOnDataLossEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(triggerAngle: try values.decodeIfPresent(Double.self, forKey: .triggerAngle) ?? 35,
                  returnAngle: try values.decodeIfPresent(Double.self, forKey: .returnAngle) ?? 20,
                  triggerDelay: try values.decodeIfPresent(Double.self, forKey: .triggerDelay) ?? 0.6,
                  returnDelay: try values.decodeIfPresent(Double.self, forKey: .returnDelay) ?? 0.5,
                  departureDetectionEnabled: try values.decodeIfPresent(Bool.self, forKey: .departureDetectionEnabled) ?? true,
                  shieldOnDataLossEnabled: try values.decodeIfPresent(Bool.self, forKey: .shieldOnDataLossEnabled) ?? true)
    }

    public func sanitized() -> Self {
        let trigger = bounded(triggerAngle, 20...75, fallback: 35)
        return Self(triggerAngle: trigger,
                    returnAngle: bounded(returnAngle, 5...(trigger - 5), fallback: min(20, trigger - 5)),
                    triggerDelay: bounded(triggerDelay, 0.2...3, fallback: 0.6),
                    returnDelay: bounded(returnDelay, 0.3...3, fallback: 0.5),
                    departureDetectionEnabled: departureDetectionEnabled,
                    shieldOnDataLossEnabled: shieldOnDataLossEnabled)
    }
}

public enum PrivacyPhase: String, Sendable, Equatable {
    case disabled, needsCalibration, watching, turningAway, shielded, returning, suspended, waitingForNeutral, departureHeld
}

/// A visual privacy policy. Loss of evidence can never reveal an existing shield.
public struct PrivacyMachine: Sendable, Equatable {
    public private(set) var settings: PrivacySettings
    public private(set) var automaticEnabled = false
    public private(set) var isSuspended = false
    public private(set) var isShielded = false
    public private(set) var requiresManualReveal = false
    public private(set) var isDepartureLatched = false
    public private(set) var phase: PrivacyPhase = .disabled
    public private(set) var progress = 0.0
    public private(set) var status = "自動隱私保護已關閉"
    /// Uptime at which armed protection lost its data and has not yet seen it resume.
    public private(set) var dataLossSince: TimeInterval?
    public static let dataLossGrace: TimeInterval = 1

    private var continuity = PoseContinuity()
    private var candidateStarted: TimeInterval?
    private var needsNeutral = true
    private var hasReference = false
    private var headingUsable = false
    private var dataLossReason: String?

    /// True only while turning away would start the shield countdown: automatic
    /// detection is on and not suspended, nothing is shielded, a reference has
    /// re-armed at neutral, and the latest pose gives a usable heading. The
    /// phase alone cannot say this (a steep pitch keeps `.watching`).
    public var isArmed: Bool {
        automaticEnabled && !isSuspended && !isShielded && hasReference && !needsNeutral && headingUsable
    }

    public init(settings: PrivacySettings = PrivacySettings()) {
        self.settings = settings.sanitized()
    }

    public mutating func updateSettings(_ settings: PrivacySettings) {
        self.settings = settings.sanitized()
        clearCandidate()
        clearDataLoss()
        needsNeutral = true
        refreshInactiveStatus()
    }

    public mutating func setAutomaticEnabled(_ enabled: Bool) {
        guard enabled != automaticEnabled else { return }
        automaticEnabled = enabled
        clearCandidate()
        clearDataLoss()
        needsNeutral = true
        if !enabled, isShielded { requiresManualReveal = true }
        refreshInactiveStatus()
    }

    public mutating func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        clearCandidate()
        clearDataLoss()
        needsNeutral = true
        refreshInactiveStatus()
    }

    public mutating func manualShield() {
        guard !isDepartureLatched else { refreshInactiveStatus(); return }
        isShielded = true
        requiresManualReveal = true
        clearCandidate()
        phase = .shielded
        status = "手動隱私遮擋；請手動解除"
    }

    public mutating func confirmDeparture() {
        guard automaticEnabled, settings.departureDetectionEnabled, !isSuspended else { return }
        isDepartureLatched = true
        isShielded = true
        requiresManualReveal = true
        clearCandidate()
        refreshInactiveStatus()
    }

    public mutating func manualReveal() {
        clearDataLoss()
        isDepartureLatched = false
        isShielded = false
        requiresManualReveal = false
        needsNeutral = true
        clearCandidate()
        refreshInactiveStatus()
    }

    public mutating func invalidatePose(reason: String = "運動數據中斷") {
        clearDataLoss()
        continuity.reset()
        hasReference = false
        headingUsable = false
        needsNeutral = true
        clearCandidate()
        if isDepartureLatched {
            refreshInactiveStatus()
        } else if isShielded {
            requiresManualReveal = true
            phase = .shielded
            status = "\(reason)；遮擋保持，請手動解除"
        } else {
            refreshInactiveStatus()
            if automaticEnabled && !isSuspended { status = "\(reason)；等待有效校準姿態" }
        }
    }

    /// Headphone data stopped arriving (disconnect, case, stream gap, sleep).
    /// While armed this fails closed: protection that cannot see the head
    /// shields instead of silently disarming. A stream gap first gets
    /// `dataLossGrace` to resume, so a Bluetooth hiccup does not demand a
    /// manual reveal; `immediate` is for definitive loss. A normal stop or the
    /// neck exercise must use `invalidatePose` instead.
    public mutating func poseDataLost(reason: String = "運動數據中斷", at uptime: TimeInterval,
                                      immediate: Bool = false) {
        let pending = settings.shieldOnDataLossEnabled && !isShielded && (isArmed || dataLossSince != nil)
        let since = dataLossSince ?? uptime
        let originalReason = dataLossReason ?? reason
        invalidatePose(reason: reason)
        guard pending else { return }
        dataLossSince = since
        dataLossReason = originalReason
        status = "\(reason)；資料未及時恢復將自動遮擋"
        checkDataLoss(at: immediate ? .infinity : uptime)
    }

    /// Raises the pending data-loss shield once the grace has passed without
    /// valid data. Callers poll this; any valid pose cancels the pending loss.
    public mutating func checkDataLoss(at uptime: TimeInterval) {
        guard let since = dataLossSince else { return }
        guard automaticEnabled, !isSuspended, settings.shieldOnDataLossEnabled, !isShielded else {
            clearDataLoss()
            return
        }
        guard uptime - since >= Self.dataLossGrace else { return }
        let reason = dataLossReason ?? "運動數據中斷"
        clearDataLoss()
        isShielded = true
        requiresManualReveal = true
        clearCandidate()
        phase = .shielded
        status = "\(reason)；已自動遮擋，請手動解除"
    }

    public mutating func resetReference() {
        invalidatePose(reason: "參考姿態已改變")
    }

    public mutating func process(_ pose: InteractionPose) {
        // 離座鎖只接受明確手動解除；新姿態、靜止或參考變化均不能揭開。
        if isDepartureLatched { refreshInactiveStatus(); return }
        let result = continuity.observe(pose)
        guard result != .invalid else { invalidatePose(reason: "姿態數據無效"); return }
        clearDataLoss() // valid calibrated data resumed within the grace
        if result == .newReference || result == .interrupted {
            hasReference = true
            needsNeutral = true
            clearCandidate()
            if isShielded {
                requiresManualReveal = true
                phase = .shielded
                status = "姿態連續性改變；遮擋保持，請手動解除"
                return
            }
        }
        hasReference = true
        guard automaticEnabled, !isSuspended else { refreshInactiveStatus(); return }
        if isShielded, requiresManualReveal {
            phase = .shielded
            return
        }
        // Near the pitch singularity yaw ceases to be a useful viewing heading.
        guard abs(pose.pitch) < 75 else {
            headingUsable = false
            clearCandidate()
            if isShielded { phase = .shielded }
            else { phase = .watching }
            status = "當前姿態不適合判斷屏幕朝向"
            return
        }
        headingUsable = true
        let yaw = abs(wrappedDegrees(pose.yaw))
        let neutral = yaw <= settings.returnAngle && abs(pose.pitch) < 45
            && abs(pose.roll) < 45 && pose.angularSpeed <= 15
        if needsNeutral && !isShielded {
            phase = .waitingForNeutral
            status = "回到正視方向並稍作停留後啓用自動檢測"
            if dwell(neutral, at: pose.timestamp, duration: settings.returnDelay) {
                needsNeutral = false
                clearCandidate()
                phase = .watching
                status = "正在留意頭部朝向"
            }
            return
        }
        if isShielded {
            phase = neutral ? .returning : .shielded
            status = neutral ? "正視方向穩定後恢復顯示" : "Privacy Mode"
            if dwell(neutral, at: pose.timestamp, duration: settings.returnDelay) {
                isShielded = false
                phase = .watching
                status = "正在留意頭部朝向"
                clearCandidate()
            }
        } else {
            let away = yaw >= settings.triggerAngle && pose.angularSpeed <= 90
            phase = away ? .turningAway : .watching
            status = away ? "轉頭持續達到設定時間後遮擋" : "正在留意頭部朝向"
            if dwell(away, at: pose.timestamp, duration: settings.triggerDelay) {
                isShielded = true
                requiresManualReveal = false
                phase = .shielded
                status = "Privacy Mode"
                clearCandidate()
            }
        }
    }

    private mutating func dwell(_ condition: Bool, at time: TimeInterval, duration: TimeInterval) -> Bool {
        guard condition else { clearCandidate(); return false }
        if candidateStarted == nil { candidateStarted = time }
        progress = min(1, max(0, (time - (candidateStarted ?? time)) / duration))
        return progress >= 1 - 1e-9
    }

    private mutating func clearCandidate() { candidateStarted = nil; progress = 0 }

    private mutating func clearDataLoss() { dataLossSince = nil; dataLossReason = nil }

    private mutating func refreshInactiveStatus() {
        if isDepartureLatched {
            phase = .departureHeld
            status = "偵測到可能離開書桌，隱私遮擋已保持；請手動解除"
        } else if isShielded {
            phase = .shielded
            if requiresManualReveal { status = "遮擋保持，請手動解除" }
        } else if isSuspended {
            phase = .suspended
            status = "頸部活動期間暫停自動隱私檢測"
        } else if !automaticEnabled {
            phase = .disabled
            status = "自動隱私保護已關閉"
        } else if !hasReference {
            phase = .needsCalibration
            status = "請先正視屏幕並校準"
        } else {
            phase = .waitingForNeutral
            status = "回到正視方向並稍作停留後啓用自動檢測"
        }
    }
}
