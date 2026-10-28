import Foundation
import Testing
@testable import InteractionCore

private let privacyReference = UUID(uuidString: "80000000-0000-0000-0000-000000000001")!

private func pose(_ time: Double, yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
                  speed: Double = 0, reference: UUID = privacyReference) -> InteractionPose {
    InteractionPose(timestamp: time, receivedUptime: time + 10, yaw: yaw, pitch: pitch,
                    roll: roll, angularSpeed: speed, calibrationID: reference)
}

private func feed(_ machine: inout PrivacyMachine, from start: Double, through end: Double,
                  yaw: Double = 0, speed: Double = 0, reference: UUID = privacyReference) {
    for index in 0...Int(((end - start) / 0.1).rounded()) {
        machine.process(pose(start + Double(index) * 0.1, yaw: yaw, speed: speed, reference: reference))
    }
}

private func armed() -> PrivacyMachine {
    var machine = PrivacyMachine()
    machine.setAutomaticEnabled(true)
    feed(&machine, from: 0, through: 0.6)
    return machine
}

private func shielded() -> PrivacyMachine {
    var machine = armed()
    machine.process(pose(0.7, yaw: 15))
    machine.process(pose(0.8, yaw: 30))
    feed(&machine, from: 0.9, through: 1.6, yaw: 40)
    return machine
}

@Test func privacyRequiresCalibrationNeutralDwellAndContinuousAwayEvidence() {
    var machine = PrivacyMachine()
    machine.setAutomaticEnabled(true)
    #expect(machine.phase == .needsCalibration)
    feed(&machine, from: 0, through: 0.4)
    #expect(machine.phase == .waitingForNeutral)
    machine.process(pose(0.5))
    #expect(machine.phase == .watching)
    machine.process(pose(0.6, yaw: 15))
    machine.process(pose(0.7, yaw: 30))
    feed(&machine, from: 0.8, through: 1.3, yaw: 40)
    #expect(!machine.isShielded)
    machine.process(pose(1.4, yaw: 40))
    #expect(machine.isShielded)
    #expect(!machine.requiresManualReveal)
}

@Test func privacyHysteresisAndStableReturnPreventFlicker() {
    var machine = shielded()
    #expect(machine.isShielded)
    feed(&machine, from: 1.7, through: 2.4, yaw: 25)
    #expect(machine.isShielded)
    #expect(machine.phase == .shielded)
    feed(&machine, from: 2.5, through: 3.1, yaw: 15, speed: 25)
    #expect(machine.isShielded)
    feed(&machine, from: 3.2, through: 3.6, yaw: 15)
    #expect(machine.isShielded)
    machine.process(pose(3.7, yaw: 15))
    #expect(!machine.isShielded)
    #expect(machine.phase == .watching)
}

@Test func returningBelowTriggerResetsTheEntireTriggerDelay() {
    var machine = armed()
    machine.process(pose(0.7, yaw: 15))
    machine.process(pose(0.8, yaw: 30))
    feed(&machine, from: 0.9, through: 1.3, yaw: 36)
    machine.process(pose(1.4, yaw: 34))
    feed(&machine, from: 1.5, through: 2, yaw: 36)
    #expect(!machine.isShielded)
    machine.process(pose(2.1, yaw: 36))
    #expect(machine.isShielded)
}

@Test func manualShieldNeverAutomaticallyRevealsAndManualExitRearmsOnlyAtNeutral() {
    var machine = armed()
    machine.manualShield()
    feed(&machine, from: 0.7, through: 2)
    #expect(machine.isShielded)
    #expect(machine.requiresManualReveal)
    machine.manualReveal()
    feed(&machine, from: 2.1, through: 3.5, yaw: 40)
    #expect(!machine.isShielded)
    #expect(machine.phase == .waitingForNeutral)
    machine.process(pose(3.6, yaw: 25))
    feed(&machine, from: 3.7, through: 4.3, yaw: 10)
    #expect(machine.phase == .watching)
}

@Test func disconnectedShieldRemainsLatchedAfterFreshDataAndNewCalibration() {
    var machine = shielded()
    machine.invalidatePose(reason: "斷開")
    #expect(machine.isShielded)
    #expect(machine.requiresManualReveal)
    let newReference = UUID()
    feed(&machine, from: 2, through: 3, reference: newReference)
    #expect(machine.isShielded)
    #expect(machine.requiresManualReveal)
    machine.setAutomaticEnabled(false)
    #expect(machine.isShielded)
    machine.manualReveal()
    #expect(!machine.isShielded)
    #expect(machine.phase == .disabled)
}

@Test func privacySampleGapOrReferenceChangeCannotCompleteRecovery() {
    var machine = shielded()
    machine.process(pose(1.7, yaw: 25))
    feed(&machine, from: 1.8, through: 2.1, yaw: 15)
    machine.process(pose(2.6, yaw: 15))
    #expect(machine.isShielded)
    #expect(machine.requiresManualReveal)

    var referenceChange = shielded()
    referenceChange.process(pose(1.7, reference: UUID()))
    #expect(referenceChange.isShielded)
    #expect(referenceChange.requiresManualReveal)
}

@Test func angleWrapIsNotMisclassifiedAsAnImpossibleJump() {
    var machine = armed()
    for index in 1...10 { machine.process(pose(0.6 + Double(index) * 0.1, yaw: Double(index) * 17)) }
    machine.process(pose(1.7, yaw: 179))
    machine.process(pose(1.8, yaw: -179))
    #expect(machine.isShielded)
    #expect(!machine.requiresManualReveal)
}

@Test func suddenPoseJumpOrMalformedValuesNeverRevealAShield() {
    var machine = shielded()
    machine.process(pose(1.7, yaw: -40))
    #expect(machine.requiresManualReveal)
    machine.process(pose(.nan))
    #expect(machine.isShielded)
    #expect(machine.requiresManualReveal)
}

@Test func exerciseSuspensionDoesNotDestroyPrivacyPreferenceOrExposeManualShield() {
    var machine = armed()
    machine.setSuspended(true)
    feed(&machine, from: 0.7, through: 2, yaw: 45)
    #expect(!machine.isShielded)
    #expect(machine.automaticEnabled)
    #expect(machine.phase == .suspended)
    machine.manualShield()
    machine.setSuspended(false)
    #expect(machine.isShielded)
    #expect(machine.requiresManualReveal)
}

@Test func privacySettingsEnforceFiniteValuesAndARealHysteresisGap() {
    let settings = PrivacySettings(triggerAngle: .nan, returnAngle: 90, triggerDelay: 0, returnDelay: .infinity).sanitized()
    #expect(settings.triggerAngle == 35)
    #expect(settings.returnAngle == 30)
    #expect(settings.triggerDelay == 0.2)
    #expect(settings.returnDelay == 0.5)
}

@Test func armedOnlyWhileTurningAwayWouldStartTheShieldCountdown() {
    var machine = PrivacyMachine()
    #expect(!machine.isArmed)
    machine.setAutomaticEnabled(true)
    #expect(!machine.isArmed)
    feed(&machine, from: 0, through: 0.4)
    #expect(machine.phase == .waitingForNeutral)
    #expect(!machine.isArmed)
    machine.process(pose(0.5))
    #expect(machine.phase == .watching)
    #expect(machine.isArmed)
    machine.process(pose(0.6, yaw: 15))
    machine.process(pose(0.7, yaw: 30))
    machine.process(pose(0.8, yaw: 40))
    #expect(machine.phase == .turningAway)
    #expect(machine.isArmed)
    feed(&machine, from: 0.9, through: 1.4, yaw: 40)
    #expect(machine.isShielded)
    #expect(!machine.isArmed)

    var suspended = armed()
    suspended.setSuspended(true)
    #expect(!suspended.isArmed)
    suspended.setSuspended(false)
    #expect(!suspended.isArmed)

    var disabled = armed()
    disabled.setAutomaticEnabled(false)
    #expect(!disabled.isArmed)

    var lost = armed()
    lost.invalidatePose()
    #expect(!lost.isArmed)

    var replaced = armed()
    replaced.process(pose(0.7, reference: UUID()))
    #expect(!replaced.isArmed)
}

@Test func steepPitchKeepsWatchingPhaseButIsNotArmed() {
    var machine = armed()
    #expect(machine.isArmed)
    for (index, pitch) in [20.0, 40, 60, 80].enumerated() {
        machine.process(pose(0.7 + Double(index) * 0.1, pitch: pitch))
    }
    #expect(machine.phase == .watching)
    #expect(!machine.isArmed)
    machine.process(pose(1.1, yaw: 20, pitch: 80))
    machine.process(pose(1.2, yaw: 40, pitch: 80))
    for index in 0...10 { machine.process(pose(1.3 + Double(index) * 0.1, yaw: 40, pitch: 80)) }
    #expect(!machine.isShielded)
    #expect(machine.phase == .watching)
    #expect(!machine.isArmed)
    machine.process(pose(2.4, yaw: 20, pitch: 80))
    machine.process(pose(2.5, pitch: 80))
    for (index, pitch) in [60.0, 40, 20, 0].enumerated() {
        machine.process(pose(2.6 + Double(index) * 0.1, pitch: pitch))
    }
    #expect(machine.phase == .watching)
    #expect(machine.isArmed)
}

@Test func losingDataWhileArmedFailsClosedUntilManualReveal() {
    var watching = armed()
    #expect(watching.isArmed)
    watching.poseDataLost(reason: "耳機已斷開", at: 100, immediate: true)
    #expect(watching.isShielded)
    #expect(watching.requiresManualReveal)
    #expect(watching.phase == .shielded)
    #expect(!watching.isArmed)
    // Fresh data, a new reference and the neutral pose cannot reveal it.
    feed(&watching, from: 2, through: 4, reference: UUID())
    #expect(watching.isShielded)
    #expect(watching.requiresManualReveal)
    watching.manualReveal()
    #expect(!watching.isShielded)
    #expect(watching.phase == .waitingForNeutral)

    var turning = armed()
    turning.process(pose(0.7, yaw: 15))
    turning.process(pose(0.8, yaw: 30))
    turning.process(pose(0.9, yaw: 40))
    #expect(turning.phase == .turningAway)
    turning.poseDataLost(at: 100, immediate: true)
    #expect(turning.isShielded)
    #expect(turning.requiresManualReveal)

    var returning = shielded()
    returning.process(pose(1.7, yaw: 25))
    feed(&returning, from: 1.8, through: 2.1, yaw: 10)
    #expect(returning.phase == .returning)
    returning.poseDataLost(at: 100)
    #expect(returning.isShielded)
    #expect(returning.requiresManualReveal)
}

@Test func aStalledStreamShieldsOnlyIfDataDoesNotResumeWithinTheGrace() {
    var stalled = armed()
    stalled.poseDataLost(reason: "資料中斷", at: 100)
    #expect(!stalled.isShielded)
    #expect(stalled.dataLossSince == 100)
    // A later, different invalidation (reference lost) keeps the original start.
    stalled.poseDataLost(reason: "參考姿態已失效", at: 100.4)
    stalled.checkDataLoss(at: 100 + PrivacyMachine.dataLossGrace - 0.1)
    #expect(!stalled.isShielded)
    stalled.checkDataLoss(at: 100 + PrivacyMachine.dataLossGrace)
    #expect(stalled.isShielded)
    #expect(stalled.requiresManualReveal)
    #expect(stalled.status.hasPrefix("資料中斷"))
    #expect(stalled.dataLossSince == nil)

    var hiccup = armed()
    hiccup.poseDataLost(at: 100)
    hiccup.process(pose(0.7)) // valid calibrated data resumed
    hiccup.checkDataLoss(at: 105)
    #expect(!hiccup.isShielded)
    #expect(hiccup.phase == .waitingForNeutral)
    feed(&hiccup, from: 0.8, through: 1.3)
    #expect(hiccup.isArmed)

    for cancel in 0..<4 {
        var machine = armed()
        machine.poseDataLost(at: 100)
        switch cancel {
        case 0: machine.invalidatePose(reason: "採集已停止")
        case 1: machine.setSuspended(true)
        case 2: machine.setAutomaticEnabled(false)
        default: machine.updateSettings(PrivacySettings(shieldOnDataLossEnabled: false))
        }
        machine.checkDataLoss(at: 200)
        #expect(!machine.isShielded)
        #expect(machine.dataLossSince == nil)
    }
}

@Test func dataLossOnlyShieldsWhenArmedAndTheSettingIsOn() {
    var optedOut = PrivacyMachine(settings: PrivacySettings(shieldOnDataLossEnabled: false))
    optedOut.setAutomaticEnabled(true)
    feed(&optedOut, from: 0, through: 0.6)
    #expect(optedOut.phase == .watching)
    optedOut.poseDataLost(reason: "資料中斷", at: 100, immediate: true)
    #expect(!optedOut.isShielded)
    #expect(optedOut.phase == .needsCalibration)

    var off = PrivacyMachine()
    feed(&off, from: 0, through: 0.6)
    off.poseDataLost(at: 100, immediate: true)
    #expect(!off.isShielded)
    #expect(off.phase == .disabled)

    var uncalibrated = PrivacyMachine()
    uncalibrated.setAutomaticEnabled(true)
    uncalibrated.poseDataLost(at: 100, immediate: true)
    #expect(!uncalibrated.isShielded)

    var waiting = PrivacyMachine()
    waiting.setAutomaticEnabled(true)
    feed(&waiting, from: 0, through: 0.2)
    #expect(waiting.phase == .waitingForNeutral)
    waiting.poseDataLost(at: 100, immediate: true)
    #expect(!waiting.isShielded)

    var exercising = armed()
    exercising.setSuspended(true)
    #expect(!exercising.isArmed)
    exercising.poseDataLost(at: 100, immediate: true)
    #expect(!exercising.isShielded)
    #expect(exercising.phase == .suspended)

    // The ordinary invalidation (normal stop, reference change) still disarms quietly.
    var stopped = armed()
    stopped.invalidatePose(reason: "採集已停止")
    #expect(!stopped.isShielded)
    #expect(stopped.phase == .needsCalibration)
    var recalibrated = armed()
    recalibrated.resetReference()
    #expect(!recalibrated.isShielded)
}

@Test func oldPrivacyPreferencesDefaultShieldOnDataLossEnabled() throws {
    let old = Data(#"{"triggerAngle":42,"returnAngle":18,"triggerDelay":0.8,"returnDelay":0.7,"departureDetectionEnabled":false}"#.utf8)
    let decoded = try JSONDecoder().decode(PrivacySettings.self, from: old)
    #expect(decoded.triggerAngle == 42)
    #expect(decoded.returnAngle == 18)
    #expect(decoded.triggerDelay == 0.8)
    #expect(decoded.returnDelay == 0.7)
    let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
    #expect(!encoded.contains("departureDetectionEnabled"))
    #expect(decoded.shieldOnDataLossEnabled)
    let off = PrivacySettings(shieldOnDataLossEnabled: false)
    #expect(try JSONDecoder().decode(PrivacySettings.self, from: JSONEncoder().encode(off)) == off)
    #expect(!off.sanitized().shieldOnDataLossEnabled)
}

@Test func recoveryDeadlineStartsAtLastSampleAndLatePoseCannotCancelIt() {
    var machine = armed()
    machine.poseDataLost(at: 100.4, lastSampleUptime: 100)
    #expect(machine.dataLossSince == 100)
    machine.checkDataLoss(at: 102.99)
    #expect(!machine.isShielded)
    var resumed = pose(3.7)
    resumed.receivedUptime = 103
    machine.process(resumed)
    #expect(machine.isShielded)
    #expect(machine.requiresManualReveal)
}
