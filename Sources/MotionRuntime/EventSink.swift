import Foundation

/// The only lock-based bridge: Core Motion callbacks and the main actor share
/// this bounded continuation. No Core Motion object crosses the bridge.
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<MotionSourceEvent>.Continuation?
    private var dropped = 0
    private var connection: MotionConnection = .unknown

    init(_ continuation: AsyncStream<MotionSourceEvent>.Continuation) {
        self.continuation = continuation
    }

    var droppedCount: Int { lock.withLock { dropped } }
    var currentConnection: MotionConnection { lock.withLock { connection } }

    func yield(_ event: MotionSourceEvent) {
        lock.withLock {
            guard let continuation else { return }
            if case .connection(let value) = event { connection = value }
            if case .dropped = continuation.yield(event) { dropped += 1 }
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
}
