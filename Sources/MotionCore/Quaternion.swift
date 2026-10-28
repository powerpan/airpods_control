import Foundation

/// Hamilton quaternion, vector part (x, y, z) and scalar part w.
public struct Quaternion: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
    public var magnitude: Double { hypot(hypot(x, y), hypot(z, w)) }

    public func normalized() -> Quaternion? {
        let norm = magnitude
        guard isFinite, norm.isFinite, norm > 1e-12 else { return nil }
        return Quaternion(x: x / norm, y: y / norm, z: z / norm, w: w / norm)
    }

    public var conjugate: Quaternion { Quaternion(x: -x, y: -y, z: -z, w: w) }

    public func multiplied(by other: Quaternion) -> Quaternion {
        Quaternion(
            x: w * other.x + x * other.w + y * other.z - z * other.y,
            y: w * other.y - x * other.z + y * other.w + z * other.x,
            z: w * other.z + x * other.y - y * other.x + z * other.w,
            w: w * other.w - x * other.x - y * other.y - z * other.z
        )
    }

    public func dot(_ other: Quaternion) -> Double {
        x * other.x + y * other.y + z * other.z + w * other.w
    }

    /// Shortest-arc spherical interpolation. q and -q describe the same rotation.
    public func interpolated(to target: Quaternion, fraction: Double) -> Quaternion {
        guard let from = normalized(), var to = target.normalized() else { return self }
        let t = min(1, max(0, fraction))
        var cosine = from.dot(to)
        if cosine < 0 {
            to = Quaternion(x: -to.x, y: -to.y, z: -to.z, w: -to.w)
            cosine = -cosine
        }
        cosine = min(1, max(-1, cosine))
        let a: Double
        let b: Double
        if cosine > 0.9995 {
            a = 1 - t
            b = t
        } else {
            let angle = acos(cosine)
            let denominator = sin(angle)
            a = sin((1 - t) * angle) / denominator
            b = sin(t * angle) / denominator
        }
        return Quaternion(x: a * from.x + b * to.x,
                          y: a * from.y + b * to.y,
                          z: a * from.z + b * to.z,
                          w: a * from.w + b * to.w).normalized() ?? from
    }

    /// Explicit application convention: R = Rz(yaw) × Rx(pitch) × Ry(roll).
    /// Apple identifies pitch with X, roll with Y and yaw with Z, but does not
    /// specify this multi-axis decomposition in the headphone API contract.
    /// Therefore derived angles use this documented convention; raw CMAttitude
    /// angles remain available separately and are never overwritten.
    public var eulerAngles: AttitudeAngles {
        guard let q = normalized() else { return .zero }
        let sinePitch = min(1, max(-1, 2 * (q.y * q.z + q.w * q.x)))
        let pitch = asin(sinePitch)
        if abs(sinePitch) > 1 - 1e-10 {
            // At ±90° pitch, yaw and roll cannot be distinguished. Choose roll=0
            // and retain the combined rotation, rather than emit unstable values.
            let m21 = 2 * (q.x * q.y + q.w * q.z)
            let m11 = 1 - 2 * (q.y * q.y + q.z * q.z)
            return AttitudeAngles(yaw: atan2(m21, m11), pitch: pitch, roll: 0)
        }
        return AttitudeAngles(
            yaw: atan2(2 * (q.w * q.z - q.x * q.y), 1 - 2 * (q.x * q.x + q.z * q.z)),
            pitch: pitch,
            roll: atan2(2 * (q.w * q.y - q.x * q.z), 1 - 2 * (q.x * q.x + q.y * q.y))
        )
    }

    /// Inverse of the application's Z-X-Y decomposition, for simulated data/tests.
    public init(angles: AttitudeAngles) {
        let yaw = Quaternion(x: 0, y: 0, z: sin(angles.yaw / 2), w: cos(angles.yaw / 2))
        let pitch = Quaternion(x: sin(angles.pitch / 2), y: 0, z: 0, w: cos(angles.pitch / 2))
        let roll = Quaternion(x: 0, y: sin(angles.roll / 2), z: 0, w: cos(angles.roll / 2))
        self = yaw.multiplied(by: pitch).multiplied(by: roll)
    }
}
