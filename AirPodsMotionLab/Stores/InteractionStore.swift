import AppKit
import Foundation
import Observation
import InteractionCore
import MotionRuntime

@MainActor
@Observable
final class InteractionStore {
    private(set) var snapshot = InteractionSnapshot()
    private(set) var privacySettings: PrivacySettings
    private(set) var exerciseSettings: NeckExerciseSettings
    private(set) var privacyEnabled: Bool
    private(set) var coveredDisplays = 0
    private(set) var isBusy = false
    @ObservationIgnored private let session: InteractionSession
    @ObservationIgnored private var overlay: PrivacyOverlayController?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var command: Task<Void, Never>?
    @ObservationIgnored private var pendingCommands = 0
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var sleepObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let disarmNotifier = DisarmNotifier()

    init(motion: MotionSession) {
        let defaults = UserDefaults.standard
        let privacy = defaults.data(forKey: "privacy.settings.v1")
            .flatMap { try? JSONDecoder().decode(PrivacySettings.self, from: $0) }?.sanitized() ?? PrivacySettings()
        let exercise = defaults.data(forKey: "exercise.settings.v1")
            .flatMap { try? JSONDecoder().decode(NeckExerciseSettings.self, from: $0) }?.sanitized() ?? NeckExerciseSettings()
        privacySettings = privacy
        exerciseSettings = exercise
        privacyEnabled = defaults.bool(forKey: "privacy.automatic.v1")
        session = InteractionSession(motion: motion, privacy: privacy, exercise: exercise)
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        overlay = PrivacyOverlayController { [weak self] in self?.hideShield() }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.perform { await $0.invalidateSensor(reason: "系統進入睡眠，遮擋保留；喚醒後重新校準。") }
            }
        }
        let session = session
        let enabled = privacyEnabled
        polling = Task { [weak self] in
            await session.activate()
            await session.setPrivacyEnabled(enabled)
            while !Task.isCancelled {
                let value = await session.snapshot()
                guard !Task.isCancelled else { break }
                if self?.pendingCommands == 0 { self?.apply(value) }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
    }

    func setPrivacyEnabled(_ enabled: Bool) {
        privacyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "privacy.automatic.v1")
        perform { await $0.setPrivacyEnabled(enabled) }
    }

    func showShield() { perform { await $0.showShield() } }
    func hideShield() {
        // A visible button/Escape always removes the windows immediately. The
        // serialized command clears the rule latch before snapshots can re-show.
        overlay?.hide()
        perform { await $0.hideShield() }
    }

    func startExercise() { perform { _ = await $0.startExercise() } }
    func calibrateExercise() { perform { _ = await $0.calibrateExercise() } }
    func pauseExercise() { perform { await $0.pauseExercise() } }
    func resumeExercise() { perform { await $0.resumeExercise() } }
    func skipExercise() { perform { await $0.skipExercise() } }
    func endExercise() { perform { await $0.endExercise() } }
    func calibrateNeutral() { perform { _ = await $0.calibrateNeutral() } }

    func updatePrivacySettings(_ settings: PrivacySettings) {
        let settings = settings.sanitized()
        privacySettings = settings
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "privacy.settings.v1") }
        perform { await $0.updatePrivacySettings(settings) }
    }

    func updateExerciseSettings(_ settings: NeckExerciseSettings) {
        let settings = settings.sanitized()
        exerciseSettings = settings
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "exercise.settings.v1") }
        perform { await $0.updateExerciseSettings(settings) }
    }

    private func perform(_ operation: @escaping @Sendable (InteractionSession) async -> Void) {
        guard !shuttingDown else { return }
        pendingCommands += 1
        isBusy = true
        let previous = command
        let session = session
        command = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation(session)
            let value = await session.snapshot()
            guard let self, !self.shuttingDown else { return }
            self.pendingCommands -= 1
            self.isBusy = self.pendingCommands > 0
            if !self.isBusy { self.apply(value) }
        }
    }

    private func apply(_ value: InteractionSnapshot) {
        snapshot = value
        disarmNotifier.observe(privacyIndicator, status: value.privacy.status)
        if value.privacy.isShielded {
            overlay?.show(status: value.privacy.status)
        } else {
            overlay?.hide()
        }
        coveredDisplays = overlay?.coveredScreenCount ?? 0
    }

    func shutdown() async {
        shuttingDown = true
        polling?.cancel()
        polling = nil
        overlay?.shutdown()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        await command?.value
        await session.shutdown()
    }

    deinit { polling?.cancel(); command?.cancel() }
}
