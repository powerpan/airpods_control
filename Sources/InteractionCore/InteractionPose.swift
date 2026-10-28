import Foundation

/// A calibrated pose expressed in degrees. No UI, sensor manager, or wall clock
/// is owned by the rule engines; callers deliver valid frames and signal loss.
public struct InteractionPose: Sendable, Equatable {
    public var timestamp: TimeInterval
    public var receivedUptime: TimeInterval
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    public var angularSpeed: Double
    public var calibrationID: UUID

    public init(timestamp: TimeInterval, receivedUptime: TimeInterval,
                yaw: Double, pitch: Double, roll: Double,
                angularSpeed: Double, calibrationID: UUID) {
        self.timestamp = timestamp
        self.receivedUptime = receivedUptime
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.angularSpeed = angularSpeed
        self.calibrationID = calibrationID
    }

    public var isFinite: Bool {
        [timestamp, receivedUptime, yaw, pitch, roll, angularSpeed].allSatisfy(\.isFinite)
            && timestamp >= 0 && receivedUptime >= 0 && angularSpeed >= 0
    }
}

func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}

func wrappedDegrees(_ angle: Double) -> Double {
    let value = angle.truncatingRemainder(dividingBy: 360)
    return value > 180 ? value - 360 : (value < -180 ? value + 360 : value)
}

enum PoseContinuityResult { case first, continuous, newReference, interrupted, invalid }

/// A missed quarter second, reference replacement, or impossible pose jump must
/// never contribute to a dwell. Angle wrapping is handled before jump detection.
struct PoseContinuity: Sendable, Equatable {
    var previous: InteractionPose?

    mutating func observe(_ pose: InteractionPose) -> PoseContinuityResult {
        guard pose.isFinite else { previous = nil; return .invalid }
        guard let old = previous else { previous = pose; return .first }
        previous = pose
        guard old.calibrationID == pose.calibrationID else { return .newReference }
        let interval = pose.timestamp - old.timestamp
        let receiptInterval = pose.receivedUptime - old.receivedUptime
        guard interval > 0, interval <= 0.25, receiptInterval >= 0, receiptInterval <= 0.25 else {
            return .interrupted
        }
        let maximumJump = max(18, interval * 240)
        guard abs(wrappedDegrees(pose.yaw - old.yaw)) <= maximumJump,
              abs(pose.pitch - old.pitch) <= maximumJump,
              abs(wrappedDegrees(pose.roll - old.roll)) <= maximumJump else { return .interrupted }
        return .continuous
    }

    mutating func reset() { previous = nil }
}
