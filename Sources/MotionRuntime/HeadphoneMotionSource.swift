import CoreMotion
import Foundation
import MotionCore

@MainActor
public final class HeadphoneMotionSource: MotionSource {
    public let kind: MotionSourceKind = .headphones
    private let manager = CMHeadphoneMotionManager()
    private let callbackQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "AirPodsMotionLab.CoreMotion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var sink: EventSink?
    private var delegateProxy: HeadphoneConnectionDelegate?

    public init() {}

    public var availability: SourceAvailability {
        SourceAvailability(
            isAvailable: manager.isDeviceMotionAvailable,
            authorization: Self.authorization,
            connection: manager.isConnectionStatusActive ? (sink?.currentConnection ?? .unknown) : .unknown
        )
    }

    public var droppedEventCount: Int { sink?.droppedCount ?? 0 }

    private static var authorization: MotionAuthorization {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    public func start() -> AsyncStream<MotionSourceEvent> {
        stop()
        let (stream, continuation) = AsyncStream<MotionSourceEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let sink = EventSink(continuation)
        self.sink = sink
        sink.yield(.availability(availability))
        guard Self.authorization != .denied, Self.authorization != .restricted else {
            sink.yield(.failure("運動權限未獲允許，請在系統設置中檢查運動與健身權限。"))
            return stream
        }

        let delegate = HeadphoneConnectionDelegate(sink: sink)
        delegateProxy = delegate
        manager.delegate = delegate
        manager.startConnectionStatusUpdates()
        // Do not precondition on availability: starting requests authorization,
        // and connection callbacks can arrive after this call.
        manager.startDeviceMotionUpdates(to: callbackQueue, withHandler: Self.makeHandler(sink: sink))
        return stream
    }

    // Core Motion's legacy block type is not annotated @Sendable. Defining its
    // closure inside start() would infer MainActor isolation in Swift 6 and
    // trap when the framework calls it on callbackQueue. Keep this factory
    // explicitly nonisolated and its returned closure Sendable.
    nonisolated static func makeHandler(sink: EventSink) -> @Sendable (CMDeviceMotion?, (any Error)?) -> Void {
        { @Sendable motion, error in
            if let error {
                let nsError = error as NSError
                sink.yield(.failure("\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"))
                return
            }
            guard let motion else {
                sink.yield(.failure("Core Motion 回調沒有包含數據或錯誤。"))
                return
            }
            let attitude = motion.attitude
            let quaternion = attitude.quaternion
            // Capture receipt clocks separately from the sensor's boot-relative
            // timestamp. Never convert the sensor timestamp directly to Date.
            let sample = MotionSample(
                timestamp: motion.timestamp,
                receivedAt: Date(),
                receivedUptime: ProcessInfo.processInfo.systemUptime,
                attitude: AttitudeAngles(yaw: attitude.yaw, pitch: attitude.pitch, roll: attitude.roll),
                quaternion: Quaternion(x: quaternion.x, y: quaternion.y, z: quaternion.z, w: quaternion.w),
                rotationRate: Vector3(x: motion.rotationRate.x, y: motion.rotationRate.y, z: motion.rotationRate.z),
                userAcceleration: Vector3(x: motion.userAcceleration.x, y: motion.userAcceleration.y, z: motion.userAcceleration.z),
                gravity: Vector3(x: motion.gravity.x, y: motion.gravity.y, z: motion.gravity.z)
            )
            sink.yield(.sample(sample))
        }
    }

    public func stop() {
        // Invalidate before stopping: already queued callbacks become harmless.
        sink?.finish()
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
        manager.delegate = nil
        delegateProxy = nil
        callbackQueue.cancelAllOperations()
    }
}

private final class HeadphoneConnectionDelegate: NSObject, CMHeadphoneMotionManagerDelegate, Sendable {
    let sink: EventSink
    init(sink: EventSink) { self.sink = sink }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        sink.yield(.connection(.connected))
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        sink.yield(.connection(.disconnected))
    }
}
