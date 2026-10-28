import Foundation
import MotionCore

public enum MotionSourceKind: String, CaseIterable, Sendable {
    case headphones, simulation
}

public enum MotionAuthorization: String, Sendable {
    case notDetermined, authorized, denied, restricted, unknown
}

public enum MotionConnection: String, Sendable {
    case unknown, connected, disconnected
}

public enum CapturePhase: String, Sendable {
    case idle, starting, waiting, streaming, interrupted, permissionDenied, failed, stopped
}

/// Retained in snapshots so a disconnect/reconnect between UI polls is not lost.
public struct CaptureInterruption: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case disconnected, sleep, sourceFailure, streamEnded, timedOut
    }
    public let id: UUID
    public let reason: Reason
    public let uptime: TimeInterval

    public init(reason: Reason, uptime: TimeInterval) {
        self.id = UUID()
        self.reason = reason
        self.uptime = uptime
    }
}

public struct SourceAvailability: Sendable, Equatable {
    public var isAvailable: Bool
    public var authorization: MotionAuthorization
    public var connection: MotionConnection

    public init(isAvailable: Bool, authorization: MotionAuthorization, connection: MotionConnection = .unknown) {
        self.isAvailable = isAvailable
        self.authorization = authorization
        self.connection = connection
    }
}

public struct SessionSnapshot: Sendable {
    public var source: MotionSourceKind = .headphones
    public var phase: CapturePhase = .idle
    public var availability = SourceAvailability(isAvailable: false, authorization: .unknown)
    public var isRequested = false
    public var latest: ProcessedMotion?
    public var lastReceivedAt: Date?
    public var lastReceivedUptime: TimeInterval?
    public var message: String? = nil
    public var lastError: String? = nil
    public var acceptedCount = 0
    public var rejectedCount = 0
    public var discontinuityCount = 0
    public var ingressDroppedCount = 0
    public var subscriberDroppedCount = 0
    public var smoothingEnabled = true
    public var calibrationMessage: String? = nil
    public var calibrationID: UUID? = nil
    public var lastInterruption: CaptureInterruption?

    public init() {}
}

public enum MotionSourceEvent: Sendable {
    case sample(MotionSample)
    case availability(SourceAvailability)
    case connection(MotionConnection)
    case failure(String)
}

/// Platform access is main-actor isolated. Sensor callbacks copy values into the
/// bounded stream on a background queue; they never render or process UI state.
@MainActor
public protocol MotionSource: AnyObject, Sendable {
    var kind: MotionSourceKind { get }
    var availability: SourceAvailability { get }
    var droppedEventCount: Int { get }
    func start() -> AsyncStream<MotionSourceEvent>
    func stop()
}
