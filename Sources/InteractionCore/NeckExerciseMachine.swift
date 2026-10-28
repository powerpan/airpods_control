import Foundation

public struct NeckExerciseSettings: Codable, Sendable, Equatable {
    public var yawAngle: Double
    public var tiltAngle: Double
    public var nodAngle: Double
    public var stableHold: TimeInterval
    public var returnHold: TimeInterval
    public var yawSign: Double
    public var pitchSign: Double
    public var rollSign: Double

    // Local AirPods Pro 2 feedback: left turn uses positive relative yaw, low
    // nod uses negative pitch, and tilt keeps the original sign. All are adjustable.
    public init(yawAngle: Double = 20, tiltAngle: Double = 12, nodAngle: Double = 10,
                stableHold: TimeInterval = 0.6, returnHold: TimeInterval = 0.5,
                yawSign: Double = -1, pitchSign: Double = -1, rollSign: Double = 1) {
        self.yawAngle = yawAngle
        self.tiltAngle = tiltAngle
        self.nodAngle = nodAngle
        self.stableHold = stableHold
        self.returnHold = returnHold
        self.yawSign = yawSign
        self.pitchSign = pitchSign
        self.rollSign = rollSign
    }

    public func sanitized() -> Self {
        Self(yawAngle: bounded(yawAngle, 10...35, fallback: 20),
             tiltAngle: bounded(tiltAngle, 5...20, fallback: 12),
             nodAngle: bounded(nodAngle, 5...20, fallback: 10),
             stableHold: bounded(stableHold, 0.3...2, fallback: 0.6),
             returnHold: bounded(returnHold, 0.3...2, fallback: 0.5),
             yawSign: yawSign < 0 ? -1 : 1,
             pitchSign: pitchSign < 0 ? -1 : 1,
             rollSign: rollSign < 0 ? -1 : 1)
    }
}

public enum ExercisePhase: String, Sendable, Equatable {
    case idle, awaitingCalibration, approaching, returning, paused, signalLost, completed
}

public enum ExerciseStep: String, CaseIterable, Sendable, Equatable {
    case turnLeft, turnRight, tiltLeft, tiltRight, nod

    public var title: String {
        switch self {
        case .turnLeft: "向左看"
        case .turnRight: "向右看"
        case .tiltLeft: "輕輕向左側傾"
        case .tiltRight: "輕輕向右側傾"
        case .nod: "緩慢低頭"
        }
    }

    public var instruction: String {
        switch self {
        case .turnLeft: "跟隨模型，緩慢向左轉頭。超過設定幅度後舒適地保持。"
        case .turnRight: "跟隨模型，緩慢向右轉頭。超過設定幅度後舒適地保持。"
        case .tiltLeft: "跟隨模型，輕輕向左側傾。超過設定幅度後保持，不聳肩。"
        case .tiltRight: "跟隨模型，輕輕向右側傾。超過設定幅度後保持，不聳肩。"
        case .nod: "跟隨模型緩慢低頭，超過設定幅度後保持；不做後仰或繞圈動作。"
        }
    }
}

public struct ExerciseTarget: Sendable, Equatable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.yaw = yaw; self.pitch = pitch; self.roll = roll
    }
}

/// A small activity guide, not an assessment of health, mobility, or technique.
/// A step completes after continuously exceeding its directional amplitude
/// threshold AND returning to neutral. There is no point-matching tolerance.
public struct NeckExerciseMachine: Sendable, Equatable {
    public private(set) var settings: NeckExerciseSettings
    public private(set) var phase: ExercisePhase = .idle
    public private(set) var stepIndex = 0
    public private(set) var completedCount = 0
    public private(set) var skippedCount = 0
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var progress = 0.0
    public private(set) var currentPose: InteractionPose?
    public private(set) var status = "按舒適範圍做一段輕緩活動"

    private var referenceID: UUID?
    private var continuity = PoseContinuity()
    private var candidateStarted: TimeInterval?
    private var phaseBeforePause: ExercisePhase = .approaching
    private var freshSinceLoss = false

    public init(settings: NeckExerciseSettings = NeckExerciseSettings()) {
        self.settings = settings.sanitized()
    }

    public var isActive: Bool { phase != .idle && phase != .completed }
    public var currentStep: ExerciseStep? {
        guard ExerciseStep.allCases.indices.contains(stepIndex) else { return nil }
        return ExerciseStep.allCases[stepIndex]
    }

    public var target: ExerciseTarget {
        if phase == .returning || (phase == .paused && phaseBeforePause == .returning) { return ExerciseTarget() }
        guard let step = currentStep else { return ExerciseTarget() }
        switch step {
        case .turnLeft: return ExerciseTarget(yaw: -settings.yawAngle * settings.yawSign)
        case .turnRight: return ExerciseTarget(yaw: settings.yawAngle * settings.yawSign)
        case .tiltLeft: return ExerciseTarget(roll: -settings.tiltAngle * settings.rollSign)
        case .tiltRight: return ExerciseTarget(roll: settings.tiltAngle * settings.rollSign)
        case .nod: return ExerciseTarget(pitch: settings.nodAngle * settings.pitchSign)
        }
    }

    public mutating func updateSettings(_ settings: NeckExerciseSettings) {
        self.settings = settings.sanitized()
        clearCandidate()
        if isActive {
            referenceID = nil
            continuity.reset()
            phase = .awaitingCalibration
            status = "參數已更新，請重新正視並校準"
        }
    }

    public mutating func start(at time: TimeInterval) {
        _ = time // All durations use observed sample intervals, never wall-clock completion.
        stepIndex = 0
        completedCount = 0
        skippedCount = 0
        elapsed = 0
        referenceID = nil
        continuity.reset()
        freshSinceLoss = false
        clearCandidate()
        phase = .awaitingCalibration
        status = "舒適坐好，正視屏幕後校準"
    }

    public mutating func calibrate(referenceID: UUID) {
        guard isActive else { return }
        self.referenceID = referenceID
        continuity.reset()
        clearCandidate()
        freshSinceLoss = false
        phaseBeforePause = .approaching
        if phase != .paused { phase = .approaching }
        status = phase == .paused ? "已校準，繼續後重新靠近當前目標" : (currentStep?.instruction ?? "")
    }

    public mutating func pause() {
        guard phase == .approaching || phase == .returning || phase == .awaitingCalibration else { return }
        phaseBeforePause = phase
        phase = .paused
        clearCandidate()
        continuity.reset()
        status = "已暫停，按自己的節奏繼續"
    }

    public mutating func resume() {
        if phase == .paused {
            phase = referenceID == nil ? .awaitingCalibration : phaseBeforePause
            if phase == .paused || phase == .signalLost { phase = .approaching }
        } else if phase == .signalLost {
            guard freshSinceLoss, referenceID != nil else {
                status = "等待有效數據；參考改變時請重新校準"
                return
            }
            // An interruption cannot preserve an acquired target: ask the user
            // to reach it again before accepting any subsequent neutral return.
            phase = .approaching
        } else { return }
        continuity.reset()
        clearCandidate()
        status = phase == .awaitingCalibration ? "請正視屏幕並重新校準" : instruction
    }

    public mutating func skip() {
        guard isActive else { return }
        skippedCount += 1
        stepIndex += 1
        clearCandidate()
        continuity.reset()
        if stepIndex >= ExerciseStep.allCases.count {
            phase = .completed
            status = "本次活動結束"
        } else if phase == .paused {
            phaseBeforePause = referenceID == nil ? .awaitingCalibration : .approaching
            status = "已跳過，繼續後進入下一動作"
        } else if phase == .signalLost || referenceID == nil {
            phase = .awaitingCalibration
            status = "已跳過，收到數據後請重新校準"
        } else {
            phase = .approaching
            status = instruction
        }
    }

    public mutating func stop() {
        phase = .idle
        referenceID = nil
        continuity.reset()
        clearCandidate()
        status = "本次活動已結束"
    }

    public mutating func invalidatePose(reason: String = "運動數據中斷") {
        guard isActive else { return }
        if phase == .approaching || phase == .returning || phase == .paused {
            phaseBeforePause = referenceID == nil ? .awaitingCalibration : .approaching
        }
        continuity.reset()
        clearCandidate()
        freshSinceLoss = false
        if phase != .paused && phase != .awaitingCalibration { phase = .signalLost }
        status = "\(reason)，動作判定已暫停"
    }

    public mutating func process(_ pose: InteractionPose) {
        let previous = continuity.previous
        let result = continuity.observe(pose)
        guard result != .invalid else { invalidatePose(reason: "姿態數據無效"); return }
        currentPose = pose
        guard isActive else { return }
        guard let referenceID else { return }
        guard pose.calibrationID == referenceID else {
            self.referenceID = nil
            clearCandidate()
            continuity.reset()
            if phase != .paused { phase = .awaitingCalibration }
            phaseBeforePause = .approaching
            status = "參考姿態已改變，請確認正視方向後重新校準"
            return
        }
        if result == .interrupted {
            invalidatePose(reason: "樣本不連續或姿態跳變")
            return
        }
        if phase == .signalLost {
            freshSinceLoss = true
            status = "數據已恢復，點擊繼續或重新校準"
            return
        }
        guard phase == .approaching || phase == .returning else { return }
        if result == .continuous, let previous {
            elapsed += max(0, pose.timestamp - previous.timestamp)
        }
        if phase == .approaching {
            let beyondThreshold = exceedsThreshold(pose)
            status = beyondThreshold ? "已達到幅度，舒適地保持" : instruction
            if dwell(beyondThreshold, at: pose.timestamp, duration: settings.stableHold) {
                phase = .returning
                clearCandidate()
                status = "緩慢回到正視位置"
            }
        } else {
            let tolerance = min(6, min(settings.yawAngle, settings.tiltAngle, settings.nodAngle) * 0.5)
            let neutral = abs(wrappedDegrees(pose.yaw)) <= tolerance
                && abs(pose.pitch) <= tolerance && abs(wrappedDegrees(pose.roll)) <= tolerance
            status = neutral ? "在中立位置稍作停留" : "緩慢回到正視位置"
            if dwell(neutral, at: pose.timestamp, duration: settings.returnHold) {
                completedCount += 1
                stepIndex += 1
                clearCandidate()
                phase = stepIndex >= ExerciseStep.allCases.count ? .completed : .approaching
                status = phase == .completed ? "這一段輕緩活動已完成" : instruction
            }
        }
    }

    private var instruction: String {
        phase == .returning ? "緩慢回到正視位置" : (currentStep?.instruction ?? "")
    }

    private func exceedsThreshold(_ pose: InteractionPose) -> Bool {
        let target = target
        func exceeds(_ value: Double, _ goal: Double) -> Bool {
            let directional = value * (goal < 0 ? -1 : 1)
            return directional >= abs(goal) - 1e-9
        }
        switch currentStep {
        case .turnLeft, .turnRight: return exceeds(wrappedDegrees(pose.yaw), target.yaw)
        case .tiltLeft, .tiltRight: return exceeds(wrappedDegrees(pose.roll), target.roll)
        case .nod: return exceeds(pose.pitch, target.pitch)
        case nil: return false
        }
    }

    private mutating func dwell(_ condition: Bool, at time: TimeInterval, duration: TimeInterval) -> Bool {
        guard condition else { clearCandidate(); return false }
        if candidateStarted == nil { candidateStarted = time }
        progress = min(1, max(0, (time - (candidateStarted ?? time)) / duration))
        return progress >= 1 - 1e-9
    }

    private mutating func clearCandidate() { candidateStarted = nil; progress = 0 }
}
