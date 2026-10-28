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

/// Both features consume one shared capture session. Rules execute at the
/// accepted sensor rate; presentation only reads a snapshot at 10 Hz.
public actor InteractionSession {
    private let motion: MotionSession
    private var state = InteractionSnapshot()
    private var consumer: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var isRunning = false
    private var referenceOperation = false
    private var lastReceipt: TimeInterval?
    private var dataWasValid = false

    public init(motion: MotionSession, privacy: PrivacySettings = PrivacySettings(), exercise: NeckExerciseSettings = NeckExerciseSettings()) {
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

    public func snapshot() -> InteractionSnapshot { state }

    public func setPrivacyEnabled(_ enabled: Bool) async {
        state.privacy.setAutomaticEnabled(enabled)
        if enabled { await motion.start() }
    }

    public func updatePrivacySettings(_ settings: PrivacySettings) { state.privacy.updateSettings(settings) }
    public func updateExerciseSettings(_ settings: NeckExerciseSettings) { state.exercise.updateSettings(settings) }

    public func showShield() {
        if state.exercise.isActive { state.exercise.pause() }
        state.privacy.manualShield()
    }

    public func hideShield() { state.privacy.manualReveal() }

    public func calibrateNeutral() async -> Bool {
        guard !state.privacy.isShielded else {
            state.message = "请先手动解除遮挡，再校准观看屏幕的中立姿态。"
            return false
        }
        if state.exercise.isActive { return await calibrateExercise() }
        guard !referenceOperation else { return false }
        referenceOperation = true
        defer { referenceOperation = false }
        let success = await motion.calibrate()
        if success {
            state.privacy.resetReference()
            state.latestPose = nil
            lastReceipt = nil
            dataWasValid = false
            state.message = "中立姿态已校准。"
        } else {
            state.message = "请先开始采集，确认耳机正在发送数据。"
        }
        return success
    }

    @discardableResult
    public func startExercise() async -> Bool {
        guard !state.privacy.isShielded else {
            state.message = "请明确解除隐私遮挡后再开始颈部活动。"
            return false
        }
        guard !state.exercise.isActive else { return true }
        state.privacy.setSuspended(true)
        state.exercise.start(at: ProcessInfo.processInfo.systemUptime)
        state.message = nil
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
            state.message = "尚无有效数据；请连接并佩戴耳机，等待开始收帧。"
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

    public func invalidateSensor(reason: String) { invalidate(reason) }

    public func shutdown() {
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
            invalidate("数据延迟或中断，暂停姿态判定。")
            return
        }
        let liveReference = await motion.currentCalibrationID()
        guard isRunning, !referenceOperation else { return }
        guard sample.isCalibrated, let id = sample.calibrationID, id == liveReference,
              let headAngles = sample.headRelativeAngles else {
            if dataWasValid || state.latestPose != nil {
                invalidate("参考姿态已失效，请重新校准")
            }
            state.latestPose = nil
            lastReceipt = nil
            dataWasValid = false
            return
        }
        if let lastReceipt, sample.raw.receivedUptime - lastReceipt > 0.3 {
            invalidate("数据连续性中断，保持遮挡并暂停动作判定。")
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
        if !state.sensorReady, dataWasValid || state.latestPose != nil {
            invalidate("耳机数据不可用；遮挡保留，活动判定暂停。")
        }
        if capture.calibrationID == nil, state.latestPose != nil {
            invalidate("参考姿态已失效，请重新校准。")
        }
    }

    private func invalidate(_ reason: String) {
        dataWasValid = false
        state.sensorReady = false
        state.latestPose = nil
        lastReceipt = nil
        state.privacy.invalidatePose(reason: reason)
        if state.exercise.isActive { state.exercise.invalidatePose(reason: reason) }
    }

    private func restorePrivacyAfterExercise() async {
        state.privacy.setSuspended(false)
        state.privacy.resetReference()
        state.latestPose = nil
        lastReceipt = nil
        dataWasValid = false
        state.message = "活动已结束。请重新看向屏幕并校准中立姿态，再恢复自动隐私检测。"
        await motion.clearCalibration()
    }

    deinit { consumer?.cancel(); watchdog?.cancel() }
}
