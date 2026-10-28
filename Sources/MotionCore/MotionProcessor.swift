import Foundation

/// Stateful, synchronous processing. The runtime owns one instance in its serial
/// processing actor; the value type itself does not create threads or timers.
public struct MotionProcessor: Sendable {
    /// Seconds. Zero disables smoothing. Invalid settings safely disable smoothing.
    public var smoothingTimeConstant: Double
    public private(set) var acceptedCount = 0
    public private(set) var rejectedCount = 0
    public private(set) var discontinuityCount = 0
    public private(set) var lastRejection: String?
    public private(set) var calibrationID: UUID?

    private var reference: Quaternion?
    private var lastSample: MotionSample?
    private var filteredOrientation: Quaternion?
    private var filteredRotationRate: Vector3?
    private var filteredAcceleration: Vector3?
    private var timestamps: [TimeInterval] = []

    public init(smoothingTimeConstant: Double = 0.08) {
        self.smoothingTimeConstant = smoothingTimeConstant
    }

    /// Invalid samples never replace the last valid sample or calibration.
    public mutating func process(_ sample: MotionSample) -> ProcessedMotion? {
        guard sample.isFinite, sample.timestamp >= 0, sample.receivedUptime >= 0 else {
            return reject("Non-finite values or negative monotonic timestamp")
        }
        // Small normalization drift is harmless. A grossly invalid sensor quaternion
        // should be visible as a rejection rather than silently converted to a pose.
        guard (0.5...1.5).contains(sample.quaternion.magnitude),
              let orientation = sample.quaternion.normalized() else {
            return reject("Invalid quaternion magnitude")
        }
        if let previous = lastSample, sample.timestamp <= previous.timestamp {
            return reject("Duplicate or backward sensor timestamp")
        }
        if let previous = lastSample {
            let sensorGap = sample.timestamp - previous.timestamp
            let receiptGap = sample.receivedUptime - previous.receivedUptime
            if sensorGap > MotionContinuityPolicy.filterResetInterval
                || receiptGap > MotionContinuityPolicy.filterResetInterval {
                let recoverable = max(sensorGap, receiptGap) < MotionContinuityPolicy.recoveryInterval
                    && receiptGap > 0
                    && abs(sensorGap - receiptGap) <= MotionContinuityPolicy.clockTolerance
                if recoverable {
                    // The same stream resumed. Discard interpolation/rate history,
                    // but retain the explicit reference; never calibrate at recovery.
                    discontinuityCount += 1
                    lastSample = nil
                    timestamps.removeAll(keepingCapacity: true)
                    clearFilters()
                } else {
                    resetContinuity()
                }
            }
        }

        let dt = lastSample.map { sample.timestamp - $0.timestamp }
        let relative = reference.map { orientation.multiplied(by: $0.conjugate).normalized()! }
        let target = relative ?? orientation
        let alpha: Double
        if let dt, smoothingTimeConstant.isFinite, smoothingTimeConstant > 0 {
            alpha = -expm1(-dt / smoothingTimeConstant)
        } else {
            alpha = 1
        }
        let display = filteredOrientation?.interpolated(to: target, fraction: alpha) ?? target
        // q maps head/body axes to the common reference frame. Convert the
        // already filtered common-frame delta by a change of basis, preserving
        // the original debug output and avoiding a second smoothing delay:
        // ref⁻¹ × (current × ref⁻¹) × ref = ref⁻¹ × current.
        let headRelative = reference.flatMap {
            $0.conjugate.multiplied(by: display).multiplied(by: $0).normalized()
        }
        let rate = filteredRotationRate?.interpolated(to: sample.rotationRate, fraction: alpha) ?? sample.rotationRate
        let acceleration = filteredAcceleration?.interpolated(to: sample.userAcceleration, fraction: alpha) ?? sample.userAcceleration
        filteredOrientation = display
        filteredRotationRate = rate
        filteredAcceleration = acceleration
        lastSample = sample
        acceptedCount += 1
        lastRejection = nil

        timestamps.append(sample.timestamp)
        let cutoff = sample.timestamp - 2
        if let firstKept = timestamps.firstIndex(where: { $0 >= cutoff }), firstKept > 0 {
            timestamps.removeFirst(firstKept)
        }
        if timestamps.count > 4096 { timestamps.removeFirst(timestamps.count - 4096) }
        let span = sample.timestamp - (timestamps.first ?? sample.timestamp)
        let frequency = timestamps.count >= 2 && span >= 0.25
            ? Double(timestamps.count - 1) / span : nil

        return ProcessedMotion(
            raw: sample, relativeQuaternion: relative, relativeAngles: relative?.eulerAngles,
            displayQuaternion: display, displayAngles: display.eulerAngles,
            smoothedRotationRate: rate, smoothedUserAcceleration: acceleration,
            measuredFrequency: frequency, isCalibrated: reference != nil,
            smoothingEnabled: smoothingTimeConstant.isFinite && smoothingTimeConstant > 0,
            calibrationID: calibrationID, headRelativeQuaternion: headRelative
        )
    }

    /// Reference is the latest accepted, unsmoothed orientation. The next accepted
    /// sample begins a fresh filter, so no pre-calibration pose contaminates it.
    @discardableResult
    public mutating func calibrate() -> Bool {
        guard let sample = lastSample, let quaternion = sample.quaternion.normalized() else { return false }
        reference = quaternion
        calibrationID = UUID()
        clearFilters()
        return true
    }

    public mutating func reset() {
        reference = nil
        calibrationID = nil
        lastSample = nil
        timestamps.removeAll(keepingCapacity: true)
        clearFilters()
        acceptedCount = 0
        rejectedCount = 0
        discontinuityCount = 0
        lastRejection = nil
    }

    /// Reconnection can create a different sensor reference frame. Discard the
    /// previous calibration, filter and rate window, while retaining run counters.
    public mutating func resetContinuity() {
        if lastSample != nil { discontinuityCount += 1 }
        reference = nil
        calibrationID = nil
        lastSample = nil
        timestamps.removeAll(keepingCapacity: true)
        clearFilters()
        lastRejection = nil
    }

    /// Ends a feature's reference without restarting the shared sensor stream.
    public mutating func clearCalibration() {
        reference = nil
        calibrationID = nil
        clearFilters()
    }

    private mutating func clearFilters() {
        filteredOrientation = nil
        filteredRotationRate = nil
        filteredAcceleration = nil
    }

    private mutating func reject(_ reason: String) -> ProcessedMotion? {
        rejectedCount += 1
        lastRejection = reason
        return nil
    }
}
