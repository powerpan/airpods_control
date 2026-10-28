import Foundation
import Testing
@testable import InteractionCore

private let activityOrigin = Date(timeIntervalSinceReferenceDate: 10_000)

private func activity(_ time: Double, confidence: ActivityConfidence = .high,
                      walking: Bool = true, running: Bool = false,
                      stationary: Bool = false, unknown: Bool = false, automotive: Bool = false,
                      start: Double? = nil, receipt: Double? = nil) -> ActivityObservation {
    ActivityObservation(timestamp: time, startDate: activityOrigin.addingTimeInterval(start ?? time),
                        receivedAt: activityOrigin.addingTimeInterval(receipt ?? time),
                        receivedUptime: receipt ?? time, confidence: confidence,
                        stationary: stationary, walking: walking, running: running,
                        unknown: unknown, automotive: automotive)
}

private func checkAdvance(_ detector: inout DepartureMachine, at time: Double, expected: Bool,
                          sourceLocation: SourceLocation = #_sourceLocation) {
    let result = detector.advance(at: time)
    #expect(result == expected, sourceLocation: sourceLocation)
}

private func confirmedDesk(cooldown: Double = 0) -> DepartureMachine {
    var detector = DepartureMachine(rearmDelay: cooldown)
    detector.confirmDesk(at: 10, date: activityOrigin.addingTimeInterval(10))
    return detector
}

@Test func singleReliableWalkingChangeCanCompleteDwellWithoutRepeatedCallbacks() {
    var detector = confirmedDesk()
    detector.observe(activity(11), now: 11)
    checkAdvance(&detector, at: 13.4, expected: false)
    #expect(detector.progress > 0.9)
    checkAdvance(&detector, at: 13.5, expected: true)
    checkAdvance(&detector, at: 20, expected: false)
}

@Test func activityAloneNeverEstablishesDeskPresence() {
    var detector = DepartureMachine()
    detector.observe(activity(11, walking: false, stationary: true), now: 11)
    detector.observe(activity(50), now: 50)
    checkAdvance(&detector, at: 100, expected: false)
    #expect(!detector.isDeskConfirmed)
}

@Test func interruptionOrStationaryCancelsWalkingAndRequiresFreshDuration() {
    var detector = confirmedDesk()
    detector.observe(activity(11), now: 11)
    detector.observe(activity(12, walking: false, stationary: true), now: 12)
    checkAdvance(&detector, at: 30, expected: false)
    detector.observe(activity(31), now: 31)
    checkAdvance(&detector, at: 33.4, expected: false)
    checkAdvance(&detector, at: 33.5, expected: true)
    detector.invalidateDesk()
    #expect(!detector.isDeskConfirmed)
    detector.observe(activity(34), now: 34)
    checkAdvance(&detector, at: 50, expected: false)
}

@Test func lowConfidenceUnknownAndConflictingLabelsCannotTriggerDeparture() {
    let uncertain = [
        activity(11, confidence: .low), activity(11, confidence: .medium),
        activity(11, confidence: .unknown), activity(11, stationary: true),
        activity(11, unknown: true), activity(11, automotive: true),
        activity(11, walking: false)
    ]
    for observation in uncertain {
        var detector = confirmedDesk()
        detector.observe(observation, now: 11)
        checkAdvance(&detector, at: 100, expected: false)
        #expect(detector.progress == 0)
    }
}

@Test func walkingAndRunningLabelsMayCoexistWithoutAssumingMutualExclusion() {
    for walking in [false, true] {
        var detector = confirmedDesk()
        detector.observe(activity(11, walking: walking, running: true), now: 11)
        checkAdvance(&detector, at: 13.5, expected: true)
    }
}

@Test func shortWalkingDoesNotAccumulateAcrossLowConfidenceUpdates() {
    var detector = confirmedDesk()
    detector.observe(activity(11), now: 11)
    detector.observe(activity(13, confidence: .low), now: 13)
    checkAdvance(&detector, at: 13.5, expected: false)
    detector.observe(activity(14), now: 14)
    checkAdvance(&detector, at: 16.4, expected: false)
    checkAdvance(&detector, at: 16.5, expected: true)
}

@Test func delayedActivityNeverBackfillsDwellFromItsStartDate() {
    var detector = confirmedDesk()
    detector.observe(activity(11, receipt: 15), now: 15)
    checkAdvance(&detector, at: 15, expected: false)
    checkAdvance(&detector, at: 17.4, expected: false)
    checkAdvance(&detector, at: 17.5, expected: true)
}

@Test func staleFutureMalformedAndQueuedObservationsCannotTrigger() {
    var stale = activity(11, receipt: 17)
    let future = activity(11, start: 12)
    var malformed = activity(11)
    malformed.timestamp = .nan
    let preEpoch = activity(9, receipt: 11)
    for observation in [stale, future, malformed, preEpoch] {
        var detector = confirmedDesk()
        detector.observe(observation, now: observation.receivedUptime)
        checkAdvance(&detector, at: 100, expected: false)
    }
    stale = activity(11)
    var detector = confirmedDesk()
    detector.observe(stale, now: 12)
    checkAdvance(&detector, at: 100, expected: false)
}

@Test func duplicateAndOutOfOrderResultsConservativelyCancelCandidate() {
    for next in [activity(11), activity(10.5, receipt: 12), activity(12, start: 10.5)] {
        var detector = confirmedDesk()
        detector.observe(activity(11), now: 11)
        detector.observe(next, now: next.receivedUptime)
        checkAdvance(&detector, at: 100, expected: false)
    }
}

@Test func resetRejectsOldWalkingAndAppliesCooldownBeforeNewDwell() {
    var detector = confirmedDesk(cooldown: 5)
    detector.observe(activity(11), now: 11)
    checkAdvance(&detector, at: 15, expected: false)
    #expect(detector.progress == 0)
    checkAdvance(&detector, at: 17.5, expected: true)
    detector.resetEvidence(at: 20, date: activityOrigin.addingTimeInterval(20))
    #expect(detector.isDeskConfirmed)
    detector.observe(activity(21, start: 19), now: 21)
    checkAdvance(&detector, at: 22, expected: false)
    detector.observe(activity(23), now: 23)
    checkAdvance(&detector, at: 25, expected: false)
    checkAdvance(&detector, at: 27.4, expected: false)
    checkAdvance(&detector, at: 27.5, expected: true)
}

@Test func clockRegressionAndInvalidDeskCannotAccumulateEvidence() {
    var detector = confirmedDesk()
    detector.observe(activity(11), now: 11)
    checkAdvance(&detector, at: 12, expected: false)
    checkAdvance(&detector, at: 11.5, expected: false)
    checkAdvance(&detector, at: 100, expected: false)
    detector.confirmDesk(at: .nan, date: activityOrigin)
    #expect(!detector.isDeskConfirmed)
}
