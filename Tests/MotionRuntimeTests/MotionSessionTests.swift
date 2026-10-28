import Foundation
import MotionCore
import Testing
@testable import MotionRuntime

/// A controllable source without Core Motion, Bluetooth, timers or privacy prompts.
/// Retains old continuations so tests can attempt callbacks from prior captures.
@MainActor
private final class FakeMotionSource: MotionSource {
    let kind: MotionSourceKind = .headphones
    var availability = SourceAvailability(isAvailable: true, authorization: .authorized, connection: .connected)
    var droppedEventCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false
    private var continuations: [AsyncStream<MotionSourceEvent>.Continuation] = []

    func start() -> AsyncStream<MotionSourceEvent> {
        let (stream, continuation) = AsyncStream<MotionSourceEvent>.makeStream()
        continuations.append(continuation)
        startCount += 1
        isRunning = true
        droppedEventCount = 0
        return stream
    }

    func stop() {
        stopCount += 1
        isRunning = false
        continuations.last?.finish()
    }

    func send(_ event: MotionSourceEvent, capture: Int? = nil) {
        let index = capture ?? (continuations.count - 1)
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(event)
    }

    func finish() { continuations.last?.finish() }
}

@MainActor
private final class WeakSourceReference {
    weak var value: FakeMotionSource?
    init(_ source: FakeMotionSource?) { value = source }
}

private func sample(_ timestamp: Double, yaw: Double = 0) -> MotionSample {
    MotionSample(
        timestamp: timestamp, receivedAt: Date(), receivedUptime: ProcessInfo.processInfo.systemUptime,
        attitude: AttitudeAngles(yaw: yaw, pitch: 0, roll: 0),
        quaternion: Quaternion(x: 0, y: 0, z: sin(yaw / 2), w: cos(yaw / 2)),
        rotationRate: .zero, userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1)
    )
}

@MainActor
private func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    } while clock.now < deadline && !Task.isCancelled
    return await condition()
}

private let patientTiming = SessionTiming(interruptionTimeout: 10, retryInterval: 10, watchdogInterval: 0.02)
private let recoveryTiming = SessionTiming(interruptionTimeout: 0.05, retryInterval: 0.12, watchdogInterval: 0.01)

@Test @MainActor
func repeatedStartIsIdempotentAndLateCallbacksCannotRestartStoppedCapture() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: patientTiming)
    await session.start()
    await session.start()
    #expect(source.startCount == 1)
    source.send(.sample(sample(10)))
    #expect(await eventually { await session.snapshot().acceptedCount == 1 })

    await session.stop()
    source.send(.sample(sample(10.1)))
    source.send(.connection(.connected))
    source.send(.failure("late callback"))
    await Task.yield()
    let stopped = await session.snapshot()
    #expect(stopped.phase == .stopped)
    #expect(!stopped.isRequested)
    #expect(stopped.acceptedCount == 1)
    #expect(!source.isRunning)

    await session.start()
    #expect(source.startCount == 2)
    source.send(.sample(sample(99)), capture: 0)
    source.send(.sample(sample(1)), capture: 1)
    #expect(await eventually { await session.snapshot().acceptedCount == 1 })
    let restarted = await session.snapshot()
    #expect(restarted.phase == .streaming)
    #expect(restarted.latest?.raw.timestamp == 1)
    await session.shutdown()
}

@Test @MainActor
func missingDataTriggersBoundedRetryAndStopCancelsTheWatchdog() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: recoveryTiming)
    await session.start()
    #expect(await eventually { source.startCount >= 2 })
    let waiting = await session.snapshot()
    #expect(waiting.phase == .waiting)
    #expect(waiting.acceptedCount == 0)
    #expect(waiting.isRequested)
    #expect(source.startCount < 10)

    await session.stop()
    let attemptsAtStop = source.startCount
    try? await Task.sleep(for: .milliseconds(180))
    #expect(source.startCount == attemptsAtStop)
    #expect(await session.snapshot().phase == .stopped)
    await session.shutdown()
}

@Test @MainActor
func disconnectInvalidatesCalibrationAndAllowsANewTimestampEpoch() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: patientTiming)
    await session.start()
    source.send(.sample(sample(10, yaw: 0.4)))
    #expect(await eventually { await session.snapshot().acceptedCount == 1 })
    #expect(await session.calibrate())
    source.send(.sample(sample(10.02, yaw: 0.4)))
    #expect(await eventually { await session.snapshot().latest?.isCalibrated == true })

    source.send(.connection(.disconnected))
    #expect(await eventually { await session.snapshot().phase == .waiting })
    #expect(await session.calibrate() == false)
    source.send(.connection(.connected))
    #expect(await eventually { await session.snapshot().phase == .starting })
    let reconnected = await session.snapshot()
    #expect(reconnected.availability.connection == .connected)
    #expect(reconnected.message?.contains("已連接") == true)
    #expect(reconnected.message?.contains("已斷開") == false)
    source.send(.sample(sample(1, yaw: -0.2)))
    #expect(await eventually { await session.snapshot().acceptedCount == 3 })
    let resumed = await session.snapshot()
    #expect(resumed.phase == .streaming)
    #expect(resumed.latest?.isCalibrated == false)
    #expect(resumed.latest?.relativeQuaternion == nil)
    #expect(resumed.latest?.measuredFrequency == nil)
    #expect(resumed.discontinuityCount == 1)
    #expect(resumed.rejectedCount == 0)
    await session.shutdown()
}

@Test @MainActor
func deniedPermissionDoesNotStartOrRetryAndRevocationStopsAnActiveCapture() async {
    let source = FakeMotionSource()
    source.availability.authorization = .denied
    let session = MotionSession(source: source, timing: recoveryTiming)
    await session.start()
    #expect(await session.snapshot().phase == .permissionDenied)
    #expect(source.startCount == 0)
    try? await Task.sleep(for: .milliseconds(180))
    #expect(source.startCount == 0)

    source.availability.authorization = .authorized
    await session.start()
    #expect(source.startCount == 1)
    source.send(.sample(sample(1)))
    #expect(await eventually { await session.snapshot().phase == .streaming })
    source.availability.authorization = .restricted
    #expect(await eventually { await session.snapshot().phase == .permissionDenied })
    let denied = await session.snapshot()
    #expect(!denied.isRequested)
    #expect(!source.isRunning)
    try? await Task.sleep(for: .milliseconds(180))
    #expect(source.startCount == 1)
    await session.shutdown()
}

@Test @MainActor
func unexpectedStreamEndRetriesAndResetsTheReference() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: recoveryTiming)
    await session.start()
    source.send(.sample(sample(20, yaw: 0.5)))
    #expect(await eventually { await session.snapshot().acceptedCount == 1 })
    #expect(await session.calibrate())
    source.finish()
    #expect(await eventually { await session.snapshot().phase == .interrupted })
    #expect(await eventually { source.startCount >= 2 })
    source.send(.sample(sample(1, yaw: -0.5)))
    #expect(await eventually { await session.snapshot().acceptedCount == 2 })
    let resumed = await session.snapshot()
    #expect(resumed.phase == .streaming)
    #expect(resumed.latest?.isCalibrated == false)
    #expect(resumed.latest?.raw.timestamp == 1)
    #expect(resumed.discontinuityCount == 1)
    await session.shutdown()
}

@Test @MainActor
func slowSubscribersHaveIndependentBoundedBuffersAndVisibleDrops() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: patientTiming)
    let newestOnly = await session.samples(bufferCapacity: 1)
    let newestTwo = await session.samples(bufferCapacity: 2)
    await session.start()
    for index in 1...5 { source.send(.sample(sample(Double(index) * 0.01))) }
    #expect(await eventually { await session.snapshot().acceptedCount == 5 })
    #expect(await session.snapshot().subscriberDroppedCount == 7)

    var firstIterator = newestOnly.makeAsyncIterator()
    var secondIterator = newestTwo.makeAsyncIterator()
    #expect(await firstIterator.next()?.raw.timestamp == 0.05)
    #expect(await secondIterator.next()?.raw.timestamp == 0.04)
    #expect(await secondIterator.next()?.raw.timestamp == 0.05)
    await session.shutdown()
    #expect(await firstIterator.next() == nil)
    #expect(await secondIterator.next() == nil)
}

@Test @MainActor
func shutdownStopsTheSourceAndFinishesSubscribers() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: recoveryTiming)
    let stream = await session.samples()
    await session.start()
    await session.shutdown()
    #expect(!source.isRunning)
    #expect(await session.snapshot().phase == .stopped)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil)
    let attempts = source.startCount
    try? await Task.sleep(for: .milliseconds(180))
    #expect(source.startCount == attempts)
}

@Test @MainActor
func sourceSwitchIsIgnoredWhileCapturingAndReleasesThePreviousSourceWhenStopped() async {
    var source: FakeMotionSource? = FakeMotionSource()
    let weakSource = WeakSourceReference(source)
    let session = MotionSession(source: source, timing: patientTiming)
    await session.start()
    await session.setSource(.simulation)
    #expect(await session.snapshot().source == .headphones)
    #expect(source?.isRunning == true)
    await session.stop()
    #expect(source?.isRunning == false)
    source = nil
    await session.setSource(.simulation)
    #expect(await eventually { weakSource.value == nil })
    let switched = await session.snapshot()
    #expect(switched.source == .simulation)
    #expect(switched.phase == .idle)
    #expect(switched.latest == nil)
    #expect(switched.acceptedCount == 0)
    #expect(switched.availability.authorization == .authorized)
    await session.start()
    #expect(await eventually { await session.snapshot().acceptedCount > 0 })
    #expect(await session.snapshot().source == .simulation)
    await session.shutdown()
}

@Test @MainActor
func aNewCaptureDoesNotCountIngressDropsFromThePreviousCapture() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: patientTiming)
    await session.start()
    source.droppedEventCount = 7
    #expect(await session.snapshot().ingressDroppedCount == 7)
    await session.stop()
    await session.start()
    #expect(await session.snapshot().ingressDroppedCount == 0)
    await session.shutdown()
}

@Test @MainActor
func switchingSourcesClearsIngressDropAccountingFromEarlierAttempts() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: recoveryTiming)
    await session.start()
    source.droppedEventCount = 7
    source.finish()
    #expect(await eventually { source.startCount >= 2 })
    #expect(await session.snapshot().ingressDroppedCount == 7)
    await session.stop()
    await session.setSource(.simulation)
    #expect(await session.snapshot().ingressDroppedCount == 0)
    await session.shutdown()
}

@Test @MainActor
func concurrentLifecycleCommandsSettleToTheSameSourceAndSessionState() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: patientTiming)
    // Exercise actor suspension between main-actor source operations. Final
    // command ordering within each group is deliberately left to the executor.
    for _ in 0..<20 {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    if index.isMultiple(of: 2) { await session.start() }
                    else { await session.stop() }
                }
            }
        }
        let settled = await session.snapshot()
        #expect(source.isRunning == settled.isRequested)
    }

    await session.stop()
    await session.start()
    source.send(.sample(sample(1)))
    #expect(await eventually { await session.snapshot().phase == .streaming })
    #expect(source.isRunning)
    await session.shutdown()
    #expect(!source.isRunning)
}

@Test @MainActor
func callbackFailureIsReportedAndRecoveryStartsWithoutTheOldCalibration() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: patientTiming)
    await session.start()
    source.send(.sample(sample(5)))
    #expect(await eventually { await session.snapshot().acceptedCount == 1 })
    #expect(await session.calibrate())
    source.send(.failure("CMErrorDomain (112): test nil-data error"))
    #expect(await eventually { await session.snapshot().phase == .failed })
    #expect(await session.snapshot().lastError == "CMErrorDomain (112): test nil-data error")
    source.send(.sample(sample(1)))
    #expect(await eventually { await session.snapshot().phase == .streaming })
    let recovered = await session.snapshot()
    #expect(recovered.latest?.isCalibrated == false)
    #expect(recovered.lastError != nil) // Last error remains inspectable after recovery.
    #expect(recovered.acceptedCount == 2)
    await session.shutdown()
}

@Test @MainActor
func releasingTheSessionStopsTheSourceAndFinishesItsStreams() async {
    let source = FakeMotionSource()
    var session: MotionSession? = MotionSession(source: source, timing: patientTiming)
    let stream = await session!.samples()
    await session!.start()
    #expect(source.isRunning)
    session = nil
    #expect(await eventually { !source.isRunning })
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil)
}

@Test @MainActor
func sensorGapBelowTheWatchdogTimeoutUpdatesTheCalibrationMessage() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: SessionTiming(
        interruptionTimeout: 2, retryInterval: 3, watchdogInterval: 0.5
    ))
    await session.start()
    source.send(.sample(sample(10, yaw: 0.3)))
    #expect(await eventually { await session.snapshot().acceptedCount == 1 })
    #expect(await session.calibrate())
    source.send(.sample(sample(10.05, yaw: 0.3)))
    #expect(await eventually { await session.snapshot().latest?.isCalibrated == true })
    let calibratedMessage = await session.snapshot().calibrationMessage

    // Deliver immediately, but simulate a 1.2-second sensor timestamp gap.
    // The processor's continuity limit is exceeded while the two-second
    // runtime watchdog has not fired. UI guidance must follow the processor.
    source.send(.sample(sample(11.25, yaw: 0.8)))
    #expect(await eventually { await session.snapshot().acceptedCount == 3 })
    let recovered = await session.snapshot()
    #expect(recovered.phase == .streaming)
    #expect(recovered.latest?.isCalibrated == false)
    #expect(recovered.latest?.relativeQuaternion == nil)
    #expect(recovered.latest?.measuredFrequency == nil)
    #expect(recovered.discontinuityCount == 1)
    #expect(recovered.calibrationMessage != calibratedMessage)
    #expect(recovered.calibrationMessage?.contains("採樣時間") == true)
    #expect(recovered.calibrationMessage?.contains("重新校準") == true)
    #expect(source.startCount == 1)
    await session.shutdown()
}

@Test @MainActor
func initialPermissionWaitDoesNotRestartTheStreamAndAuthorizationResumesRecovery() async {
    let source = FakeMotionSource()
    source.availability.authorization = .notDetermined
    let session = MotionSession(source: source, timing: recoveryTiming)
    await session.start()
    #expect(source.startCount == 1)
    let initialStops = source.stopCount
    // More than two normal retry intervals: a pending system consent prompt
    // must not have its source repeatedly stopped and recreated.
    try? await Task.sleep(for: .milliseconds(350))
    let pending = await session.snapshot()
    #expect(source.startCount == 1)
    #expect(source.stopCount == initialStops)
    #expect(source.isRunning)
    #expect(pending.isRequested)
    #expect(pending.phase == .waiting)
    #expect(pending.availability.authorization == .notDetermined)
    #expect(pending.message?.contains("運動權限") == true)

    source.availability.authorization = .authorized
    #expect(await eventually { source.startCount >= 2 })
    source.send(.sample(sample(1, yaw: 0.2)))
    #expect(await eventually { await session.snapshot().acceptedCount == 1 })
    let streaming = await session.snapshot()
    #expect(streaming.phase == .streaming)
    #expect(streaming.isRequested)
    #expect(streaming.availability.authorization == .authorized)
    #expect(streaming.latest?.raw.timestamp == 1)
    #expect(source.isRunning)
    await session.shutdown()
}


@Test @MainActor
func automaticCalibrationCannotUseANewerUnverifiedOrStaleSample() async {
    let source = FakeMotionSource()
    let session = MotionSession(source: source, timing: patientTiming)
    await session.start()
    source.send(.sample(sample(10)))
    #expect(await eventually { await session.snapshot().latest?.raw.timestamp == 10 })
    source.send(.sample(sample(10.02, yaw: 0.4)))
    #expect(await eventually { await session.snapshot().latest?.raw.timestamp == 10.02 })
    #expect(await session.calibrate(expectedTimestamp: 10) == false)
    #expect(await session.currentCalibrationID() == nil)
    #expect(await session.calibrate(expectedTimestamp: 10.02))
    let reference = await session.currentCalibrationID()
    try? await Task.sleep(for: .milliseconds(350))
    #expect(await session.calibrate(expectedTimestamp: 10.02) == false)
    #expect(await session.currentCalibrationID() == reference)
    await session.shutdown()
}
