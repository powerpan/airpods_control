import Foundation

public enum ActivityConfidence: String, Sendable, Equatable {
    case low, medium, high, unknown
}

/// 活動標籤不互斥。保留變化時間、來源時間戳和本機接收時間，避免把延遲當成持續證據。
public struct ActivityObservation: Sendable, Equatable {
    public var timestamp: TimeInterval
    public var startDate: Date
    public var receivedAt: Date
    public var receivedUptime: TimeInterval
    public var confidence: ActivityConfidence
    public var stationary: Bool
    public var walking: Bool
    public var running: Bool
    public var unknown: Bool
    public var automotive: Bool

    public init(timestamp: TimeInterval, startDate: Date, receivedAt: Date,
                receivedUptime: TimeInterval, confidence: ActivityConfidence,
                stationary: Bool = false, walking: Bool = false, running: Bool = false,
                unknown: Bool = false, automotive: Bool = false) {
        self.timestamp = timestamp
        self.startDate = startDate
        self.receivedAt = receivedAt
        self.receivedUptime = receivedUptime
        self.confidence = confidence
        self.stationary = stationary
        self.walking = walking
        self.running = running
        self.unknown = unknown
        self.automotive = automotive
    }

    public var isReliableLocomotion: Bool {
        confidence == .high && (walking || running) && !stationary && !unknown && !automotive
    }
}

/// 只判斷連續的可靠步行證據，不估計位置，也不將靜止當作返回書桌。
/// 呼叫端必須在資料健康、已校準且未進行頸部活動時推進；中斷時清除證據。
public struct DepartureMachine: Sendable, Equatable {
    public private(set) var isDeskConfirmed = false
    public private(set) var progress = 0.0
    public let holdDuration: TimeInterval
    public let rearmDelay: TimeInterval

    private var epochUptime: TimeInterval?
    private var epochDate: Date?
    private var readyAt: TimeInterval?
    private var candidateStarted: TimeInterval?
    private var lastObservation: ActivityObservation?
    private var lastAdvance: TimeInterval?
    private var hasTriggered = false

    public init(holdDuration: TimeInterval = 2.5, rearmDelay: TimeInterval = 5) {
        self.holdDuration = bounded(holdDuration, 2...5, fallback: 2.5)
        self.rearmDelay = bounded(rearmDelay, 0...10, fallback: 5)
    }

    public func isRearming(at time: TimeInterval) -> Bool {
        guard isDeskConfirmed, let readyAt else { return false }
        return time < readyAt
    }

    public mutating func confirmDesk(at time: TimeInterval, date: Date) {
        guard time.isFinite, time >= 0, date.timeIntervalSinceReferenceDate.isFinite else {
            invalidateDesk()
            return
        }
        isDeskConfirmed = true
        resetEvidence(at: time, date: date)
    }

    public mutating func invalidateDesk() {
        isDeskConfirmed = false
        epochUptime = nil
        epochDate = nil
        readyAt = nil
        candidateStarted = nil
        lastObservation = nil
        lastAdvance = nil
        hasTriggered = false
        progress = 0
    }

    /// 手動解除或暫停後劃定新的事件邊界，禁止舊步行事件重新觸發。
    public mutating func resetEvidence(at time: TimeInterval, date: Date) {
        guard time.isFinite, time >= 0, date.timeIntervalSinceReferenceDate.isFinite else {
            invalidateDesk()
            return
        }
        epochUptime = time
        epochDate = date
        readyAt = time + rearmDelay
        candidateStarted = nil
        lastObservation = nil
        lastAdvance = nil
        hasTriggered = false
        progress = 0
    }

    public mutating func observe(_ observation: ActivityObservation, now: TimeInterval) {
        guard isDeskConfirmed, !hasTriggered,
              let epochUptime, let epochDate, let readyAt else { return }
        let sourceDelay = observation.receivedAt.timeIntervalSince(observation.startDate)
        let queueDelay = now - observation.receivedUptime
        let numbers = [observation.timestamp, observation.receivedUptime, now,
                       observation.startDate.timeIntervalSinceReferenceDate,
                       observation.receivedAt.timeIntervalSinceReferenceDate]
        guard numbers.allSatisfy(\.isFinite), observation.timestamp >= 0,
              observation.receivedUptime >= epochUptime, observation.startDate >= epochDate,
              sourceDelay >= 0, sourceDelay <= 5, queueDelay >= 0, queueDelay <= 0.5,
              observation.receivedAt >= epochDate else {
            clearCandidate()
            return
        }
        if let previous = lastObservation {
            guard observation.timestamp > previous.timestamp,
                  observation.receivedUptime > previous.receivedUptime,
                  observation.startDate >= previous.startDate else {
                clearCandidate()
                return
            }
        }
        lastObservation = observation
        guard observation.isReliableLocomotion else {
            clearCandidate()
            return
        }
        // 系統只在活動改變時回調；同一活動的持續證據由單調時鐘計算。
        if candidateStarted == nil { candidateStarted = max(observation.receivedUptime, readyAt) }
    }

    /// 不依賴新活動回調；已接受的分類保持有效，直到新分類、失聯或重置。
    @discardableResult
    public mutating func advance(at time: TimeInterval) -> Bool {
        guard time.isFinite, time >= 0 else { clearCandidate(); return false }
        if let lastAdvance, time < lastAdvance { clearCandidate(); return false }
        lastAdvance = time
        guard isDeskConfirmed, !hasTriggered, let candidateStarted else { return false }
        progress = min(1, max(0, (time - candidateStarted) / holdDuration))
        guard progress >= 1 - 1e-9 else { return false }
        hasTriggered = true
        return true
    }

    private mutating func clearCandidate() {
        candidateStarted = nil
        progress = 0
    }
}
