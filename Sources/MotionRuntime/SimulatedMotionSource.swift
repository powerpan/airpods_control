import Foundation
import MotionCore

/// A deterministic synthetic attitude, sampled at deliberately uneven intervals.
/// It validates the app pipeline, not any AirPods model or sensor accuracy.
@MainActor
public final class SimulatedMotionSource: MotionSource {
    public let kind: MotionSourceKind = .simulation
    public var availability: SourceAvailability {
        SourceAvailability(isAvailable: true, authorization: .authorized, connection: .connected)
    }
    public var droppedEventCount: Int { sink?.droppedCount ?? 0 }
    private var producer: Task<Void, Never>?
    private var sink: EventSink?

    public init() {}

    public func start() -> AsyncStream<MotionSourceEvent> {
        stop()
        let (stream, continuation) = AsyncStream<MotionSourceEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let sink = EventSink(continuation)
        self.sink = sink
        sink.yield(.availability(availability))
        producer = Task.detached(priority: .utility) {
            let origin = ProcessInfo.processInfo.systemUptime
            var index = 0
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                let t = now - origin
                let angles = Self.angles(at: t)
                let q = Quaternion(angles: angles)
                // Synthetic rigid rotation in the app's explicit Z-X-Y
                // convention. Derive body rate and gravity from the same pose.
                let step = 0.0001
                let next = Quaternion(angles: Self.angles(at: t + step))
                let delta = q.conjugate.multiplied(by: next)
                let gravity = q.conjugate
                    .multiplied(by: Quaternion(x: 0, y: 0, z: -1, w: 0))
                    .multiplied(by: q)
                sink.yield(.sample(MotionSample(
                    timestamp: now,
                    receivedAt: Date(),
                    receivedUptime: now,
                    attitude: angles,
                    quaternion: q,
                    rotationRate: Vector3(x: 2 * delta.x / step, y: 2 * delta.y / step, z: 2 * delta.z / step),
                    userAcceleration: Vector3(x: 0, y: 0, z: 0),
                    gravity: Vector3(x: gravity.x, y: gravity.y, z: gravity.z)
                )))
                let delays: [UInt64] = [16, 22, 18, 24, 20]
                do { try await Task.sleep(nanoseconds: delays[index % delays.count] * 1_000_000) }
                catch { break }
                index += 1
            }
            sink.finish()
        }
        return stream
    }

    public func stop() {
        producer?.cancel()
        producer = nil
        sink?.finish()
    }

    private nonisolated static func angles(at time: TimeInterval) -> AttitudeAngles {
        AttitudeAngles(yaw: 0.55 * sin(time * 0.7),
                       pitch: 0.28 * sin(time * 0.5),
                       roll: 0.20 * sin(time * 0.9))
    }

    deinit { producer?.cancel(); sink?.finish() }
}
