import Foundation
import InteractionCore
import MotionCore
import Testing
@testable import MotionRuntime

@MainActor
private final class InteractionMockSource: MotionSource {
    let kind: MotionSourceKind = .headphones
    var availability = SourceAvailability(isAvailable: true, authorization: .authorized, connection: .connected)
    var droppedEventCount = 0
    private(set) var startCount = 0
    private var continuation: AsyncStream<MotionSourceEvent>.Continuation?

    func start() -> AsyncStream<MotionSourceEvent> {
        startCount += 1
        let pair = AsyncStream<MotionSourceEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        continuation = pair.continuation
        return pair.stream
    }

    func stop() { continuation?.finish(); continuation = nil }
    func send(_ sample: MotionSample) { continuation?.yield(.sample(sample)) }
    func disconnect() { continuation?.yield(.connection(.disconnected)) }
}

@MainActor
private func waitForInteraction(_ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

@MainActor
private final class InteractionFixture {
    let source: InteractionMockSource
    let motion: MotionSession
    let interactions: InteractionSession
    private var timestamp = 10.0

    init() {
        let source = InteractionMockSource()
        self.source = source
        let motion = MotionSession(source: source, timing: SessionTiming(interruptionTimeout: 10, retryInterval: 10, watchdogInterval: 0.02))
        self.motion = motion
        interactions = InteractionSession(motion: motion, activitySource: UnavailableActivitySource(reason: "此測試只驗證姿態資料流。"))
    }

    func activate(privacy: Bool = true) async {
        await interactions.activate()
        await motion.setSmoothing(enabled: false)
        if privacy { await interactions.setPrivacyEnabled(true) }
        else { await motion.start() }
    }

    /// Uses actual MotionProcessor quaternion calibration. Sensor timestamps are
    /// controlled while callback receipt clocks remain real and fresh. Wait for
    /// both pipeline stages before asserting outcomes or issuing the next frame.
    func send(yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
              calibrated: Bool = true, allowCompletion: Bool = false,
              reference: Quaternion? = nil) async {
        timestamp += 0.1
        let time = timestamp
        let angles = AttitudeAngles(yaw: yaw * .pi / 180, pitch: pitch * .pi / 180, roll: roll * .pi / 180)
        let localRotation = Quaternion(angles: angles)
        let orientation = reference?.multiplied(by: localRotation) ?? localRotation
        source.send(MotionSample(
            timestamp: time, receivedAt: Date(), receivedUptime: ProcessInfo.processInfo.systemUptime,
            attitude: orientation.eulerAngles, quaternion: orientation,
            rotationRate: .zero, userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1)
        ))
        #expect(await waitForInteraction { await self.motion.snapshot().latest?.raw.timestamp == time })
        if calibrated {
            #expect(await waitForInteraction {
                let snapshot = await self.interactions.snapshot()
                return snapshot.latestPose?.timestamp == time || (allowCompletion && snapshot.exercise.phase == .completed)
            })
        } else {
            #expect(await waitForInteraction { await self.interactions.snapshot().latestPose == nil })
        }
    }

    func calibrateAndArmPrivacy() async {
        await send(calibrated: false)
        #expect(await interactions.calibrateNeutral())
        for _ in 0..<7 { await send() }
        #expect(await interactions.snapshot().privacy.phase == .watching)
    }

    func triggerShield() async {
        for yaw in [10.0, 20, 30, 40] { await send(yaw: yaw) }
        for _ in 0..<7 { await send(yaw: 40) }
        #expect(await interactions.snapshot().privacy.isShielded)
    }

    func shutdown() async { await interactions.shutdown(); await motion.shutdown() }
}

@Test @MainActor
func featuresShareCaptureAndAStoppedStreamCannotExposeTheShield() async {
    let fixture = InteractionFixture()
    await fixture.activate()
    await fixture.calibrateAndArmPrivacy()
    await fixture.interactions.setPrivacyEnabled(true)
    #expect(fixture.source.startCount == 1)
    await fixture.triggerShield()
    #expect(await fixture.interactions.startExercise() == false)
    await fixture.motion.stop()
    #expect(await waitForInteraction { await fixture.interactions.snapshot().privacy.requiresManualReveal })
    #expect(await fixture.interactions.snapshot().privacy.isShielded)

    await fixture.interactions.hideShield()
    #expect(await fixture.interactions.startExercise())
    #expect(fixture.source.startCount == 2) // the same source was restarted after explicit stop
    await fixture.send(calibrated: false)
    #expect(await fixture.interactions.calibrateExercise())
    for yaw in [0.0, 10, 20, 30, 40] { await fixture.send(yaw: yaw) }
    for _ in 0..<8 { await fixture.send(yaw: 40) }
    let practicing = await fixture.interactions.snapshot()
    #expect(practicing.exercise.isActive)
    #expect(practicing.privacy.automaticEnabled)
    #expect(practicing.privacy.isSuspended)
    #expect(!practicing.privacy.isShielded)
    #expect(fixture.source.startCount == 2)

    await fixture.interactions.endExercise()
    let ended = await fixture.interactions.snapshot()
    #expect(!ended.exercise.isActive)
    #expect(ended.privacy.automaticEnabled)
    #expect(!ended.privacy.isSuspended)
    #expect(ended.privacy.phase == .needsCalibration)
    #expect(await fixture.motion.currentCalibrationID() == nil)
    await fixture.shutdown()
}

@Test @MainActor
func externalDebugRecalibrationCannotRevealAnAutomaticallyShieldedScreen() async {
    let fixture = InteractionFixture()
    await fixture.activate()
    await fixture.calibrateAndArmPrivacy()
    await fixture.triggerShield()
    let previousReference = await fixture.motion.currentCalibrationID()
    #expect(await fixture.motion.calibrate()) // the original debug interface shares this session
    #expect(await fixture.motion.currentCalibrationID() != previousReference)
    for _ in 0..<10 { await fixture.send(yaw: 40) } // neutral in the new reference
    let protected = await fixture.interactions.snapshot()
    #expect(protected.privacy.isShielded)
    #expect(protected.privacy.requiresManualReveal)
    await fixture.interactions.hideShield()
    #expect(await fixture.interactions.snapshot().privacy.isShielded == false)
    await fixture.shutdown()
}

@Test @MainActor
func waitingUncalibratedBetweenExercisesDoesNotInvalidateTheNextFreshCalibration() async {
    let fixture = InteractionFixture()
    await fixture.activate()
    #expect(await fixture.interactions.startExercise())
    await fixture.send(calibrated: false)
    #expect(await fixture.interactions.calibrateExercise())
    await fixture.send()
    await fixture.interactions.endExercise()
    // Raw motion continues throughout the wait. This is not a sensor outage;
    // the next reference must not inherit the previous exercise's receipt time.
    for _ in 0..<6 {
        try? await Task.sleep(for: .milliseconds(80))
        await fixture.send(calibrated: false)
    }
    #expect(await fixture.interactions.startExercise())
    #expect(await fixture.interactions.calibrateExercise())
    await fixture.send()
    let restarted = await fixture.interactions.snapshot()
    #expect(restarted.exercise.phase == .approaching)
    #expect(restarted.exercise.completedCount == 0)
    #expect(restarted.latestPose != nil)
    await fixture.shutdown()
}

@Test @MainActor
func uncalibratedMotionCannotTriggerPrivacyOrCompleteExercise() async {
    let fixture = InteractionFixture()
    await fixture.activate()
    for _ in 0..<10 { await fixture.send(yaw: 60, calibrated: false) }
    #expect(await fixture.interactions.snapshot().privacy.isShielded == false)
    #expect(await fixture.interactions.startExercise())
    for _ in 0..<10 { await fixture.send(yaw: -20, calibrated: false) }
    let waiting = await fixture.interactions.snapshot()
    #expect(waiting.exercise.phase == .awaitingCalibration)
    #expect(waiting.exercise.completedCount == 0)
    #expect(waiting.exercise.elapsed == 0)
    await fixture.shutdown()
}

@Test @MainActor
func aCompleteObservedExerciseRestoresPrivacyPreferenceAndClearsItsReference() async {
    let fixture = InteractionFixture()
    await fixture.activate()
    #expect(await fixture.interactions.startExercise())
    await fixture.send(calibrated: false)
    #expect(await fixture.interactions.calibrateExercise())
    for index in 0..<5 {
        let target = await fixture.interactions.snapshot().exercise.target
        for _ in 0..<8 { await fixture.send(yaw: target.yaw, pitch: target.pitch, roll: target.roll) }
        #expect(await fixture.interactions.snapshot().exercise.phase == .returning)
        for _ in 0..<6 { await fixture.send(allowCompletion: index == 4) }
    }
    #expect(await waitForInteraction { await fixture.motion.currentCalibrationID() == nil })
    let finished = await fixture.interactions.snapshot()
    #expect(finished.exercise.phase == .completed)
    #expect(finished.exercise.completedCount == 5)
    #expect(finished.exercise.skippedCount == 0)
    #expect(finished.privacy.automaticEnabled)
    #expect(!finished.privacy.isSuspended)
    #expect(finished.privacy.phase == .needsCalibration)
    #expect(fixture.source.startCount == 1)
    await fixture.shutdown()
}

@Test @MainActor
func exerciseAxesRemainHeadLocalAcrossDifferentCalibrationHeadings() async throws {
    let fixture = InteractionFixture()
    await fixture.activate()
    for heading in [90.0, -90, 180] {
        // Keep one capture session while starting and calibrating a fresh
        // exercise at each global heading. Body-local movement composes on the
        // right; world-relative deltas would swap pitch/roll at ±90°.
        let reference = Quaternion(angles: AttitudeAngles(yaw: heading * .pi / 180, pitch: 0, roll: 0))
        #expect(await fixture.interactions.startExercise())
        await fixture.send(calibrated: false, reference: reference)
        #expect(await fixture.interactions.calibrateExercise())
        await fixture.send(reference: reference)
        let neutral = try #require(await fixture.interactions.snapshot().latestPose)
        #expect(abs(neutral.yaw) < 1e-8)
        #expect(abs(neutral.pitch) < 1e-8)
        #expect(abs(neutral.roll) < 1e-8)

        for index in 0..<5 {
            let target = await fixture.interactions.snapshot().exercise.target
            for _ in 0..<8 {
                await fixture.send(yaw: target.yaw, pitch: target.pitch, roll: target.roll, reference: reference)
            }
            let acquired = await fixture.interactions.snapshot()
            let pose = try #require(acquired.latestPose)
            #expect(abs(pose.yaw - target.yaw) < 1e-8)
            #expect(abs(pose.pitch - target.pitch) < 1e-8)
            #expect(abs(pose.roll - target.roll) < 1e-8)
            #expect(acquired.exercise.phase == .returning)
            for _ in 0..<6 { await fixture.send(allowCompletion: index == 4, reference: reference) }
        }
        #expect(await waitForInteraction { await fixture.motion.currentCalibrationID() == nil })
        #expect(await fixture.interactions.snapshot().exercise.completedCount == 5)
    }
    #expect(fixture.source.startCount == 1)
    await fixture.shutdown()
}

@Test @MainActor
func losingHeadphoneDataWhileArmedRaisesAShieldThatNeedsManualReveal() async {
    for disconnect in [false, true] {
        let fixture = InteractionFixture()
        await fixture.activate()
        await fixture.calibrateAndArmPrivacy()
        // AirPods put in the case or out of range: either an explicit
        // disconnect or the stream simply stops while capture is still wanted.
        if disconnect { fixture.source.disconnect() }
        #expect(await waitForInteraction { await fixture.interactions.snapshot().privacy.isShielded })
        let lost = await fixture.interactions.snapshot()
        #expect(lost.privacy.requiresManualReveal)
        #expect(lost.privacy.phase == .shielded)
        #expect(await fixture.motion.snapshot().isRequested)
        await fixture.interactions.hideShield()
        #expect(await fixture.interactions.snapshot().privacy.isShielded == false)
        await fixture.shutdown()
    }
}

@Test @MainActor
func aShortStreamHiccupResumesWithoutAShieldAndRearmsAtNeutral() async {
    let fixture = InteractionFixture()
    await fixture.activate()
    await fixture.calibrateAndArmPrivacy()
    #expect(await waitForInteraction { await fixture.interactions.snapshot().privacy.dataLossSince != nil })
    #expect(await fixture.interactions.snapshot().privacy.isShielded == false)
    for _ in 0..<7 { await fixture.send() }
    let resumed = await fixture.interactions.snapshot()
    #expect(!resumed.privacy.isShielded)
    #expect(resumed.privacy.dataLossSince == nil)
    #expect(resumed.privacy.phase == .watching)
    // Keep the stream alive past the grace: the cancelled loss never fires late.
    for _ in 0..<12 {
        try? await Task.sleep(for: .milliseconds(80))
        await fixture.send()
    }
    #expect(await fixture.interactions.snapshot().privacy.isShielded == false)
    await fixture.shutdown()
}

@Test @MainActor
func sleepWhileArmedShieldsButOptingOutOnlyDisarms() async {
    let fixture = InteractionFixture()
    await fixture.activate()
    await fixture.calibrateAndArmPrivacy()
    await fixture.interactions.invalidateSensor(reason: "系統進入睡眠")
    #expect(await fixture.interactions.snapshot().privacy.requiresManualReveal)
    await fixture.shutdown()

    let optedOut = InteractionFixture()
    await optedOut.activate()
    await optedOut.interactions.updatePrivacySettings(PrivacySettings(shieldOnDataLossEnabled: false))
    await optedOut.calibrateAndArmPrivacy()
    await optedOut.interactions.invalidateSensor(reason: "系統進入睡眠")
    try? await Task.sleep(for: .milliseconds(1200)) // past the grace for the stalled stream too
    let disarmed = await optedOut.interactions.snapshot()
    #expect(!disarmed.privacy.isShielded)
    #expect(disarmed.privacy.phase == .needsCalibration)
    await optedOut.shutdown()
}

@Test @MainActor
func stoppingCaptureOnPurposeDisarmsWithoutShielding() async {
    let fixture = InteractionFixture()
    await fixture.activate()
    await fixture.calibrateAndArmPrivacy()
    await fixture.motion.stop()
    #expect(await waitForInteraction { await fixture.interactions.snapshot().latestPose == nil })
    try? await Task.sleep(for: .milliseconds(1200))
    let stopped = await fixture.interactions.snapshot()
    #expect(!stopped.privacy.isShielded)
    #expect(stopped.privacy.automaticEnabled)
    #expect(stopped.privacy.phase == .needsCalibration)
    await fixture.shutdown()
}

@Test @MainActor
func dataLossDuringOrAfterTheExerciseDoesNotShield() async {
    let fixture = InteractionFixture()
    await fixture.activate()
    await fixture.calibrateAndArmPrivacy()
    #expect(await fixture.interactions.startExercise())
    await fixture.send(calibrated: false)
    #expect(await fixture.interactions.calibrateExercise())
    await fixture.send()
    try? await Task.sleep(for: .milliseconds(1200)) // stream stalls mid-exercise
    let practicing = await fixture.interactions.snapshot()
    #expect(practicing.exercise.isActive)
    #expect(!practicing.privacy.isShielded)
    #expect(practicing.latestPose == nil)

    await fixture.interactions.endExercise()
    await fixture.send(calibrated: false)
    try? await Task.sleep(for: .milliseconds(1200))
    let ended = await fixture.interactions.snapshot()
    #expect(!ended.privacy.isShielded)
    #expect(ended.privacy.phase == .needsCalibration)
    await fixture.shutdown()
}
