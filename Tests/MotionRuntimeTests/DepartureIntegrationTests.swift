import Foundation
import InteractionCore
import MotionCore
import Testing
@testable import MotionRuntime

@MainActor
private final class DepartureMotionSource: MotionSource {
    let kind: MotionSourceKind = .headphones
    var availability = SourceAvailability(isAvailable: true, authorization: .authorized, connection: .connected)
    var droppedEventCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var continuation: AsyncStream<MotionSourceEvent>.Continuation?

    func start() -> AsyncStream<MotionSourceEvent> {
        startCount += 1
        let pair = AsyncStream<MotionSourceEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        continuation = pair.continuation
        return pair.stream
    }

    func stop() { stopCount += 1; continuation?.finish(); continuation = nil }
    func send(_ sample: MotionSample) { continuation?.yield(.sample(sample)) }
}

@MainActor
private final class DepartureActivitySource: ActivitySource {
    var availability = ActivityAvailability(isAvailable: true, authorization: .authorized,
                                          connection: .connected, isActive: false)
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var continuation: AsyncStream<ActivitySourceEvent>.Continuation?
    private var retired: AsyncStream<ActivitySourceEvent>.Continuation?

    func start() -> AsyncStream<ActivitySourceEvent> {
        startCount += 1
        availability.isActive = true
        let pair = AsyncStream<ActivitySourceEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation = pair.continuation
        return pair.stream
    }

    func stop() {
        stopCount += 1
        availability.isActive = false
        retired = continuation
        continuation?.finish()
        continuation = nil
    }

    func send(_ event: ActivitySourceEvent) {
        if case .connection(let connection) = event { availability.connection = connection }
        if case .failure(let reason) = event { availability.isActive = false; availability.reason = reason }
        continuation?.yield(event)
    }

    func sendRetired(_ event: ActivitySourceEvent) { retired?.yield(event) }
}

@MainActor
private func eventuallyDeparture(_ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

@MainActor
private final class DepartureFixture {
    let source = DepartureMotionSource()
    let activity: DepartureActivitySource?
    let motion: MotionSession
    let session: InteractionSession
    private var sensorTime = 1.0

    init(unavailableReason: String? = nil) {
        let motion = MotionSession(source: source,
                                   timing: SessionTiming(interruptionTimeout: 10, retryInterval: 10, watchdogInterval: 0.02))
        self.motion = motion
        let activity = unavailableReason == nil ? DepartureActivitySource() : nil
        self.activity = activity
        let activitySource: any ActivitySource = activity ?? UnavailableActivitySource(reason: unavailableReason!)
        session = InteractionSession(motion: motion, activitySource: activitySource,
                                     departure: DepartureMachine(holdDuration: 2, rearmDelay: 0),
                                     returnCalibrationHold: 0.1)
    }

    func activateAndCalibrate() async throws {
        await motion.setSmoothing(enabled: false)
        await session.activate()
        await session.setPrivacyEnabled(true)
        await send()
        let calibrated = await session.calibrateNeutral()
        try #require(calibrated)
        await pump(for: 0.7)
        try #require(await session.snapshot().privacy.phase == .watching)
        try #require(await session.snapshot().departure.isDeskConfirmed)
        if activity != nil {
            try #require(await session.snapshot().activityAvailability.isActive)
        }
    }

    func send(yaw: Double = 0, rate: Double = 0, scale: Double = 1) async {
        sensorTime += 0.04
        let time = sensorTime
        let angles = AttitudeAngles(yaw: yaw * .pi / 180, pitch: 0, roll: 0)
        let q = Quaternion(angles: angles)
        source.send(MotionSample(timestamp: time, receivedAt: Date(),
                                 receivedUptime: ProcessInfo.processInfo.systemUptime,
                                 attitude: angles,
                                 quaternion: Quaternion(x: q.x * scale, y: q.y * scale, z: q.z * scale, w: q.w * scale),
                                 rotationRate: Vector3(x: 0, y: 0, z: rate * .pi / 180),
                                 userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1)))
        #expect(await eventuallyDeparture { await self.motion.snapshot().latest?.raw.timestamp == time })
        await Task.yield()
    }

    func pump(for seconds: Double, yaw: Double = 0) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        repeat {
            await send(yaw: yaw)
            try? await Task.sleep(for: .milliseconds(40))
        } while clock.now < deadline
    }

    func observation(walking: Bool = true, confidence: ActivityConfidence = .high,
                     age: Double = 0) -> ActivityObservation {
        let now = ProcessInfo.processInfo.systemUptime
        let date = Date()
        return ActivityObservation(timestamp: now, startDate: date.addingTimeInterval(-age),
                                   receivedAt: date, receivedUptime: now, confidence: confidence,
                                   stationary: !walking, walking: walking)
    }

    func triggerTurnShield() async throws {
        for yaw in [10.0, 20, 30, 40] {
            await send(yaw: yaw)
            try? await Task.sleep(for: .milliseconds(40))
        }
        await pump(for: 0.7, yaw: 40)
        try #require(await session.snapshot().privacy.isShielded)
        try #require(await session.snapshot().privacy.requiresManualReveal == false)
    }

    func returnToNeutral() async {
        for yaw in [30.0, 20, 10, 0] {
            await send(yaw: yaw)
            try? await Task.sleep(for: .milliseconds(40))
        }
        await pump(for: 0.7)
    }

    func shutdown() async { await session.shutdown(); await motion.shutdown() }
}

@Test @MainActor
func oneWalkingEventLatchesUntilManualRevealAndFreshStableReturnCalibration() async throws {
    let fixture = DepartureFixture()
    try await fixture.activateAndCalibrate()
    let walking = fixture.observation()
    fixture.activity?.send(.observation(walking))
    await fixture.pump(for: 2.2)
    let held = await fixture.session.snapshot()
    #expect(held.privacy.isDepartureLatched)
    #expect(held.privacy.phase == .departureHeld)
    #expect(held.privacy.requiresManualReveal)
    #expect(fixture.source.startCount == 1)
    fixture.activity?.send(.observation(fixture.observation(walking: false)))
    await fixture.pump(for: 0.7)
    #expect(await fixture.session.snapshot().privacy.isDepartureLatched)
    let oldID = await fixture.motion.currentCalibrationID()
    await fixture.session.hideShield()
    #expect(await fixture.session.snapshot().privacy.isShielded == false)
    #expect(await fixture.session.snapshot().returnCalibrationPending)
    await fixture.pump(for: 0.9)
    let returned = await fixture.session.snapshot()
    #expect(!returned.returnCalibrationPending)
    #expect(returned.departure.isDeskConfirmed)
    #expect(returned.privacy.phase == .watching)
    #expect(await fixture.motion.currentCalibrationID() != oldID)
    fixture.activity?.send(.observation(walking))
    await fixture.pump(for: 2.2)
    #expect(await fixture.session.snapshot().privacy.isShielded == false)
    #expect(fixture.source.startCount == 1)
    await fixture.shutdown()
    #expect(fixture.activity?.availability.isActive == false)
    #expect((fixture.activity?.stopCount ?? 0) >= 1)
    #expect(fixture.source.stopCount >= 1)
}

@Test @MainActor
func walkingUpgradesTemporaryShieldAndControlChangesNeverRevealIt() async throws {
    let fixture = DepartureFixture()
    try await fixture.activateAndCalibrate()
    try await fixture.triggerTurnShield()
    fixture.activity?.send(.observation(fixture.observation()))
    await fixture.pump(for: 2.2, yaw: 40)
    #expect(await fixture.session.snapshot().privacy.isDepartureLatched)
    await fixture.returnToNeutral()
    #expect(await fixture.session.snapshot().privacy.isShielded)
    await fixture.session.invalidateSensor(reason: "測試睡眠與資料中斷")
    #expect(await fixture.motion.calibrate())
    await fixture.pump(for: 0.3)
    #expect(await fixture.session.snapshot().privacy.isDepartureLatched)
    await fixture.session.updatePrivacySettings(PrivacySettings(departureDetectionEnabled: false))
    await fixture.session.setPrivacyEnabled(false)
    #expect(await fixture.session.snapshot().privacy.isShielded)
    await fixture.session.hideShield()
    #expect(await fixture.session.snapshot().privacy.isShielded == false)
    await fixture.shutdown()
}

@Test @MainActor
func activityDisconnectionOrFailureKeepsTurnShieldBeforeMotionStops() async throws {
    for isFailure in [false, true] {
        let fixture = DepartureFixture()
        try await fixture.activateAndCalibrate()
        try await fixture.triggerTurnShield()
        if isFailure { fixture.activity?.send(.failure("測試活動來源中斷")) }
        else { fixture.activity?.send(.connection(.disconnected)) }
        await fixture.returnToNeutral()
        #expect(await fixture.session.snapshot().privacy.isShielded)
        #expect(await fixture.session.snapshot().privacy.requiresManualReveal)
        #expect(await fixture.session.snapshot().departure.isDeskConfirmed == false)
        #expect(await fixture.motion.snapshot().phase == .streaming)
        await fixture.shutdown()
    }
}

@Test @MainActor
func exerciseSuspendsActivityAndOldGenerationCannotTriggerOnExit() async throws {
    let fixture = DepartureFixture()
    try await fixture.activateAndCalibrate()
    let old = fixture.observation()
    fixture.activity?.send(.observation(old))
    await fixture.pump(for: 0.1)
    let starts = fixture.activity?.startCount
    #expect(await fixture.session.startExercise())
    #expect(fixture.activity?.availability.isActive == false)
    fixture.activity?.sendRetired(.observation(old))
    await fixture.pump(for: 2.2)
    #expect(await fixture.session.snapshot().privacy.isShielded == false)
    #expect(fixture.activity?.startCount == starts)
    #expect(fixture.source.startCount == 1)
    await fixture.session.endExercise()
    await fixture.pump(for: 0.3)
    #expect(await fixture.session.snapshot().departure.isDeskConfirmed == false)
    #expect(await fixture.session.calibrateNeutral())
    await fixture.pump(for: 0.7)
    fixture.activity?.sendRetired(.observation(old))
    fixture.activity?.send(.observation(old))
    await fixture.pump(for: 2.2)
    #expect(await fixture.session.snapshot().privacy.isShielded == false)
    await fixture.shutdown()
}

@Test @MainActor
func unavailableActivityKeepsItsReasonAndPreservesOrdinaryTurnRecovery() async throws {
    let reason = "離座識別需要 macOS 15 或更新版本。"
    let fixture = DepartureFixture(unavailableReason: reason)
    try await fixture.activateAndCalibrate()
    #expect(await fixture.session.snapshot().departureStatus.contains(reason))
    try await fixture.triggerTurnShield()
    await fixture.returnToNeutral()
    #expect(await fixture.session.snapshot().privacy.isShielded == false)
    #expect(await fixture.session.snapshot().privacy.isDepartureLatched == false)
    #expect(await fixture.session.snapshot().departureStatus.contains(reason))
    await fixture.shutdown()
}

@Test @MainActor
func staleAndLowConfidenceActivityCannotLatchAndExternalCalibrationInvalidatesDesk() async throws {
    let fixture = DepartureFixture()
    try await fixture.activateAndCalibrate()
    fixture.activity?.send(.observation(fixture.observation(confidence: .low)))
    await fixture.pump(for: 2.2)
    #expect(await fixture.session.snapshot().privacy.isShielded == false)
    fixture.activity?.send(.observation(fixture.observation(age: 6)))
    await fixture.pump(for: 2.2)
    #expect(await fixture.session.snapshot().privacy.isShielded == false)
    #expect(await fixture.motion.calibrate())
    await fixture.pump(for: 0.7)
    #expect(await fixture.session.snapshot().departure.isDeskConfirmed == false)
    fixture.activity?.send(.observation(fixture.observation()))
    await fixture.pump(for: 2.2)
    #expect(await fixture.session.snapshot().privacy.isShielded == false)
    await fixture.shutdown()
}

@Test @MainActor
func availableActivityPreservesOrdinaryTurnAndAutomaticNeutralRecovery() async throws {
    let fixture = DepartureFixture()
    try await fixture.activateAndCalibrate()
    #expect(await fixture.session.snapshot().activityAvailability.isActive)
    try await fixture.triggerTurnShield()
    #expect(await fixture.session.snapshot().privacy.isDepartureLatched == false)
    await fixture.returnToNeutral()
    let returned = await fixture.session.snapshot()
    #expect(!returned.privacy.isShielded)
    #expect(returned.privacy.phase == .watching)
    #expect(returned.departure.isDeskConfirmed)
    #expect(fixture.source.startCount == 1)
    await fixture.shutdown()
}

@Test @MainActor
func scaledQuaternionsCannotHideContinuedTurningDuringReturnCalibration() async throws {
    let fixture = DepartureFixture()
    try await fixture.activateAndCalibrate()
    fixture.activity?.send(.observation(fixture.observation()))
    await fixture.pump(for: 2.2)
    try #require(await fixture.session.snapshot().privacy.isDepartureLatched)
    await fixture.session.hideShield()
    // 合法幅值偏差不應掩蓋姿態改變；角速度在此刻意設低，以獨立驗證四元數檢查。
    for index in 0..<10 {
        await fixture.send(yaw: Double(index) * 4, rate: 0, scale: 1.2)
        try? await Task.sleep(for: .milliseconds(40))
    }
    #expect(await fixture.session.snapshot().returnCalibrationPending)
    #expect(await fixture.motion.currentCalibrationID() == nil)
    #expect(await fixture.session.snapshot().privacy.isShielded == false)
    await fixture.pump(for: 0.9, yaw: 36)
    let settled = await fixture.session.snapshot()
    #expect(!settled.returnCalibrationPending)
    #expect(settled.departure.isDeskConfirmed)
    #expect(settled.privacy.phase == .watching)
    await fixture.shutdown()
}


@Test @MainActor
func aPoseGapBelowHealthTimeoutStillInvalidatesTheDeskBaseline() async throws {
    let fixture = DepartureFixture()
    try await fixture.activateAndCalibrate()
    try? await Task.sleep(for: .milliseconds(270))
    await fixture.send()
    #expect(await eventuallyDeparture { await fixture.session.snapshot().departure.isDeskConfirmed == false })
    await fixture.pump(for: 0.7)
    #expect(await fixture.session.snapshot().departure.isDeskConfirmed == false)
    #expect(await fixture.session.snapshot().privacy.isShielded == false)
    await fixture.shutdown()
}
