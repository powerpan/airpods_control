import Foundation
import Testing
@testable import MotionCore

private func headSample(_ time: Double, _ quaternion: Quaternion) -> MotionSample {
    MotionSample(timestamp: time, receivedAt: Date(timeIntervalSince1970: time), receivedUptime: time,
                 attitude: quaternion.eulerAngles, quaternion: quaternion,
                 rotationRate: .zero, userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1))
}

private func sameRotation(_ a: Quaternion, _ b: Quaternion) -> Bool {
    guard let a = a.normalized(), let b = b.normalized() else { return false }
    return abs(abs(a.dot(b)) - 1) < 1e-10
}

@Test func calibratedHeadAxesAreIndependentOfGlobalHeading() throws {
    let localAngles = [
        AttitudeAngles(yaw: 0.3, pitch: 0, roll: 0),
        AttitudeAngles(yaw: -0.3, pitch: 0, roll: 0),
        AttitudeAngles(yaw: 0, pitch: 0.2, roll: 0),
        AttitudeAngles(yaw: 0, pitch: -0.2, roll: 0),
        AttitudeAngles(yaw: 0, pitch: 0, roll: 0.25),
        AttitudeAngles(yaw: 0, pitch: 0, roll: -0.25),
        AttitudeAngles(yaw: 0.17, pitch: -0.2, roll: 0.13)
    ]
    for heading in [0.0, 90, -90, 180] {
        let reference = Quaternion(x: 0, y: 0, z: sin(heading * .pi / 360), w: cos(heading * .pi / 360))
        for angles in localAngles {
            var processor = MotionProcessor(smoothingTimeConstant: 0)
            _ = processor.process(headSample(0, reference))
            let calibrated = processor.calibrate()
            #expect(calibrated)
            let localRotation = Quaternion(angles: angles)
            // A head-local movement composes on the right of body-to-world pose.
            let current = reference.multiplied(by: localRotation)
            let processed = processor.process(headSample(0.1, current))
            let output = try #require(processed)
            #expect(sameRotation(try #require(output.headRelativeQuaternion), localRotation))
            let headAngles = try #require(output.headRelativeAngles)
            #expect(abs(headAngles.yaw - angles.yaw) < 1e-10)
            #expect(abs(headAngles.pitch - angles.pitch) < 1e-10)
            #expect(abs(headAngles.roll - angles.roll) < 1e-10)
            #expect(output.raw.quaternion == current)
        }
    }
}

@Test func originalCommonFrameDebugOutputIsPreservedBesideHeadLocalOutput() throws {
    let h = sqrt(0.5)
    let reference = Quaternion(x: 0, y: 0, z: h, w: h) // global yaw +90°
    let pitch = 10.0 * .pi / 180
    let localPitch = Quaternion(x: sin(pitch / 2), y: 0, z: 0, w: cos(pitch / 2))
    var processor = MotionProcessor(smoothingTimeConstant: 0)
    _ = processor.process(headSample(0, reference))
    let calibrated = processor.calibrate()
    #expect(calibrated)
    let current = reference.multiplied(by: localPitch)
    let processed = processor.process(headSample(0.1, current))
    let result = try #require(processed)
    let originalDelta = current.multiplied(by: reference.conjugate)
    #expect(sameRotation(try #require(result.relativeQuaternion), originalDelta))
    #expect(sameRotation(result.displayQuaternion, originalDelta))
    // The old result rotates the local X action into global Y. Feature-local
    // output must keep it on pitch/X while the existing debug output is intact.
    #expect(abs(result.displayAngles.roll - pitch) < 1e-10)
    #expect(abs(result.displayAngles.pitch) < 1e-10)
    #expect(abs(try #require(result.headRelativeAngles).pitch - pitch) < 1e-10)
    #expect(abs(try #require(result.headRelativeAngles).roll) < 1e-10)
}

@Test func headLocalOutputSharesTheExistingFilterWithoutAddingLag() throws {
    let movement = Quaternion(angles: AttitudeAngles(yaw: 0.2, pitch: -0.15, roll: 0.1))
    let expected = Quaternion.identity.interpolated(to: movement, fraction: 1 - exp(-0.1 / 0.2))
    for heading in [0.0, 90, -90, 180] {
        let reference = Quaternion(angles: AttitudeAngles(yaw: heading * .pi / 180, pitch: 0.21, roll: -0.13))
        var processor = MotionProcessor(smoothingTimeConstant: 0.2)
        _ = processor.process(headSample(0, reference))
        let calibrated = processor.calibrate()
        #expect(calibrated)
        _ = processor.process(headSample(0.1, reference))
        let current = reference.multiplied(by: movement)
        let processed = processor.process(headSample(0.2, current))
        let result = try #require(processed)
        #expect(sameRotation(try #require(result.headRelativeQuaternion), expected))
        #expect(result.smoothingEnabled)
    }
}

@Test func invalidatedReferencesNeverPublishHeadLocalAngles() throws {
    var processor = MotionProcessor()
    _ = processor.process(headSample(0, .identity))
    let calibrated = processor.calibrate()
    #expect(calibrated)
    let calibratedSample = processor.process(headSample(0.1, .identity))
    #expect(try #require(calibratedSample).headRelativeAngles != nil)
    processor.clearCalibration()
    let clearedSample = processor.process(headSample(0.2, .identity))
    #expect(try #require(clearedSample).headRelativeAngles == nil)
    let recalibrated = processor.calibrate()
    #expect(recalibrated)
    // Crossing the recovery deadline invalidates feature axes as well.
    let interruptedSample = processor.process(headSample(3.3, .identity))
    #expect(try #require(interruptedSample).headRelativeQuaternion == nil)
}
