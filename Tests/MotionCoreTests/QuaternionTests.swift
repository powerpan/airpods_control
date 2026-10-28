import Foundation
import Testing
@testable import MotionCore

@Test func antipodalQuaternionsInterpolateWithoutMotion() {
    let q = Quaternion(x: 0.3, y: 0.4, z: 0, w: sqrt(0.75))
    let opposite = Quaternion(x: -q.x, y: -q.y, z: -q.z, w: -q.w)
    for t in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let result = q.interpolated(to: opposite, fraction: t)
        #expect(abs(abs(result.dot(q)) - 1) < 1e-12)
        #expect(abs(result.magnitude - 1) < 1e-12)
    }
}

@Test func singleAxesFollowDocumentedPitchXRollYYawZ() {
    let h = sqrt(0.5)
    let pitch = Quaternion(x: h, y: 0, z: 0, w: h).eulerAngles
    let roll = Quaternion(x: 0, y: h, z: 0, w: h).eulerAngles
    let yaw = Quaternion(x: 0, y: 0, z: h, w: h).eulerAngles
    #expect(abs(pitch.pitch - .pi / 2) < 1e-7)
    #expect(abs(roll.roll - .pi / 2) < 1e-12)
    #expect(abs(yaw.yaw - .pi / 2) < 1e-12)
    #expect(pitch.roll == 0 && roll.pitch == 0 && yaw.pitch == 0)
}

@Test func derivedAnglesReconstructRotationIncludingPitchSingularities() {
    for pitch in [-Double.pi / 2, -1.2, -0.3, 0, 0.7, Double.pi / 2] {
        for yaw in [-2.5, -0.4, 0, 1.2] {
            for roll in [-1.8, 0.2, 2.4] {
                let q = Quaternion(angles: AttitudeAngles(yaw: yaw, pitch: pitch, roll: roll))
                let reconstructed = Quaternion(angles: q.eulerAngles)
                #expect(abs(abs(q.dot(reconstructed)) - 1) < 1e-9)
                #expect(q.eulerAngles.isFinite)
            }
        }
    }
}

@Test func normalizationRejectsZeroAndNonfiniteInput() throws {
    #expect(Quaternion(x: 0, y: 0, z: 0, w: 0).normalized() == nil)
    #expect(Quaternion(x: .nan, y: 0, z: 0, w: 1).normalized() == nil)
    #expect(Quaternion(x: 0, y: 0, z: 0, w: .infinity).normalized() == nil)
    let q = try #require(Quaternion(x: 0.1, y: 0.2, z: 0.3, w: 0.9).normalized())
    #expect(abs(q.magnitude - 1) < 1e-12)
    let identity = q.multiplied(by: q.conjugate)
    #expect(abs(identity.x) < 1e-12 && abs(identity.y) < 1e-12 && abs(identity.z) < 1e-12)
    #expect(abs(identity.w - 1) < 1e-12)
}
