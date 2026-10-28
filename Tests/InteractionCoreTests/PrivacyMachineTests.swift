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
    machine.invalidatePose(reason: "断开")
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
