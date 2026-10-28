import Foundation

/// Shared deadline for a recoverable gap in the same capture stream.
public enum MotionContinuityPolicy {
    public static let recoveryInterval: TimeInterval = 3
    public static let filterResetInterval: TimeInterval = 1
    public static let clockTolerance: TimeInterval = 0.25
}
