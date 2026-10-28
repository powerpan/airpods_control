import Foundation
import MotionCore
import InteractionCore

public struct InteractionSnapshot: Sendable {
    public var privacy = PrivacyMachine()
    public var exercise = NeckExerciseMachine()
    public var latestPose: InteractionPose?
    public var sensorReady = false
    public var message: String?
    public var capture = SessionSnapshot()
    public var automaticSuspended: Bool { exercise.isActive }
    public init() {}
}

/// Both features share one capture stream; UI reads snapshots at 10 Hz.
public actor InteractionSession {
    private let motion: MotionSession
    private var state = InteractionSnapshot()
    private var consumer: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var isRunning = false
    private var referenceOperation = false
    private var lastReceipt: TimeInterval?
    private var dataWasValid = false
    private var handledInterruptionID: UUID?

    public init(motion: MotionSession, privacy: PrivacySettings = PrivacySettings(),
                exercise: NeckExerciseSettings = NeckExerciseSettings()) {
        self.motion = motion
        state.privacy = PrivacyMachine(settings: privacy)
        state.exercise = NeckExerciseMachine(settings: exercise)
    }

    public func activate() async {
        guard !isRunning else { return }
        isRunning = true
        let stream = await motion.samples(bufferCapacity: 64)
        guard isRunning else { return }
        consumer = Task { [weak self] in
            for await sample in stream {
                guard !Task.isCancelled else { break }
                await self?.receive(sample)
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkHealth()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
    }

    public func snapshot() -> InteractionSnapshot {
        return state
    }

    public func setPrivacyEnabled(_ enabled: Bool) async {
        state.privacy.setAutomaticEnabled(enabled)
        if enabled { await motion.start() }
    }

    public func updatePrivacySettings(_ settings: PrivacySettings) async {
        state.privacy.updateSettings(settings)
    }
    public func updateExerciseSettings(_ settings: NeckExerciseSettings) { state.exercise.updateSettings(settings) }

    public func showShield() {
        if state.exercise.isActive { state.exercise.pause() }
        state.privacy.manualShield()
    }

    public func hideShield() { state.privacy.manualReveal() }

    public func calibrateNeutral() async -> Bool {
        guard !state.privacy.isShielded else {
            state.message = "請先手動解除遮擋，再校準觀看屏幕的中立姿態。"
            return false
        }
        if state.exercise.isActive { return await calibrateExercise() }
        guard !referenceOperation else { return false }
        referenceOperation = true
        defer { referenceOperation = false }
        let success = await motion.calibrate()
        if success, await motion.currentCalibrationID() != nil, isRunning, !state.privacy.isShielded {
            state.privacy.resetReference()
            state.latestPose = nil
            lastReceipt = nil
            dataWasValid = false
            state.message = "中立姿態已校準。"
        } else {
            state.message = "請先開始採集，確認耳機正在發送數據。"
        }
        return success
    }

    @discardableResult
    public func startExercise() async -> Bool {
        guard !state.privacy.isShielded else {
            state.message = "請明確解除隱私遮擋後再開始頸部活動。"
            return false
        }
        guard !state.exercise.isActive else { return true }
        state.privacy.setSuspended(true)
        state.exercise.start(at: ProcessInfo.processInfo.systemUptime)
        state.message = nil
        guard isRunning, state.exercise.isActive else { return false }
        await motion.start()
        return true
    }

    @discardableResult
    public func calibrateExercise() async -> Bool {
        guard state.exercise.isActive, !state.privacy.isShielded, !referenceOperation else { return false }
        referenceOperation = true
        defer { referenceOperation = false }
        let success = await motion.calibrate()
        guard success, let id = await motion.currentCalibrationID() else {
            state.message = "尚無有效數據；請連接並佩戴耳機，等待開始收幀。"
            return false
        }
        guard state.exercise.isActive, !state.privacy.isShielded else { return false }
        state.exercise.calibrate(referenceID: id)
        state.latestPose = nil
        lastReceipt = nil
        dataWasValid = false
        state.message = nil
        return true
    }

    public func pauseExercise() { state.exercise.pause() }
    public func resumeExercise() {
        guard !state.privacy.isShielded else { return }
        state.exercise.resume()
    }
    public func skipExercise() async {
        let wasActive = state.exercise.isActive
        state.exercise.skip()
        if wasActive, !state.exercise.isActive { await restorePrivacyAfterExercise() }
    }
    public func endExercise() async {
        guard state.exercise.isActive else { return }
        state.exercise.stop()
        await restorePrivacyAfterExercise()
    }

    public func invalidateSensor(reason: String) async {
        invalidate(reason, immediate: true)
        await motion.invalidateForSleep()
    }

    public func shutdown() async {
        isRunning = false
        consumer?.cancel()
        consumer = nil
        watchdog?.cancel()
        watchdog = nil
        state.exercise.stop()
        state.privacy.setAutomaticEnabled(false)
        state.privacy.manualReveal()
    }

    private func receive(_ sample: ProcessedMotion) async {
        guard isRunning, !referenceOperation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - sample.raw.receivedUptime <= 0.3, now >= sample.raw.receivedUptime else {
            invalidate("數據延遲或中斷，暫停姿態判定。")
            return
        }
        let capture = await motion.snapshot()
        guard isRunning, !referenceOperation else { return }
        consumeInterruption(capture)
        guard sample.isCalibrated, let id = sample.calibrationID, id == capture.calibrationID,
              let headAngles = sample.headRelativeAngles else {
            if dataWasValid || state.latestPose != nil {
                invalidate("參考姿態已失效，請重新校準")
            }
            state.latestPose = nil
            lastReceipt = nil
            dataWasValid = false
            return
        }
        if let lastReceipt, sample.raw.receivedUptime - lastReceipt > 0.3 {
            invalidate("數據連續性中斷，保持遮擋並暫停動作判定。")
        }
        lastReceipt = sample.raw.receivedUptime
        state.sensorReady = true
        dataWasValid = true
        let rate = sample.smoothedRotationRate
        let pose = InteractionPose(
            timestamp: sample.raw.timestamp, receivedUptime: sample.raw.receivedUptime,
            yaw: headAngles.yaw * 180 / .pi,
            pitch: headAngles.pitch * 180 / .pi,
            roll: headAngles.roll * 180 / .pi,
            angularSpeed: sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z) * 180 / .pi,
            calibrationID: id
        )
        state.latestPose = pose
        let wasActive = state.exercise.isActive
        state.privacy.process(pose)
        state.exercise.process(pose)
        if wasActive, !state.exercise.isActive { await restorePrivacyAfterExercise() }
    }

    private func checkHealth() async {
        guard isRunning else { return }
        let capture = await motion.snapshot()
        guard isRunning else { return }
        state.capture = capture
        let age = capture.lastReceivedUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .infinity
        state.sensorReady = capture.phase == .streaming && age <= 0.3
        // 使用者停止採集（或應用結束）是正常關閉，不是資料遺失，不自動遮擋。
        let stoppedOnPurpose = !capture.isRequested && (capture.phase == .stopped || capture.phase == .idle)
        let disconnected = capture.availability.connection == .disconnected
        consumeInterruption(capture)
        if !state.sensorReady, dataWasValid || state.latestPose != nil {
            invalidate("耳機數據不可用；遮擋保留，活動判定暫停。", dataLost: !stoppedOnPurpose, immediate: disconnected)
        }
        if capture.calibrationID == nil, state.latestPose != nil {
            invalidate("參考姿態已失效，請重新校準。", dataLost: !stoppedOnPurpose)
        }
        if stoppedOnPurpose, state.privacy.dataLossSince != nil {
            state.privacy.invalidatePose(reason: "採集已停止")
        } else {
            state.privacy.checkDataLoss(at: disconnected ? .infinity : ProcessInfo.processInfo.systemUptime)
        }
    }

    /// `dataLost` marks evidence that disappeared while capture was wanted;
    /// armed protection then fails closed (see `PrivacyMachine.poseDataLost`).
    /// `immediate` skips the resume grace for definitive loss (disconnect, sleep).
    private func invalidate(_ reason: String, dataLost: Bool = true, immediate: Bool = false) {
        let lastValidReceipt = lastReceipt
        dataWasValid = false
        state.sensorReady = false
        state.latestPose = nil
        lastReceipt = nil
        if dataLost {
            state.privacy.poseDataLost(reason: reason, at: ProcessInfo.processInfo.systemUptime,
                                      immediate: immediate, lastSampleUptime: lastValidReceipt)
        } else {
            state.privacy.invalidatePose(reason: reason)
        }
        if state.exercise.isActive { state.exercise.invalidatePose(reason: reason) }
    }

    private func consumeInterruption(_ capture: SessionSnapshot) {
        guard let event = capture.lastInterruption, event.id != handledInterruptionID else { return }
        handledInterruptionID = event.id
        let reason: String
        switch event.reason {
        case .disconnected: reason = "耳機連線已中斷；重新連接後請手動校準"
        case .sleep: reason = "系統已進入睡眠；喚醒後請手動校準"
        case .sourceFailure: reason = "運動資料來源異常；恢復後請手動校準"
        case .streamEnded: reason = "運動資料流已結束；恢復後請手動校準"
        case .timedOut: reason = "運動資料中斷超過恢復期；請手動校準"
        }
        let stoppedOnPurpose = !capture.isRequested && (capture.phase == .stopped || capture.phase == .idle)
        invalidate(reason, dataLost: !stoppedOnPurpose, immediate: true)
    }

    private func restorePrivacyAfterExercise() async {
        state.privacy.setSuspended(false)
        state.privacy.resetReference()
        state.latestPose = nil
        lastReceipt = nil
        dataWasValid = false
        state.message = "活動已結束。請重新看向屏幕並校準中立姿態，再恢復自動隱私檢測。"
        await motion.clearCalibration()
    }

    deinit {
        consumer?.cancel()
        watchdog?.cancel()
    }
}
