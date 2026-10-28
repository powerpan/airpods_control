import Foundation
import InteractionCore

public struct ActivityAvailability: Sendable, Equatable {
    public var isAvailable: Bool
    public var authorization: MotionAuthorization
    public var connection: MotionConnection
    public var isActive: Bool
    public var reason: String?

    public init(isAvailable: Bool, authorization: MotionAuthorization,
                connection: MotionConnection = .unknown, isActive: Bool = false,
                reason: String? = nil) {
        self.isAvailable = isAvailable
        self.authorization = authorization
        self.connection = connection
        self.isActive = isActive
        self.reason = reason
    }
}

public enum ActivitySourceEvent: Sendable {
    case observation(ActivityObservation)
    case availability(ActivityAvailability)
    case connection(MotionConnection)
    case failure(String)
}

/// 活動來源只傳遞官方分類，不建立另一條姿態採集流程。
@MainActor
public protocol ActivitySource: AnyObject, Sendable {
    var availability: ActivityAvailability { get }
    func start() -> AsyncStream<ActivitySourceEvent>
    func stop()
}

@MainActor
public func makeHeadphoneActivitySource() -> any ActivitySource {
    if #available(macOS 15.0, *) {
        return HeadphoneActivitySource()
    }
    return UnavailableActivitySource(reason: "離座識別需要 macOS 15 或更新版本；轉頭遮擋仍可使用。")
}

@MainActor
public final class UnavailableActivitySource: ActivitySource {
    public let availability: ActivityAvailability

    public init(reason: String) {
        availability = ActivityAvailability(isAvailable: false, authorization: .unknown, reason: reason)
    }

    public func start() -> AsyncStream<ActivitySourceEvent> {
        let (stream, continuation) = AsyncStream<ActivitySourceEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(.availability(availability))
        continuation.finish()
        return stream
    }

    public func stop() {}
}

/// Core Motion 回調與主 actor 只共用這個受鎖保護的值橋接器。
/// 終止後不再接受舊回調；丟失任何事件時必須中斷分類證據。
final class ActivityEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ActivitySourceEvent>.Continuation?
    private var connection: MotionConnection = .unknown
    private var failure: String?

    init(_ continuation: AsyncStream<ActivitySourceEvent>.Continuation) {
        self.continuation = continuation
    }

    var currentConnection: MotionConnection { lock.withLock { connection } }
    var failureReason: String? { lock.withLock { failure } }
    var isOpen: Bool { lock.withLock { continuation != nil } }

    func yield(_ event: ActivitySourceEvent) {
        lock.withLock {
            guard let continuation else { return }
            if case .connection(let value) = event { connection = value }
            if case .failure(let reason) = event {
                terminateLocked(reason, continuation: continuation)
                return
            }
            switch continuation.yield(event) {
            case .dropped:
                terminateLocked("活動事件緩衝溢位；離座判定已暫停，等待重新連接資料流。", continuation: continuation)
            case .terminated:
                self.continuation = nil
            case .enqueued:
                break
            @unknown default:
                terminateLocked("活動資料流狀態不明；離座判定已暫停。", continuation: continuation)
            }
        }
    }

    func finish() {
        let old = lock.withLock {
            let old = continuation
            continuation = nil
            return old
        }
        old?.finish()
    }

    private func terminateLocked(_ reason: String, continuation: AsyncStream<ActivitySourceEvent>.Continuation) {
        failure = reason
        self.continuation = nil
        // 使用 bufferingNewest，最後保留 failure；之後的回調不能將其擠走。
        continuation.yield(.failure(reason))
        continuation.finish()
    }
}
