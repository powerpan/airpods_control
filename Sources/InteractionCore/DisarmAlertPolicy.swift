import Foundation

/// Decides when protection that is switched on but no longer armed deserves a
/// notification. Only a real loss counts: the user must have been armed since
/// the toggle was last off, so launch before the first calibration is silent.
/// The neck exercise and a visible shield neither cancel nor start a loss; a
/// brief re-arm wait (settings change, recalibration) stays below `delay`.
public struct DisarmAlertPolicy: Sendable, Equatable {
    public enum Observation: Sendable, Equatable {
        /// Toggle off: the user chose no protection.
        case off
        case armed
        case notArmed
        /// Exercise pause or a visible shield: the user already knows.
        case held
    }

    public let delay: TimeInterval
    public let minimumInterval: TimeInterval
    private var wasArmed = false
    private var notArmedSince: TimeInterval?
    private var lastAlert: TimeInterval?

    public init(delay: TimeInterval = 5, minimumInterval: TimeInterval = 300) {
        self.delay = delay.isFinite ? max(0, delay) : 5
        self.minimumInterval = minimumInterval.isFinite ? max(0, minimumInterval) : 300
    }

    /// Returns true exactly when a notification should be posted now.
    public mutating func observe(_ observation: Observation, at now: TimeInterval) -> Bool {
        switch observation {
        case .off:
            wasArmed = false
            notArmedSince = nil
        case .armed:
            wasArmed = true
            notArmedSince = nil
        case .held:
            notArmedSince = nil
        case .notArmed:
            guard wasArmed else { return false }
            let since = notArmedSince ?? now
            notArmedSince = since
            guard now - since >= delay else { return false }
            // One alert per loss; a suppressed one is consumed too.
            wasArmed = false
            notArmedSince = nil
            if let lastAlert, now - lastAlert < minimumInterval { return false }
            lastAlert = now
            return true
        }
        return false
    }
}
