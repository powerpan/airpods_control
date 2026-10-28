import Foundation
import Testing
@testable import InteractionCore

private let exerciseReference = UUID(uuidString: "80000000-0000-0000-0000-000000000002")!
private let defaultLeftTarget = NeckExerciseMachine().target

private func exercisePose(_ time: Double, yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
                          speed: Double = 0, reference: UUID = exerciseReference) -> InteractionPose {
    InteractionPose(timestamp: time, receivedUptime: time + 10, yaw: yaw, pitch: pitch,
                    roll: roll, angularSpeed: speed, calibrationID: reference)
}

private func feed(_ machine: inout NeckExerciseMachine, time: inout Double,
                  target: ExerciseTarget, count: Int = 8, speed: Double = 0) {
    for _ in 0..<count {
        time += 0.1
        machine.process(exercisePose(time, yaw: target.yaw, pitch: target.pitch, roll: target.roll, speed: speed))
    }
}

private func ready() -> NeckExerciseMachine {
    var machine = NeckExerciseMachine()
    machine.start(at: 0)
    machine.calibrate(referenceID: exerciseReference)
    return machine
}

@Test func exerciseCannotStartJudgingFromAnExistingUnconfirmedReference() {
    var machine = NeckExerciseMachine()
    machine.process(exercisePose(0))
    machine.start(at: 0)
    var time = 0.0
    feed(&machine, time: &time, target: defaultLeftTarget, count: 20)
    #expect(machine.phase == .awaitingCalibration)
    #expect(machine.completedCount == 0)
    #expect(machine.elapsed == 0)
}

@Test func everyExerciseRequiresStableTargetAndObservedNeutralReturn() {
    var machine = ready()
    var time = 0.0
    for step in 0..<5 {
        let target = machine.target
        feed(&machine, time: &time, target: target, count: 8)
        #expect(machine.phase == .returning)
        #expect(machine.completedCount == step)
        #expect(machine.target == ExerciseTarget())
        feed(&machine, time: &time, target: ExerciseTarget(), count: 7)
        #expect(machine.completedCount == step + 1)
    }
    #expect(machine.phase == .completed)
    #expect(machine.skippedCount == 0)
    #expect(!machine.isActive)
    #expect(machine.elapsed > 5)
}

@Test func timeAloneWrongAxisOrWrongDirectionCannotCompleteAnExercise() {
    var machine = ready()
    var time = 0.0
    feed(&machine, time: &time, target: ExerciseTarget(), count: 30)
    #expect(machine.completedCount == 0)
    feed(&machine, time: &time, target: ExerciseTarget(roll: -12), count: 20)
    #expect(machine.phase == .approaching)
    feed(&machine, time: &time, target: ExerciseTarget(yaw: -defaultLeftTarget.yaw), count: 20)
    #expect(machine.phase == .approaching)
    #expect(machine.progress == 0)
}

@Test func smallTargetRangeStillRequiresDistinctReturnMovement() {
    var machine = NeckExerciseMachine(settings: NeckExerciseSettings(yawAngle: 10, tiltAngle: 5, nodAngle: 5))
    machine.start(at: 0)
    machine.calibrate(referenceID: exerciseReference)
    machine.skip(); machine.skip(); machine.skip(); machine.skip()
    var time = 0.0
    feed(&machine, time: &time, target: ExerciseTarget(pitch: machine.target.pitch * 0.8), count: 20)
    #expect(machine.phase == .approaching)
    feed(&machine, time: &time, target: ExerciseTarget(pitch: machine.target.pitch * 1.2), count: 20)
    #expect(machine.phase == .returning)
    #expect(machine.completedCount == 0)
    feed(&machine, time: &time, target: ExerciseTarget(), count: 7)
    #expect(machine.completedCount == 1)
    #expect(machine.skippedCount == 4)
}

@Test func exceedingAmplitudeDoesNotRequireMatchingAPointOrOtherAxes() {
    var machine = ready()
    var time = 0.0
    feed(&machine, time: &time, target: ExerciseTarget(yaw: defaultLeftTarget.yaw * 1.4,
                                                    pitch: 9, roll: 10), count: 8, speed: 10)
    #expect(machine.phase == .returning)
    #expect(machine.completedCount == 0)
    feed(&machine, time: &time, target: ExerciseTarget(yaw: defaultLeftTarget.yaw * 0.7), count: 1)
    feed(&machine, time: &time, target: ExerciseTarget(), count: 7)
    #expect(machine.completedCount == 1)
}

@Test func targetHoldResetsAfterNoiseAndNeverAccumulatesSeparateVisits() {
    var machine = ready()
    var time = 0.0
    feed(&machine, time: &time, target: defaultLeftTarget, count: 5)
    feed(&machine, time: &time, target: ExerciseTarget(yaw: defaultLeftTarget.yaw / 2), count: 1)
    feed(&machine, time: &time, target: defaultLeftTarget, count: 6)
    #expect(machine.phase == .approaching)
    feed(&machine, time: &time, target: defaultLeftTarget, count: 1)
    #expect(machine.phase == .returning)
}

@Test func pauseFreezesJudgmentAndResumingRestartsTheHold() {
    var machine = ready()
    var time = 0.0
    feed(&machine, time: &time, target: defaultLeftTarget, count: 5)
    let elapsed = machine.elapsed
    machine.pause()
    feed(&machine, time: &time, target: defaultLeftTarget, count: 20)
    #expect(machine.phase == .paused)
    #expect(machine.elapsed == elapsed)
    #expect(machine.progress == 0)
    machine.resume()
    feed(&machine, time: &time, target: defaultLeftTarget, count: 5)
    #expect(machine.phase == .approaching)
    feed(&machine, time: &time, target: defaultLeftTarget, count: 2)
    #expect(machine.phase == .returning)
}

@Test func dataLossPausesAndCannotTurnAnOldTargetIntoACompletedReturn() {
    var machine = ready()
    var time = 0.0
    feed(&machine, time: &time, target: defaultLeftTarget, count: 8)
    #expect(machine.phase == .returning)
    machine.invalidatePose()
    #expect(machine.phase == .signalLost)
    machine.resume()
    #expect(machine.phase == .signalLost)
    feed(&machine, time: &time, target: ExerciseTarget(), count: 10)
    #expect(machine.completedCount == 0)
    #expect(machine.phase == .signalLost)
    machine.resume()
    feed(&machine, time: &time, target: ExerciseTarget(), count: 10)
    #expect(machine.phase == .approaching)
    #expect(machine.completedCount == 0)
}

@Test func longSampleGapOrCalibrationReplacementRequiresFreshJudgment() {
    var machine = ready()
    machine.process(exercisePose(0, yaw: defaultLeftTarget.yaw))
    machine.process(exercisePose(0.1, yaw: defaultLeftTarget.yaw))
    machine.process(exercisePose(1, yaw: defaultLeftTarget.yaw))
    #expect(machine.phase == .signalLost)
    machine.process(exercisePose(1.1, reference: UUID()))
    #expect(machine.phase == .awaitingCalibration)
    #expect(machine.completedCount == 0)
    machine.calibrate(referenceID: exerciseReference)
    #expect(machine.phase == .approaching)
    #expect(machine.progress == 0)
}

@Test func dataLossWhileManuallyPausedAlsoDiscardsTheAcquiredTarget() {
    var machine = ready()
    var time = 0.0
    feed(&machine, time: &time, target: defaultLeftTarget, count: 8)
    #expect(machine.phase == .returning)
    machine.pause()
    machine.invalidatePose()
    feed(&machine, time: &time, target: ExerciseTarget(), count: 10)
    #expect(machine.phase == .paused)
    machine.resume()
    feed(&machine, time: &time, target: ExerciseTarget(), count: 10)
    #expect(machine.phase == .approaching)
    #expect(machine.completedCount == 0)
}

@Test func skipsAreNotCompletedActionsAndAUserCanStopFromAnyState() {
    var machine = ready()
    for _ in 0..<5 { machine.skip() }
    #expect(machine.phase == .completed)
    #expect(machine.skippedCount == 5)
    #expect(machine.completedCount == 0)
    machine.start(at: 10)
    machine.invalidatePose()
    #expect(machine.phase == .awaitingCalibration)
    machine.stop()
    #expect(machine.phase == .idle)
    #expect(!machine.isActive)
}

@Test func defaultDirectionsMatchTheObservedAirPodsPro2Movements() {
    var machine = ready()
    #expect(machine.settings.yawSign == -1)
    #expect(machine.currentStep == .turnLeft)
    #expect(machine.target.yaw == 20)
    machine.skip()
    #expect(machine.currentStep == .turnRight)
    #expect(machine.target.yaw == -20)
    machine.skip()
    #expect(machine.currentStep == .tiltLeft)
    #expect(machine.target.roll == -12)
    machine.skip()
    #expect(machine.currentStep == .tiltRight)
    #expect(machine.target.roll == 12)
    machine.skip()
    #expect(machine.currentStep == .nod)
    #expect(machine.target.pitch == -10)
    #expect(machine.settings.pitchSign == -1)
    #expect(machine.settings.rollSign == 1)
}

@Test func configurableDirectionSignsAreAppliedToTargetsNotToSensorValues() {
    var machine = NeckExerciseMachine(settings: NeckExerciseSettings(yawSign: 1, pitchSign: 1, rollSign: -1))
    machine.start(at: 0)
    machine.calibrate(referenceID: exerciseReference)
    #expect(machine.target.yaw == -20)
    machine.skip(); machine.skip()
    #expect(machine.target.roll == 12)
    machine.skip(); machine.skip()
    #expect(machine.target.pitch == 10)
}

@Test func exerciseSettingsAreBoundedAndChangingThemRequiresRecalibration() {
    var machine = ready()
    machine.updateSettings(NeckExerciseSettings(yawAngle: 90, tiltAngle: .nan, nodAngle: 0, yawSign: 0))
    #expect(machine.settings.yawAngle == 35)
    #expect(machine.settings.tiltAngle == 12)
    #expect(machine.settings.nodAngle == 5)
    #expect(machine.settings.yawSign == 1)
    #expect(machine.phase == .awaitingCalibration)
}
