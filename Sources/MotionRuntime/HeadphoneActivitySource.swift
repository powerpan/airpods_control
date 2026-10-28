import CoreMotion
import Foundation
import InteractionCore

@available(macOS 15.0, *)
@MainActor
public final class HeadphoneActivitySource: ActivitySource {
    private let manager = CMHeadphoneActivityManager()
    private let callbackQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "AirPodsMotionLab.HeadphoneActivity"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var sink: ActivityEventSink?

    public init() {}

    public var availability: ActivityAvailability {
        let authorization = Self.authorization
        let capable = manager.isActivityAvailable && manager.isStatusAvailable
        let active = sink?.isOpen == true && sink?.failureReason == nil && manager.isActivityActive
        let connection = manager.isStatusActive ? (sink?.currentConnection ?? .unknown) : .unknown
        let reason: String?
        if let failure = sink?.failureReason {
            reason = failure
        } else if authorization == .denied || authorization == .restricted {
            reason = "活動識別權限未獲允許；請在系統設定檢查運動與健身權限。"
        } else if !capable {
            reason = "目前系統或耳機不提供活動識別及連接狀態；轉頭遮擋仍可使用。"
        } else if connection == .disconnected {
            reason = "活動識別耳機已斷開；等待相容耳機重新連接。"
        } else if authorization == .notDetermined {
            reason = "等待運動與健身權限。"
        } else if !active {
            reason = "活動識別尚未啟動；等待有效連接。"
        } else if connection != .connected {
            reason = "等待相容耳機的活動識別連接狀態。"
        } else {
            reason = nil
        }
        return ActivityAvailability(isAvailable: capable, authorization: authorization,
                                    connection: connection, isActive: active, reason: reason)
    }

    public func start() -> AsyncStream<ActivitySourceEvent> {
        stop()
        let (stream, continuation) = AsyncStream<ActivitySourceEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let sink = ActivityEventSink(continuation)
        self.sink = sink
        sink.yield(.availability(availability))
        guard Self.authorization != .denied, Self.authorization != .restricted else {
            sink.yield(.failure("活動識別權限未獲允許；轉頭遮擋與手動解除仍可使用。"))
            return stream
        }
        // 不把未連接時的 capability=false 當作可反覆發出的授權請求。
        // 可用時先監聽連接；重新連接後由擁有者重試活動來源。
        guard manager.isStatusAvailable else { return stream }
        manager.startStatusUpdates(to: callbackQueue, withHandler: Self.makeStatusHandler(sink: sink))
        guard manager.isActivityAvailable else { return stream }
        manager.startActivityUpdates(to: callbackQueue, withHandler: Self.makeActivityHandler(sink: sink))
        return stream
    }

    public func stop() {
        sink?.finish()
        manager.stopActivityUpdates()
        manager.stopStatusUpdates()
        callbackQueue.cancelAllOperations()
    }

    private static var authorization: MotionAuthorization {
        switch CMHeadphoneActivityManager.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    // Core Motion 舊式 block 沒有 Sendable 標記。工廠明確脫離主 actor，
    // 避免 Swift 6 將背景回調推斷為主 actor 並觸發執行器斷言。
    nonisolated static func makeActivityHandler(sink: ActivityEventSink) -> @Sendable (CMMotionActivity?, (any Error)?) -> Void {
        { @Sendable activity, error in
            if let error {
                sink.yield(.failure(Self.errorDescription(error)))
                return
            }
            guard let activity else {
                sink.yield(.failure("Core Motion 活動回調沒有包含資料或錯誤。"))
                return
            }
            let confidence: ActivityConfidence
            switch activity.confidence {
            case .low: confidence = .low
            case .medium: confidence = .medium
            case .high: confidence = .high
            @unknown default: confidence = .unknown
            }
            // startDate 是活動變化時間；timestamp 是資料有效時的開機相對秒數。
            // 到達時間另外記錄，不把活動開始時間直接當作持續觀察時間。
            let observation = ActivityObservation(
                timestamp: activity.timestamp, startDate: activity.startDate,
                receivedAt: Date(), receivedUptime: ProcessInfo.processInfo.systemUptime,
                confidence: confidence, stationary: activity.stationary,
                walking: activity.walking, running: activity.running,
                unknown: activity.unknown, automotive: activity.automotive
            )
            // cycling 在 macOS 不可用；官方耳機來源也未支援此分類。
            sink.yield(.observation(observation))
        }
    }

    nonisolated static func makeStatusHandler(sink: ActivityEventSink) -> @Sendable (CMHeadphoneActivityManager.Status, (any Error)?) -> Void {
        { @Sendable status, error in
            if let error {
                sink.yield(.failure(Self.errorDescription(error)))
                return
            }
            switch status {
            case .connected: sink.yield(.connection(.connected))
            case .disconnected: sink.yield(.connection(.disconnected))
            @unknown default: sink.yield(.failure("耳機活動連接狀態不明；離座判定已暫停。"))
            }
        }
    }

    nonisolated private static func errorDescription(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) (\(error.code)): \(error.localizedDescription)"
    }
}
