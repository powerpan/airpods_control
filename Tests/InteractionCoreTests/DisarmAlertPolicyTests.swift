import Foundation
import Testing
@testable import InteractionCore

private func run(_ policy: inout DisarmAlertPolicy, _ observation: DisarmAlertPolicy.Observation,
                 from start: Double, through end: Double) -> [Double] {
    var alerts: [Double] = []
    for index in 0...Int(((end - start) / 0.1).rounded()) {
        let time = start + Double(index) * 0.1
        if policy.observe(observation, at: time) { alerts.append(time) }
    }
    return alerts
}

@Test func launchBeforeTheFirstCalibrationNeverAlerts() {
    var policy = DisarmAlertPolicy(delay: 5, minimumInterval: 300)
    #expect(run(&policy, .off, from: 0, through: 1).isEmpty)
    #expect(run(&policy, .notArmed, from: 1.1, through: 60).isEmpty)
}

@Test func armedThenNotArmedAlertsOnceAfterTheDelay() {
    var policy = DisarmAlertPolicy(delay: 5, minimumInterval: 300)
    #expect(run(&policy, .armed, from: 0, through: 2).isEmpty)
    let alerts = run(&policy, .notArmed, from: 2.1, through: 30)
    #expect(alerts.count == 1)
    #expect(((7.1 - 1e-6)...(7.2 + 1e-6)).contains(alerts.first ?? 0))
}

@Test func aBriefRearmWaitDoesNotAlert() {
    var policy = DisarmAlertPolicy(delay: 5, minimumInterval: 300)
    _ = run(&policy, .armed, from: 0, through: 1)
    // Settings change or recalibration: neutral dwell re-arms within a second.
    #expect(run(&policy, .notArmed, from: 1.1, through: 2).isEmpty)
    #expect(run(&policy, .armed, from: 2.1, through: 3).isEmpty)
    #expect(run(&policy, .notArmed, from: 3.1, through: 7).isEmpty)
    #expect(run(&policy, .armed, from: 7.1, through: 8).isEmpty)
}

@Test func alertsAreRateLimitedAndNeedARealRearm() {
    var policy = DisarmAlertPolicy(delay: 5, minimumInterval: 300)
    _ = run(&policy, .armed, from: 0, through: 1)
    #expect(run(&policy, .notArmed, from: 1.1, through: 10).count == 1)
    _ = run(&policy, .armed, from: 10.1, through: 11)
    #expect(run(&policy, .notArmed, from: 11.1, through: 20).isEmpty) // within the interval
    _ = run(&policy, .armed, from: 400, through: 401)
    #expect(run(&policy, .notArmed, from: 401.1, through: 410).count == 1)
}

@Test func exerciseAndShieldAreHeldButTurningProtectionOffForgetsTheArming() {
    var exercise = DisarmAlertPolicy(delay: 5, minimumInterval: 300)
    _ = run(&exercise, .armed, from: 0, through: 1)
    #expect(run(&exercise, .held, from: 1.1, through: 60).isEmpty)
    // The exercise ended and cleared the reference: the loss is still reported.
    #expect(run(&exercise, .notArmed, from: 60.1, through: 70).count == 1)

    var off = DisarmAlertPolicy(delay: 5, minimumInterval: 300)
    _ = run(&off, .armed, from: 0, through: 1)
    _ = run(&off, .off, from: 1.1, through: 2)
    #expect(run(&off, .notArmed, from: 2.1, through: 30).isEmpty)
}
