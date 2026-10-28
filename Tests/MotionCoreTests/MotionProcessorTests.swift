import Foundation
import Testing
@testable import MotionCore

private func sample(_ timestamp: Double, quaternion: Quaternion = .identity,
                    attitude: AttitudeAngles = .zero,
                    rate: Vector3 = .zero, acceleration: Vector3 = .zero, receipt: Double? = nil) -> MotionSample {
    MotionSample(timestamp: timestamp, receivedAt: Date(timeIntervalSince1970: 1_000 + timestamp),
                 receivedUptime: receipt ?? timestamp + 10, attitude: attitude, quaternion: quaternion,
                 rotationRate: rate, userAcceleration: acceleration,
                 gravity: Vector3(x: 0, y: 0, z: -1))
}

private func equivalent(_ a: Quaternion, _ b: Quaternion, tolerance: Double = 1e-9) -> Bool {
    guard let x = a.normalized(), let y = b.normalized() else { return false }
    return abs(abs(x.dot(y)) - 1) < tolerance
}

@Test func rawSampleIsPreservedAndCalibrationIsExplicit() throws {
    var processor = MotionProcessor()
    #expect(processor.calibrate() == false)
    let rawAngles = AttitudeAngles(yaw: 0.123, pitch: -0.456, roll: 0.789)
    // Deliberately use different raw Euler values to prove they are not regenerated.
    let raw = sample(10, attitude: rawAngles)
    let resultValue = processor.process(raw)
    let result = try #require(resultValue)
    #expect(result.raw == raw)
    #expect(result.relativeQuaternion == nil)
    #expect(result.relativeAngles == nil)
    #expect(result.headRelativeQuaternion == nil)
    #expect(result.headRelativeAngles == nil)
    #expect(!result.isCalibrated)
    #expect(result.measuredFrequency == nil)
    #expect(result.smoothingEnabled)
}

@Test func calibrationAtArbitraryOrientationProducesIdentity() throws {
    var processor = MotionProcessor()
    let q = Quaternion(x: 0.2, y: -0.3, z: 0.4, w: sqrt(0.71))
    _ = processor.process(sample(10, quaternion: q))
    #expect(processor.calibrate() == true)
    let resultValue = processor.process(sample(10.01, quaternion: q))
    let result = try #require(resultValue)
    #expect(equivalent(try #require(result.relativeQuaternion), .identity))
    #expect(equivalent(result.displayQuaternion, .identity))
    #expect(equivalent(try #require(result.headRelativeQuaternion), .identity))
    #expect(abs(result.displayAngles.yaw) < 1e-12)
    #expect(abs(result.displayAngles.pitch) < 1e-12)
    #expect(abs(result.displayAngles.roll) < 1e-12)
}

@Test func relativeRotationUsesCurrentTimesReferenceInverse() throws {
    var processor = MotionProcessor(smoothingTimeConstant: 0)
    let h = sqrt(0.5)
    let reference = Quaternion(x: h, y: 0, z: 0, w: h) // X +90°
    _ = processor.process(sample(0, quaternion: reference))
    #expect(processor.calibrate() == true)
    // Y(+90°) × X(+90°), written independently of the production multiplication.
    let current = Quaternion(x: 0.5, y: 0.5, z: -0.5, w: 0.5)
    let resultValue = processor.process(sample(0.1, quaternion: current))
    let result = try #require(resultValue)
    let expected = Quaternion(x: 0, y: h, z: 0, w: h)
    #expect(!result.smoothingEnabled)
    #expect(equivalent(try #require(result.relativeQuaternion), expected))
    #expect(abs(result.displayAngles.roll - .pi / 2) < 1e-10)
    #expect(abs(result.displayAngles.pitch) < 1e-10)
    #expect(abs(result.displayAngles.yaw) < 1e-10)
}

@Test func yawWrapUsesShortestArcAndDoesNotAverageThroughZero() throws {
    var processor = MotionProcessor(smoothingTimeConstant: 0.1 / log(2))
    let left = Quaternion(angles: AttitudeAngles(yaw: 179 * .pi / 180, pitch: 0, roll: 0))
    let right = Quaternion(angles: AttitudeAngles(yaw: -179 * .pi / 180, pitch: 0, roll: 0))
    _ = processor.process(sample(0, quaternion: left))
    let resultValue = processor.process(sample(0.1, quaternion: right))
    let result = try #require(resultValue)
    #expect(abs(abs(result.displayAngles.yaw) - .pi) < 1e-8)
}

@Test func invalidAndNonmonotonicSamplesAreRejectedWithoutChangingReference() throws {
    var processor = MotionProcessor()
    _ = processor.process(sample(1))
    #expect(processor.calibrate() == true)
    #expect(processor.process(sample(1)) == nil)
    #expect(processor.process(sample(0.5)) == nil)
    #expect(processor.process(sample(.nan)) == nil)
    #expect(processor.process(sample(1.01, quaternion: Quaternion(x: 0, y: 0, z: 0, w: 0))) == nil)
    #expect(processor.process(sample(1.01, quaternion: Quaternion(x: 0, y: 0, z: 0, w: 50))) == nil)
    #expect(processor.process(sample(1.01, rate: Vector3(x: .infinity, y: 0, z: 0))) == nil)
    #expect(processor.acceptedCount == 1)
    #expect(processor.rejectedCount == 6)
    #expect(processor.lastRejection != nil)
    let recoveredValue = processor.process(sample(1.02))
    let recovered = try #require(recoveredValue)
    #expect(recovered.isCalibrated)
    #expect(processor.acceptedCount == 2)
    #expect(processor.lastRejection == nil)
}

@Test func frequencyMeasuresIrregularTimestampsAndIgnoresWallClockDelivery() throws {
    var processor = MotionProcessor()
    var result: ProcessedMotion?
    for t in [10.0, 10.08, 10.2, 10.3, 10.5] {
        let value = sample(t)
        result = processor.process(MotionSample(
            timestamp: value.timestamp, receivedAt: Date(timeIntervalSince1970: 42),
            receivedUptime: 123, attitude: value.attitude, quaternion: value.quaternion,
            rotationRate: value.rotationRate, userAcceleration: value.userAcceleration,
            gravity: value.gravity
        ))
    }
    #expect(abs(try #require(result?.measuredFrequency) - 8) < 1e-10)
    #expect(processor.process(sample(10.5)) == nil)
    result = processor.process(sample(10.6))
    #expect(abs(try #require(result?.measuredFrequency) - 5 / 0.6) < 1e-10)
}

@Test func frequencyWindowDropsOldRateHistory() throws {
    var processor = MotionProcessor()
    for i in 0...20 { _ = processor.process(sample(Double(i) * 0.05)) }
    var result: ProcessedMotion?
    for i in 1...30 { result = processor.process(sample(1 + Double(i) * 0.1)) }
    #expect(abs(try #require(result?.measuredFrequency) - 10) < 1e-8)
}

@Test func longGapClearsReferenceFilterAndRateButKeepsCounters() throws {
    var processor = MotionProcessor(smoothingTimeConstant: 1)
    _ = processor.process(sample(10))
    _ = processor.process(sample(10.5))
    #expect(processor.calibrate() == true)
    let orientation = Quaternion(angles: AttitudeAngles(yaw: 1, pitch: 0, roll: 0))
    let resultValue = processor.process(sample(14, quaternion: orientation))
    let result = try #require(resultValue)
    #expect(!result.isCalibrated)
    #expect(result.measuredFrequency == nil)
    #expect(equivalent(result.displayQuaternion, orientation))
    #expect(processor.discontinuityCount == 1)
    #expect(processor.acceptedCount == 3)
    processor.resetContinuity()
    #expect(processor.discontinuityCount == 2)
    #expect(processor.calibrate() == false)
    // A new stream may start on a lower sensor timestamp after explicit reset.
    #expect(processor.process(sample(1)) != nil)
    processor.reset()
    #expect(processor.acceptedCount == 0)
    #expect(processor.rejectedCount == 0)
    #expect(processor.discontinuityCount == 0)
    #expect(processor.calibrate() == false)
}

@Test(arguments: [1.1, 2.5, 2.9])
func recoverableClockAlignedGapPreservesCalibrationAndResetsFiltering(gap: Double) throws {
    var processor = MotionProcessor(smoothingTimeConstant: 1)
    let reference = Quaternion(angles: AttitudeAngles(yaw: 0.4, pitch: 0, roll: 0))
    _ = processor.process(sample(10, quaternion: reference))
    #expect(processor.calibrate() == true)
    let id = processor.calibrationID
    let target = Quaternion(angles: AttitudeAngles(yaw: 0.6, pitch: 0, roll: 0))
    let processed = processor.process(sample(10 + gap, quaternion: target))
    let result = try #require(processed)
    #expect(result.calibrationID == id)
    #expect(result.isCalibrated)
    #expect(abs(try #require(result.relativeAngles).yaw - 0.2) < 1e-8)
    #expect(equivalent(result.displayQuaternion, try #require(result.relativeQuaternion)))
    #expect(result.measuredFrequency == nil)
}

@Test func timestampJumpWithoutMatchingReceiptGapStillInvalidatesCalibration() throws {
    var processor = MotionProcessor()
    _ = processor.process(sample(10))
    #expect(processor.calibrate() == true)
    let result = processor.process(sample(11.2, receipt: 20.02))
    #expect(try #require(result).isCalibrated == false)
}

@Test func gapAtRecoveryDeadlineRequiresManualCalibration() throws {
    var processor = MotionProcessor()
    _ = processor.process(sample(10))
    #expect(processor.calibrate() == true)
    let result = processor.process(sample(13))
    #expect(try #require(result).isCalibrated == false)
}

@Test func recalibrationDoesNotRetainOldFilterPose() throws {
    var processor = MotionProcessor(smoothingTimeConstant: 10)
    _ = processor.process(sample(0))
    let moved = Quaternion(angles: AttitudeAngles(yaw: 0.8, pitch: 0.2, roll: -0.3))
    _ = processor.process(sample(0.1, quaternion: moved))
    #expect(processor.calibrate() == true)
    let resultValue = processor.process(sample(0.2, quaternion: moved))
    let result = try #require(resultValue)
    #expect(equivalent(result.displayQuaternion, .identity))
}

@Test func smoothingUsesElapsedTimeInsteadOfAssumedSampleRate() throws {
    func run(step: Double) throws -> ProcessedMotion {
        var processor = MotionProcessor(smoothingTimeConstant: 0.2)
        _ = processor.process(sample(0))
        let target = Quaternion(angles: AttitudeAngles(yaw: 1, pitch: 0, roll: 0))
        var result: ProcessedMotion?
        for i in 1...Int((1 / step).rounded()) {
            result = processor.process(sample(Double(i) * step, quaternion: target,
                                              rate: Vector3(x: 1, y: 0, z: 0),
                                              acceleration: Vector3(x: 0, y: 1, z: 0)))
        }
        return try #require(result)
    }
    let fast = try run(step: 0.02)
    let slow = try run(step: 0.1)
    let expected = 1 - exp(-5.0)
    #expect(abs(fast.displayAngles.yaw - slow.displayAngles.yaw) < 1e-5)
    #expect(abs(fast.displayAngles.yaw - expected) < 1e-5)
    #expect(abs(fast.smoothedRotationRate.x - expected) < 1e-12)
    #expect(abs(slow.smoothedUserAcceleration.y - expected) < 1e-12)
}
