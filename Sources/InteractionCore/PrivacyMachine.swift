import Foundation

public struct PrivacySettings: Codable, Sendable, Equatable {
    public var triggerAngle: Double
    public var returnAngle: Double
    public var triggerDelay: TimeInterval
    public var returnDelay: TimeInterval

    public init(triggerAngle: Double = 35, returnAngle: Double = 20,
                triggerDelay: TimeInterval = 0.6, returnDelay: TimeInterval = 0.5) {
        self.triggerAngle = triggerAngle
        self.returnAngle = returnAngle
        self.triggerDelay = triggerDelay
        self.returnDelay = returnDelay
    }

    public func sanitized() -> Self {
        let trigger = bounded(triggerAngle, 20...75, fallback: 35)
        return Self(triggerAngle: trigger,
                    returnAngle: bounded(returnAngle, 5...(trigger - 5), fallback: min(20, trigger - 5)),
                    triggerDelay: bounded(triggerDelay, 0.2...3, fallback: 0.6),
                    returnDelay: bounded(returnDelay, 0.3...3, fallback: 0.5))
    }
}

public enum PrivacyPhase: String, Sendable, Equatable {
    case disabled, needsCalibration, watching, turningAway, shielded, returning, suspended, waitingForNeutral
}

/// A visual privacy policy. Loss of evidence can never reveal an existing shield.
public struct PrivacyMachine: Sendable, Equatable {
    public private(set) var settings: PrivacySettings
    public private(set) var automaticEnabled = false
    public private(set) var isSuspended = false
    public private(set) var isShielded = false
    public private(set) var requiresManualReveal = false
    public private(set) var phase: PrivacyPhase = .disabled
    public private(set) var progress = 0.0
    public private(set) var status = "自动隐私保护已关闭"

    private var continuity = PoseContinuity()
    private var candidateStarted: TimeInterval?
    private var needsNeutral = true
    private var hasReference = false

    public init(settings: PrivacySettings = PrivacySettings()) {
        self.settings = settings.sanitized()
    }

    public mutating func updateSettings(_ settings: PrivacySettings) {
        self.settings = settings.sanitized()
        clearCandidate()
        needsNeutral = true
        refreshInactiveStatus()
    }

    public mutating func setAutomaticEnabled(_ enabled: Bool) {
        guard enabled != automaticEnabled else { return }
        automaticEnabled = enabled
        clearCandidate()
        needsNeutral = true
        if !enabled, isShielded { requiresManualReveal = true }
        refreshInactiveStatus()
    }

    public mutating func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        clearCandidate()
        needsNeutral = true
        refreshInactiveStatus()
    }

    public mutating func manualShield() {
        isShielded = true
        requiresManualReveal = true
        clearCandidate()
        phase = .shielded
        status = "手动隐私遮挡；请手动解除"
    }

    public mutating func manualReveal() {
        isShielded = false
        requiresManualReveal = false
        needsNeutral = true
        clearCandidate()
        refreshInactiveStatus()
    }

    public mutating func invalidatePose(reason: String = "运动数据中断") {
        continuity.reset()
        hasReference = false
        needsNeutral = true
        clearCandidate()
        if isShielded {
            requiresManualReveal = true
            phase = .shielded
            status = "\(reason)；遮挡保持，请手动解除"
        } else {
            refreshInactiveStatus()
            if automaticEnabled && !isSuspended { status = "\(reason)；等待有效校准姿态" }
        }
    }

    public mutating func resetReference() {
        invalidatePose(reason: "参考姿态已改变")
    }

    public mutating func process(_ pose: InteractionPose) {
        let result = continuity.observe(pose)
        guard result != .invalid else { invalidatePose(reason: "姿态数据无效"); return }
        if result == .newReference || result == .interrupted {
            hasReference = true
            needsNeutral = true
            clearCandidate()
            if isShielded {
                requiresManualReveal = true
                phase = .shielded
                status = "姿态连续性改变；遮挡保持，请手动解除"
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
            clearCandidate()
            if isShielded { phase = .shielded }
            else { phase = .watching }
            status = "当前姿态不适合判断屏幕朝向"
            return
        }
        let yaw = abs(wrappedDegrees(pose.yaw))
        let neutral = yaw <= settings.returnAngle && abs(pose.pitch) < 45
            && abs(pose.roll) < 45 && pose.angularSpeed <= 15
        if needsNeutral && !isShielded {
            phase = .waitingForNeutral
            status = "回到正视方向并稍作停留后启用自动检测"
            if dwell(neutral, at: pose.timestamp, duration: settings.returnDelay) {
                needsNeutral = false
                clearCandidate()
                phase = .watching
                status = "正在留意头部朝向"
            }
            return
        }
        if isShielded {
            phase = neutral ? .returning : .shielded
            status = neutral ? "正视方向稳定后恢复显示" : "Privacy Mode"
            if dwell(neutral, at: pose.timestamp, duration: settings.returnDelay) {
                isShielded = false
                phase = .watching
                status = "正在留意头部朝向"
                clearCandidate()
            }
        } else {
            let away = yaw >= settings.triggerAngle && pose.angularSpeed <= 90
            phase = away ? .turningAway : .watching
            status = away ? "转头持续达到设定时间后遮挡" : "正在留意头部朝向"
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

    private mutating func refreshInactiveStatus() {
        if isShielded {
            phase = .shielded
            if requiresManualReveal { status = "遮挡保持，请手动解除" }
        } else if isSuspended {
            phase = .suspended
            status = "颈部活动期间暂停自动隐私检测"
        } else if !automaticEnabled {
            phase = .disabled
            status = "自动隐私保护已关闭"
        } else if !hasReference {
            phase = .needsCalibration
            status = "请先正视屏幕并校准"
        } else {
            phase = .waitingForNeutral
            status = "回到正视方向并稍作停留后启用自动检测"
        }
    }
}
