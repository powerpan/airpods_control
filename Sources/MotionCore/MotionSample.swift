import Foundation

/// Core Motion values stay in their original units. UI formatting is a separate concern.
public struct Vector3: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(x: 0, y: 0, z: 0)
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    public func interpolated(to target: Vector3, fraction: Double) -> Vector3 {
        Vector3(x: x + (target.x - x) * fraction,
                y: y + (target.y - y) * fraction,
                z: z + (target.z - z) * fraction)
    }
}

public struct AttitudeAngles: Sendable, Equatable {
    /// Radians; the raw sample contains Apple's values without reinterpretation.
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    public static let zero = AttitudeAngles(yaw: 0, pitch: 0, roll: 0)
    public var isFinite: Bool { yaw.isFinite && pitch.isFinite && roll.isFinite }
}

public struct MotionSample: Sendable, Equatable {
    /// Sensor timestamp: seconds since device boot, not a Unix date or delivery time.
    public let timestamp: TimeInterval
    /// Local wall-clock callback receipt; useful for the debug interface, not integration.
    public let receivedAt: Date
    /// Local monotonic callback receipt; use this for interruption detection.
    public let receivedUptime: TimeInterval
    /// Original CMAttitude values in radians (or the simulator's documented convention).
    public let attitude: AttitudeAngles
    /// Original quaternion in x, y, z, w order.
    public let quaternion: Quaternion
    /// Radians per second in the sensor frame.
    public let rotationRate: Vector3
    /// Acceleration excluding gravity, in g (1 g ≈ 9.81 m/s²).
    public let userAcceleration: Vector3
    /// Gravity vector in g in the sensor frame.
    public let gravity: Vector3

    public init(timestamp: TimeInterval, receivedAt: Date, receivedUptime: TimeInterval,
                attitude: AttitudeAngles, quaternion: Quaternion, rotationRate: Vector3,
                userAcceleration: Vector3, gravity: Vector3) {
        self.timestamp = timestamp
        self.receivedAt = receivedAt
        self.receivedUptime = receivedUptime
        self.attitude = attitude
        self.quaternion = quaternion
        self.rotationRate = rotationRate
        self.userAcceleration = userAcceleration
        self.gravity = gravity
    }

    public var isFinite: Bool {
        timestamp.isFinite && receivedAt.timeIntervalSinceReferenceDate.isFinite &&
        receivedUptime.isFinite && attitude.isFinite && quaternion.isFinite &&
        rotationRate.isFinite && userAcceleration.isFinite && gravity.isFinite
    }
}

public struct ProcessedMotion: Sendable, Equatable {
    public let raw: MotionSample
    /// Unsmoothed current × inverse(reference), in the common reference axes.
    /// Kept for the original debug view; nil until explicit calibration.
    public let relativeQuaternion: Quaternion?
    /// Application-defined Z-X-Y decomposition, not componentwise Euler subtraction.
    public let relativeAngles: AttitudeAngles?
    /// Smoothed relative orientation when calibrated; smoothed absolute otherwise.
    public let displayQuaternion: Quaternion
    public let displayAngles: AttitudeAngles
    public let smoothedRotationRate: Vector3
    public let smoothedUserAcceleration: Vector3
    /// Measured from accepted sensor timestamps over up to two seconds; nil while warming up.
    public let measuredFrequency: Double?
    public let isCalibrated: Bool
    /// Processing setting captured with this frame, including historical frames.
    public let smoothingEnabled: Bool
    /// Changes on every explicit calibration; nil when no reference is valid.
    public let calibrationID: UUID?
    /// Filtered relative orientation expressed in the calibrated head's local
    /// axes. With smoothing disabled this is inverse(reference) × current.
    /// Unlike the common-frame delta, its pitch/roll axes do not rotate when the
    /// user calibrates while facing a different global heading.
    public let headRelativeQuaternion: Quaternion?
    public var headRelativeAngles: AttitudeAngles? { headRelativeQuaternion?.eulerAngles }

    public init(raw: MotionSample, relativeQuaternion: Quaternion?, relativeAngles: AttitudeAngles?,
                displayQuaternion: Quaternion, displayAngles: AttitudeAngles,
                smoothedRotationRate: Vector3, smoothedUserAcceleration: Vector3,
                measuredFrequency: Double?, isCalibrated: Bool, smoothingEnabled: Bool = true,
                calibrationID: UUID? = nil, headRelativeQuaternion: Quaternion? = nil) {
        self.raw = raw
        self.relativeQuaternion = relativeQuaternion
        self.relativeAngles = relativeAngles
        self.displayQuaternion = displayQuaternion
        self.displayAngles = displayAngles
        self.smoothedRotationRate = smoothedRotationRate
        self.smoothedUserAcceleration = smoothedUserAcceleration
        self.measuredFrequency = measuredFrequency
        self.isCalibrated = isCalibrated
        self.smoothingEnabled = smoothingEnabled
        self.calibrationID = calibrationID
        self.headRelativeQuaternion = headRelativeQuaternion
    }
}
