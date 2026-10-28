import Foundation
import MotionCore

public struct SessionTiming: Sendable {
    public var interruptionTimeout: TimeInterval
    public var retryInterval: TimeInterval
    public var watchdogInterval: TimeInterval

    public init(interruptionTimeout: TimeInterval = 2, retryInterval: TimeInterval = 3, watchdogInterval: TimeInterval = 0.5) {
        self.interruptionTimeout = max(0.05, interruptionTimeout)
        self.retryInterval = max(0.1, retryInterval)
        self.watchdogInterval = max(0.01, watchdogInterval)
    }
}

/// Owns capture intent, recovery, processing and bounded fan-out. All processing
/// is serialized here, off the main actor. UI obtains snapshots at its own rate.
public actor MotionSession {
    private var source: (any MotionSource)?
    private var processor = MotionProcessor()
    private var state = SessionSnapshot()
    private let timing: SessionTiming
    private var eventTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var generation = 0
    private var attempt = 0
    private var lastAttemptUptime: TimeInterval = 0
    private var continuityLost = false
    private var completedIngressDrops = 0
    private var hasStartedSource = false
    private var lastAvailabilityCheckUptime: TimeInterval = -.infinity
    private var sourceOperation: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<ProcessedMotion>.Continuation] = [:]

    public init(source: (any MotionSource)? = nil, timing: SessionTiming = SessionTiming()) {
        self.source = source
        self.timing = timing
    }

    public func setSource(_ kind: MotionSourceKind) async {
        guard !state.isRequested, state.source != kind else { return }
        generation += 1
        let token = generation
        let previous = source
        source = nil
        state = SessionSnapshot()
        state.source = kind
        processor.reset()
        completedIngressDrops = 0
        hasStartedSource = false
        if let previous { await stopSource(previous) }
        guard generation == token else { return }
        let replacement = await Self.makeSource(kind)
        guard generation == token else { return }
        source = replacement
        state.availability = await replacement.availability
    }

    public func start() async {
        guard !state.isRequested else { return }
        generation += 1
        let token = generation
        let kind = state.source
        let smoothing = state.smoothingEnabled
        state = SessionSnapshot()
        state.source = kind
        state.smoothingEnabled = smoothing
        state.isRequested = true
        state.phase = .starting
        state.message = "正在等待首個有效樣本…"
        processor.reset()
        processor.smoothingTimeConstant = smoothing ? 0.08 : 0
        continuityLost = false
        completedIngressDrops = 0
        hasStartedSource = false
        if source == nil {
            let created = await Self.makeSource(kind)
            guard generation == token, state.isRequested else { return }
            source = created
        }
        guard let source else { return }
        let sourceKind = await source.kind
        guard generation == token, state.isRequested else { return }
        state.source = sourceKind
        await beginAttempt(generation: token)
        guard generation == token, state.isRequested else { return }
        let interval = timing.watchdogInterval
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
                await self?.checkHealth(generation: token)
            }
        }
    }

    public func stop() async {
        generation += 1
        eventTask?.cancel()
        eventTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        state.isRequested = false
        state.phase = .stopped
        state.message = "採集已停止；保留最後一幀供檢查。"
        loseContinuity()
        if let source { await stopSource(source) }
    }

    public func shutdown() async {
        await stop()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    @discardableResult
    public func calibrate(expectedTimestamp: TimeInterval? = nil) -> Bool {
        // 自動回桌校準必須原子地使用已確認穩定的那一幀，不能套用稍後到達的姿態。
        if let expectedTimestamp {
            guard state.latest?.raw.timestamp == expectedTimestamp,
                  let receipt = state.lastReceivedUptime else { return false }
            let age = ProcessInfo.processInfo.systemUptime - receipt
            guard age >= 0, age <= 0.3 else { return false }
        }
        guard state.isRequested, state.phase == .streaming,
              let received = state.lastReceivedUptime,
              ProcessInfo.processInfo.systemUptime - received <= timing.interruptionTimeout,
              processor.calibrate() else {
            state.calibrationMessage = "校準需要正在接收的有效樣本。"
            return false
        }
        state.calibrationMessage = "已將最近有效姿態設為參考；下一幀顯示相對姿態。"
        state.calibrationID = processor.calibrationID
        return true
    }

    public func clearCalibration() {
        processor.clearCalibration()
        state.calibrationID = nil
        state.calibrationMessage = "請自然看向屏幕並重新校準中立姿態。"
    }

    public func currentCalibrationID() -> UUID? { state.calibrationID }

    public func setSmoothing(enabled: Bool) {
        state.smoothingEnabled = enabled
        processor.smoothingTimeConstant = enabled ? 0.08 : 0
    }

    public func snapshot() async -> SessionSnapshot {
        if source == nil {
            let token = generation
            let created = await Self.makeSource(state.source)
            if generation == token, source == nil { source = created }
        }
        if let source {
            let token = generation
            let now = ProcessInfo.processInfo.systemUptime
            // Connection/authorization are health state, not 10 Hz UI data.
            // The active watchdog refreshes them; idle snapshots poll at 1 Hz.
            let availability: SourceAvailability
            if !state.isRequested && now - lastAvailabilityCheckUptime >= 1 {
                availability = await source.availability
                lastAvailabilityCheckUptime = now
            } else {
                availability = state.availability
            }
            let drops = await source.droppedEventCount
            if generation == token {
                state.availability = availability
                state.ingressDroppedCount = completedIngressDrops + (hasStartedSource ? drops : 0)
            }
        }
        return state
    }

    /// Each consumer has its own bounded queue. Slow consumers drop oldest
    /// samples instead of delaying acquisition; drops are visible in diagnostics.
    /// Future recognition modules should consume this stream, not UI snapshots.
    public func samples(bufferCapacity: Int = 128) -> AsyncStream<ProcessedMotion> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ProcessedMotion>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, min(bufferCapacity, 4096)))
        )
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private static func makeSource(_ kind: MotionSourceKind) async -> any MotionSource {
        await MainActor.run {
            switch kind {
            case .headphones: HeadphoneMotionSource()
            case .simulation: SimulatedMotionSource()
            }
        }
    }

    private func beginAttempt(generation token: Int) async {
        guard token == generation, state.isRequested, let source else { return }
        attempt += 1
        let currentAttempt = attempt
        eventTask?.cancel()
        let drops = await source.droppedEventCount
        guard token == generation, state.isRequested else { return }
        let previousAttemptDrops = hasStartedSource ? drops : 0
        await stopSource(source)
        guard token == generation, state.isRequested else { return }
        let availability = await source.availability
        guard token == generation, state.isRequested else { return }
        state.availability = availability
        lastAvailabilityCheckUptime = ProcessInfo.processInfo.systemUptime
        if availability.authorization == .denied || availability.authorization == .restricted {
            state.phase = .permissionDenied
            state.message = "運動權限被拒絕或受系統限制。修改權限後重新開始採集。"
            state.lastError = state.message
            state.isRequested = false
            return
        }
        lastAttemptUptime = ProcessInfo.processInfo.systemUptime
        let stream = await startSource(source)
        // Newer stop/start commands already follow this start in the command
        // chain. A stale attempt must never stop a newer capture session.
        guard token == generation, state.isRequested else { return }
        completedIngressDrops += previousAttemptDrops
        hasStartedSource = true
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.receive(event, generation: token, attempt: currentAttempt)
            }
            guard !Task.isCancelled else { return }
            await self?.streamEnded(generation: token, attempt: currentAttempt)
        }
    }

    private func receive(_ event: MotionSourceEvent, generation token: Int, attempt currentAttempt: Int) {
        guard generation == token, attempt == currentAttempt, state.isRequested else { return }
        switch event {
        case .sample(let sample):
            let previousDiscontinuities = processor.discontinuityCount
            guard let processed = processor.process(sample) else {
                updateCounters()
                state.lastError = processor.lastRejection
                return
            }
            if processor.discontinuityCount > previousDiscontinuities {
                state.calibrationMessage = "採樣時間出現間隔，參考姿態已清除；請重新校準。"
            }
            continuityLost = false
            state.latest = processed
            state.lastReceivedAt = sample.receivedAt
            state.lastReceivedUptime = sample.receivedUptime
            state.phase = .streaming
            state.message = nil
            updateCounters()
            for continuation in subscribers.values {
                if case .dropped = continuation.yield(processed) { state.subscriberDroppedCount += 1 }
            }
        case .availability(let availability):
            state.availability = availability
        case .connection(let connection):
            state.availability.connection = connection
            if connection == .disconnected {
                state.phase = .waiting
                state.message = "耳機已斷開，等待重新連接。"
                loseContinuity()
            } else if connection == .connected, state.phase != .streaming {
                state.phase = .starting
                state.message = "耳機已連接，等待運動權限與有效數據。"
            }
        case .failure(let message):
            state.lastError = message
            state.phase = .failed
            state.message = "採集回調異常；將檢查權限與連接並重試。"
            loseContinuity()
        }
    }

    private func streamEnded(generation token: Int, attempt currentAttempt: Int) {
        guard generation == token, attempt == currentAttempt, state.isRequested else { return }
        state.phase = .interrupted
        state.message = "數據流已結束，等待重試。"
        loseContinuity()
    }

    private func checkHealth(generation token: Int) async {
        guard token == generation, state.isRequested, let source else { return }
        let availability = await source.availability
        guard token == generation, state.isRequested else { return }
        state.availability = availability
        lastAvailabilityCheckUptime = ProcessInfo.processInfo.systemUptime
        if availability.authorization == .denied || availability.authorization == .restricted {
            state.phase = .permissionDenied
            state.message = "運動權限被拒絕或受限制；修改系統權限後重新開始。"
            state.lastError = state.message
            state.isRequested = false
            loseContinuity()
            eventTask?.cancel()
            watchdogTask?.cancel()
            await stopSource(source)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let age = now - (state.lastReceivedUptime ?? lastAttemptUptime)
        if age > timing.interruptionTimeout {
            if state.phase == .streaming || state.phase == .starting {
                state.phase = state.lastReceivedUptime == nil ? .waiting : .interrupted
                state.message = state.lastReceivedUptime == nil
                    ? "尚未收到有效數據。請連接並佩戴兼容耳機，確認當前連接到這台 Mac。"
                    : "超過 \(timing.interruptionTimeout.formatted()) 秒沒有有效數據；參考姿態已清除。"
                loseContinuity()
            }
        }
        // Do not repeatedly tear down the stream while the OS is waiting for
        // initial consent. Wearing/connecting and the permission prompt can
        // take longer than our normal recovery interval.
        if availability.authorization == .notDetermined {
            if state.phase != .streaming {
                state.message = "等待運動權限或首個有效樣本；請佩戴耳機並檢查系統權限提示。"
            }
            return
        }
        if state.phase != .streaming, now - lastAttemptUptime >= timing.retryInterval {
            // A fresh stream may restart its timestamp/reference frame. Never
            // reuse a calibration or interpolate across a recovery attempt.
            loseContinuity()
            await beginAttempt(generation: token)
        }
    }

    private func loseContinuity() {
        guard !continuityLost else { return }
        continuityLost = true
        processor.resetContinuity()
        state.calibrationMessage = "連續性已重置；恢復數據後請重新校準。"
        updateCounters()
    }

    private func updateCounters() {
        state.acceptedCount = processor.acceptedCount
        state.rejectedCount = processor.rejectedCount
        state.discontinuityCount = processor.discontinuityCount
        state.calibrationID = processor.calibrationID
    }

    // Source lifecycle calls are ordered independently of actor reentrancy.
    // In particular, a stop requested during an awaited start always executes
    // after that start, and before any subsequent start.
    private func startSource(_ source: any MotionSource) async -> AsyncStream<MotionSourceEvent> {
        let previous = sourceOperation
        let operation = Task {
            await previous?.value
            return await source.start()
        }
        sourceOperation = Task { _ = await operation.value }
        return await operation.value
    }

    private func stopSource(_ source: any MotionSource) async {
        let previous = sourceOperation
        let operation = Task {
            await previous?.value
            await source.stop()
        }
        sourceOperation = operation
        await operation.value
    }

    deinit {
        eventTask?.cancel()
        watchdogTask?.cancel()
        for continuation in subscribers.values { continuation.finish() }
        let source = source
        let operation = sourceOperation
        Task { @MainActor in
            await operation?.value
            source?.stop()
        }
    }
}
