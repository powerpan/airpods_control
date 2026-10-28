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
    public var departure = DepartureMachine()
    public var departureStatus = "離座偵測尚未啟用。"
    public var returnCalibrationPending = false
    public var activityAvailability = ActivityAvailability(isAvailable: false, authorization: .unknown)
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
    private var activitySource: (any ActivitySource)?
    private var activityConsumer: Task<Void, Never>?
    private var activityOperation: Task<Void, Never>?
    private var activityGeneration = 0
    private var activityRequested = false
    private var activityRefreshing = false
    private var activityFault: String?
    private var lastActivityAttempt = -Double.infinity
    private var lastActivityPoll = -Double.infinity
    private var departureWasEligible = false
    private var deskReferenceID: UUID?
    private var returnAnchor: ProcessedMotion?
    private var previousReturnSample: ProcessedMotion?
    private let returnCalibrationHold: TimeInterval

    public init(motion: MotionSession, privacy: PrivacySettings = PrivacySettings(),
                exercise: NeckExerciseSettings = NeckExerciseSettings(),
                activitySource: (any ActivitySource)? = nil,
                departure: DepartureMachine = DepartureMachine(),
                returnCalibrationHold: TimeInterval = 0.75) {
        self.motion = motion
        self.activitySource = activitySource
        self.returnCalibrationHold = returnCalibrationHold.isFinite ? max(0.1, returnCalibrationHold) : 0.75
        state.departure = departure
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
        updateDepartureStatus()
        return state
    }

    public func setPrivacyEnabled(_ enabled: Bool) async {
        state.privacy.setAutomaticEnabled(enabled)
        resetDepartureEvidence()
        if enabled { await motion.start() }
        await refreshActivitySource()
    }

    public func updatePrivacySettings(_ settings: PrivacySettings) async {
        state.privacy.updateSettings(settings)
        resetDepartureEvidence()
        await refreshActivitySource()
    }
    public func updateExerciseSettings(_ settings: NeckExerciseSettings) { state.exercise.updateSettings(settings) }

    public func showShield() {
        if state.exercise.isActive { state.exercise.pause() }
        state.privacy.manualShield()
    }

    public func hideShield() async {
        let wasDeparture = state.privacy.isDepartureLatched
        state.privacy.manualReveal()
        resetDepartureEvidence()
        if wasDeparture {
            // 此次明確解除才是返回確認；不能由 stationary 或回正姿態代替。
            invalidateDesk()
            state.returnCalibrationPending = true
            state.privacy.invalidatePose(reason: "已解除離座遮擋；等待穩定姿態重新校準")
            state.latestPose = nil
            lastReceipt = nil
            dataWasValid = false
            state.message = "已解除遮擋。請自然正視螢幕；收到穩定資料後重新校準，亦可使用原有手動校準。"
            await motion.clearCalibration()
        }
    }

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
        if success, let id = await motion.currentCalibrationID(), isRunning, !state.privacy.isShielded {
            confirmDesk(reference: id)
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
        invalidateDesk()
        state.returnCalibrationPending = false
        state.privacy.setSuspended(true)
        state.exercise.start(at: ProcessInfo.processInfo.systemUptime)
        state.message = nil
        await stopActivitySource()
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

    public func invalidateSensor(reason: String) { invalidate(reason, immediate: true) }

    public func shutdown() async {
        isRunning = false
        consumer?.cancel()
        consumer = nil
        watchdog?.cancel()
        watchdog = nil
        state.exercise.stop()
        state.privacy.setAutomaticEnabled(false)
        state.privacy.manualReveal()
        state.returnCalibrationPending = false
        invalidateDesk()
        await stopActivitySource()
    }

    private func receive(_ sample: ProcessedMotion) async {
        guard isRunning, !referenceOperation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - sample.raw.receivedUptime <= 0.3, now >= sample.raw.receivedUptime else {
            invalidate("數據延遲或中斷，暫停姿態判定。")
            return
        }
        if state.returnCalibrationPending {
            await considerReturnCalibration(sample)
            if state.returnCalibrationPending { return }
        }
        let liveReference = await motion.currentCalibrationID()
        guard isRunning, !referenceOperation else { return }
        guard sample.isCalibrated, let id = sample.calibrationID, id == liveReference,
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
        if let deskReferenceID, deskReferenceID != id { invalidateDesk() }
        if let previous = state.latestPose,
           sample.raw.timestamp - previous.timestamp > 0.25
            || sample.raw.receivedUptime - previous.receivedUptime > 0.25 {
            invalidateDesk()
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
        advanceDeparture()
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
        if let deskReferenceID, capture.calibrationID != deskReferenceID || !state.sensorReady {
            invalidateDesk()
        }
        if !state.sensorReady {
            returnAnchor = nil
            previousReturnSample = nil
        }
        await refreshActivitySource()
        guard isRunning else { return }
        advanceDeparture()
    }

    /// `dataLost` marks evidence that disappeared while capture was wanted;
    /// armed protection then fails closed (see `PrivacyMachine.poseDataLost`).
    /// `immediate` skips the resume grace for definitive loss (disconnect, sleep).
    private func invalidate(_ reason: String, dataLost: Bool = true, immediate: Bool = false) {
        invalidateDesk()
        dataWasValid = false
        state.sensorReady = false
        state.latestPose = nil
        lastReceipt = nil
        if dataLost {
            state.privacy.poseDataLost(reason: reason, at: ProcessInfo.processInfo.systemUptime, immediate: immediate)
        } else {
            state.privacy.invalidatePose(reason: reason)
        }
        if state.exercise.isActive { state.exercise.invalidatePose(reason: reason) }
    }

    private func restorePrivacyAfterExercise() async {
        invalidateDesk()
        state.returnCalibrationPending = false
        state.privacy.setSuspended(false)
        state.privacy.resetReference()
        state.latestPose = nil
        lastReceipt = nil
        dataWasValid = false
        state.message = "活動已結束。請重新看向屏幕並校準中立姿態，再恢復自動隱私檢測。"
        await motion.clearCalibration()
    }

    private func confirmDesk(reference: UUID) {
        deskReferenceID = reference
        state.departure.confirmDesk(at: ProcessInfo.processInfo.systemUptime, date: Date())
        departureWasEligible = false
        state.returnCalibrationPending = false
        returnAnchor = nil
        previousReturnSample = nil
    }

    private func invalidateDesk() {
        deskReferenceID = nil
        state.departure.invalidateDesk()
        departureWasEligible = false
        returnAnchor = nil
        previousReturnSample = nil
    }

    private func resetDepartureEvidence() {
        state.departure.resetEvidence(at: ProcessInfo.processInfo.systemUptime, date: Date())
        departureWasEligible = false
    }

    private var activityWanted: Bool {
        isRunning && state.privacy.automaticEnabled && state.privacy.settings.departureDetectionEnabled
            && !state.exercise.isActive && !state.privacy.isSuspended && state.capture.source == .headphones
            && state.capture.isRequested
    }

    private var departureEligible: Bool {
        let activity = state.activityAvailability
        let phase = state.privacy.phase
        return activityWanted && activity.isAvailable && activity.isActive
            && activity.authorization == .authorized && activity.connection == .connected
            && activityFault == nil && state.sensorReady && !state.returnCalibrationPending
            && state.departure.isDeskConfirmed && deskReferenceID == state.latestPose?.calibrationID
            && deskReferenceID == state.capture.calibrationID
            && (phase == .watching || phase == .turningAway || phase == .shielded || phase == .returning)
    }

    private func advanceDeparture() {
        guard !state.privacy.isDepartureLatched else { return }
        guard departureEligible else {
            if departureWasEligible { resetDepartureEvidence() }
            return
        }
        departureWasEligible = true
        if state.departure.advance(at: ProcessInfo.processInfo.systemUptime) {
            state.privacy.confirmDeparture()
        }
    }

    // 活動回調是狀態變更通知，不是心跳。只輪詢來源健康，從不因缺少重複回調
    // 判定斷流；姿態資料、授權、連接與來源錯誤共同決定候選是否仍可採信。
    private func refreshActivitySource() async {
        guard !activityRefreshing else { return }
        activityRefreshing = true
        defer { activityRefreshing = false }
        let capture = await motion.snapshot()
        guard isRunning else { return }
        state.capture = capture
        guard activityWanted else {
            await stopActivitySource()
            return
        }
        if activitySource == nil {
            let created = await makeHeadphoneActivitySource()
            guard activityWanted else { return }
            activitySource = created
        }
        guard let source = activitySource else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastActivityPoll >= 0.5 {
            let generation = activityGeneration
            let availability = await source.availability
            guard activityWanted, generation == activityGeneration else { return }
            lastActivityPoll = now
            applyActivityAvailability(availability)
        }
        let availability = state.activityAvailability
        let retry = now - lastActivityAttempt >= 3
            && availability.authorization != .notDetermined
            && availability.authorization != .denied && availability.authorization != .restricted
            && (availability.isAvailable || availability.connection == .connected)
            && (!availability.isActive || activityFault != nil)
        guard !activityRequested || retry else { return }
        activityGeneration += 1
        let generation = activityGeneration
        activityRequested = true
        activityFault = nil
        lastActivityAttempt = now
        resetDepartureEvidence()
        activityConsumer?.cancel()
        // 和 MotionSession 一樣串行排列來源啟停，避免 actor 重入留下晚啟動的來源。
        let previous = activityOperation
        let operation = Task {
            await previous?.value
            return await source.start()
        }
        activityOperation = Task { _ = await operation.value }
        let stream = await operation.value
        guard generation == activityGeneration, activityWanted else { return }
        state.activityAvailability = await source.availability
        guard generation == activityGeneration, activityWanted else { return }
        activityConsumer = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.receiveActivity(event, generation: generation)
            }
            guard !Task.isCancelled else { return }
            await self?.activityEnded(generation: generation)
        }
    }

    private func stopActivitySource() async {
        guard activityRequested else { return }
        activityGeneration += 1
        activityRequested = false
        activityConsumer?.cancel()
        activityConsumer = nil
        state.activityAvailability.isActive = false
        activityFault = nil
        resetDepartureEvidence()
        guard let source = activitySource else { return }
        let previous = activityOperation
        let operation = Task {
            await previous?.value
            await source.stop()
        }
        activityOperation = operation
        await operation.value
    }

    private func receiveActivity(_ event: ActivitySourceEvent, generation: Int) async {
        guard generation == activityGeneration, activityRequested, isRunning else { return }
        switch event {
        case .observation(let observation):
            // 事件處理前重讀共享採集狀態，防止停止/換源與回調同時發生時沿用舊健康快照。
            let capture = await motion.snapshot()
            guard generation == activityGeneration, activityRequested, isRunning else { return }
            state.capture = capture
            let now = ProcessInfo.processInfo.systemUptime
            let age = capture.lastReceivedUptime.map { now - $0 } ?? .infinity
            guard capture.phase == .streaming, age >= 0, age <= 0.3, departureEligible else { return }
            departureWasEligible = true
            state.departure.observe(observation, now: now)
            advanceDeparture()
        case .availability(let availability):
            // start() 的初始通知可能早於 manager 啟動；以當前來源讀值確認健康。
            if let source = activitySource {
                let current = await source.availability
                guard generation == activityGeneration, activityRequested else { return }
                applyActivityAvailability(current)
            } else {
                applyActivityAvailability(availability)
            }
        case .connection(let connection):
            state.activityAvailability.connection = connection
            if connection == .disconnected {
                state.activityAvailability.isActive = false
                activityEvidenceLost("耳機活動連接已斷開")
            }
        case .failure(let reason):
            activityFault = reason
            state.activityAvailability.isActive = false
            activityEvidenceLost(reason)
        }
    }

    private func activityEvidenceLost(_ reason: String) {
        invalidateDesk()
        // 活動通道可先於姿態通道報告失聯；不能讓排隊中的回正樣本揭開遮擋。
        if state.privacy.isShielded { state.privacy.invalidatePose(reason: reason) }
    }

    private func applyActivityAvailability(_ availability: ActivityAvailability) {
        let old = state.activityAvailability
        state.activityAvailability = availability
        if availability.connection == .disconnected
            || (old.isActive && !availability.isActive)
            || availability.authorization == .denied || availability.authorization == .restricted {
            activityEvidenceLost(availability.reason ?? "活動識別資料不可用")
        }
    }

    private func activityEnded(generation: Int) {
        guard generation == activityGeneration, activityRequested else { return }
        if !state.activityAvailability.isAvailable, state.activityAvailability.reason != nil {
            activityFault = nil
        } else {
            activityFault = activityFault ?? "活動資料流已結束；等待重新連接。"
        }
        state.activityAvailability.isActive = false
        activityEvidenceLost(activityFault ?? "活動識別不可用")
    }

    private func considerReturnCalibration(_ sample: ProcessedMotion) async {
        guard !state.exercise.isActive, !state.privacy.isShielded else { return }
        let rate = sample.raw.rotationRate
        let speed = sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z) * 180 / .pi
        if let previous = previousReturnSample {
            let interval = sample.raw.timestamp - previous.raw.timestamp
            let receivedInterval = sample.raw.receivedUptime - previous.raw.receivedUptime
            if interval <= 0 || interval > 0.25 || receivedInterval < 0 || receivedInterval > 0.25 {
                returnAnchor = nil
            }
        }
        previousReturnSample = sample
        guard speed.isFinite, speed <= 10 else { returnAnchor = nil; return }
        if let anchor = returnAnchor {
            guard let a = anchor.raw.quaternion.normalized(),
                  let b = sample.raw.quaternion.normalized() else { returnAnchor = nil; return }
            let dot = abs(a.dot(b))
            // 持續小幅旋轉不能僅憑角速度低就重新設為中立。
            if dot < cos(3 * .pi / 360) { returnAnchor = sample; return }
        } else { returnAnchor = sample }
        guard let anchor = returnAnchor,
              sample.raw.receivedUptime - anchor.raw.receivedUptime >= returnCalibrationHold else { return }
        referenceOperation = true
        defer { referenceOperation = false }
        let success = await motion.calibrate(expectedTimestamp: sample.raw.timestamp)
        guard isRunning, state.returnCalibrationPending, !state.privacy.isShielded, !state.exercise.isActive,
              success, let id = await motion.currentCalibrationID() else { return }
        guard isRunning, state.returnCalibrationPending, !state.privacy.isShielded else { return }
        confirmDesk(reference: id)
        state.privacy.resetReference()
        state.latestPose = nil
        lastReceipt = nil
        dataWasValid = false
        state.message = "中立方向已重新校準；穩定後恢復轉頭偵測，離座偵測另有短暫冷卻。"
    }

    private func updateDepartureStatus() {
        if state.privacy.isDepartureLatched {
            state.departureStatus = "偵測到可能離開書桌，遮擋已保持；請手動解除。"
        } else if !state.privacy.settings.departureDetectionEnabled {
            state.departureStatus = "離座偵測已關閉；轉頭遮擋設定不受影響。"
        } else if !state.privacy.automaticEnabled {
            state.departureStatus = "開啟自動隱私保護後可啟用離座偵測。"
        } else if state.exercise.isActive {
            state.departureStatus = "頸部活動期間暫停離座偵測。"
        } else if state.capture.source != .headphones {
            state.departureStatus = "模擬姿態不提供真實活動分類；離座偵測不可用。"
        } else if state.returnCalibrationPending {
            state.departureStatus = "已解除；請正視螢幕並保持穩定。缺少即時資料時，請恢復採集後使用原有校準入口。"
        } else if let fault = activityFault {
            state.departureStatus = "離座偵測暫不可用：\(fault) 轉頭遮擋仍可使用。"
        } else if let reason = state.activityAvailability.reason {
            state.departureStatus = "離座偵測不可用：\(reason)"
        } else if !state.activityAvailability.isAvailable || !state.activityAvailability.isActive {
            state.departureStatus = "等待相容耳機、活動權限及連接；轉頭遮擋仍可使用。"
        } else if !state.departure.isDeskConfirmed {
            state.departureStatus = "請坐在書桌前，使用原有螢幕中立方向校準確認基準。"
        } else if !departureEligible {
            state.departureStatus = "等待有效姿態與中立方向穩定；離座證據尚未累積。"
        } else if state.departure.isRearming(at: ProcessInfo.processInfo.systemUptime) {
            state.departureStatus = "離座偵測正在重新就緒，短暫冷卻後恢復；轉頭遮擋仍正常運作。"
        } else if state.departure.progress > 0 {
            state.departureStatus = "正在確認持續步行；達到保持時間後鎖定遮擋。"
        } else {
            state.departureStatus = "已確認書桌基準；可靠步行持續約 2.5 秒後保持遮擋。"
        }
    }

    deinit {
        consumer?.cancel()
        watchdog?.cancel()
        activityConsumer?.cancel()
        let source = activitySource
        let operation = activityOperation
        Task { @MainActor in
            await operation?.value
            source?.stop()
        }
    }
}
