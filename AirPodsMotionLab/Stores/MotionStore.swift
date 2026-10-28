import Foundation
import Observation
import MotionCore
import MotionRuntime

struct AttitudeChartPoint: Identifiable {
    let id: Int
    let timestamp: TimeInterval
    let axis: String
    let degrees: Double
    let segment: Int

    var series: String { "\(axis)-\(segment)" }
}

/// Main-actor presentation state is refreshed at 10 Hz, independently of the
/// sensor stream and its consumers. Pausing only freezes displayed samples.
@MainActor
@Observable
final class MotionStore {
    private(set) var snapshot = SessionSnapshot()
    private(set) var displayedMotion: ProcessedMotion?
    private(set) var displayedSmoothingEnabled = true
    private(set) var chartPoints: [AttitudeChartPoint] = []
    private(set) var isDisplayPaused = false
    private(set) var isBusy = false
    private(set) var localMessage: String?
    private(set) var refreshedUptime = ProcessInfo.processInfo.systemUptime

    @ObservationIgnored let session: MotionSession
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var lastPlottedMotion: ProcessedMotion?
    @ObservationIgnored private var chartSequence = 0
    @ObservationIgnored private var chartSegments = ["Yaw": 0, "Pitch": 0, "Roll": 0]
    @ObservationIgnored private var activated = false
    @ObservationIgnored private var clearChartOnResume = false

    init(session: MotionSession = MotionSession()) { self.session = session }

    deinit {
        pollingTask?.cancel()
    }

    var canStart: Bool { !snapshot.isRequested && !isBusy }
    var canStop: Bool { snapshot.isRequested && !isBusy }
    var canCalibrate: Bool {
        snapshot.phase == .streaming && snapshot.latest != nil && !isBusy
    }

    func activate() {
        guard !activated else { return }
        activated = true
        let session = session
        pollingTask = Task { [weak self, session] in
            while !Task.isCancelled {
                let value = await session.snapshot()
                guard !Task.isCancelled else { break }
                self?.receive(value)
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { break }
            }
        }
    }

    func selectSource(_ source: MotionSourceKind) {
        guard !snapshot.isRequested, !isBusy, source != snapshot.source else { return }
        isBusy = true
        Task { [weak self, session] in
            await session.setSource(source)
            let value = await session.snapshot()
            self?.clearDisplay()
            self?.receive(value)
            self?.isBusy = false
        }
    }

    func start() {
        guard canStart else { return }
        isBusy = true
        localMessage = nil
        clearDisplay()
        Task { [weak self, session] in
            await session.start()
            let value = await session.snapshot()
            self?.receive(value)
            self?.isBusy = false
        }
    }

    func stop() {
        guard canStop else { return }
        isBusy = true
        Task { [weak self, session] in
            await session.stop()
            let value = await session.snapshot()
            self?.receive(value)
            self?.isBusy = false
        }
    }

    func toggleDisplayPause() {
        isDisplayPaused.toggle()
        if !isDisplayPaused {
            if clearChartOnResume {
                clearChart()
                clearChartOnResume = false
            } else {
                breakChartSegments()
            }
            updateDisplay(snapshot.latest)
        }
    }

    func calibrate() {
        guard canCalibrate else { return }
        isBusy = true
        Task { [weak self, session] in
            let succeeded = await session.calibrate()
            self?.localMessage = succeeded ? "已將最新採集姿態設為參考。" : "當前沒有可用於校準的新鮮數據。"
            if succeeded { self?.didCalibrate() }
            let value = await session.snapshot()
            self?.receive(value)
            self?.isBusy = false
        }
    }

    func setSmoothing(_ enabled: Bool) {
        Task { [weak self, session] in
            await session.setSmoothing(enabled: enabled)
            self?.breakChartSegments()
            let value = await session.snapshot()
            self?.receive(value)
        }
    }

    func shutdown() async {
        pollingTask?.cancel()
        pollingTask = nil
        await session.shutdown()
    }

    private func receive(_ value: SessionSnapshot) {
        if snapshot.phase == .streaming, value.phase != .streaming {
            breakChartSegments()
        }
        snapshot = value
        refreshedUptime = ProcessInfo.processInfo.systemUptime
        if !isDisplayPaused { updateDisplay(value.latest) }
    }

    private func updateDisplay(_ motion: ProcessedMotion?) {
        // Keep a historical/frozen frame's processing label. Changing settings
        // cannot retroactively change the filter used for an existing sample.
        if let motion, motion.raw.timestamp != displayedMotion?.raw.timestamp {
            displayedSmoothingEnabled = motion.smoothingEnabled
        }
        displayedMotion = motion
        guard snapshot.phase == .streaming, let motion,
              motion.raw.timestamp != lastPlottedMotion?.raw.timestamp else { return }
        if let previous = lastPlottedMotion {
            let gap = motion.raw.timestamp - previous.raw.timestamp
            if gap > 0.5 || gap <= 0 || motion.isCalibrated != previous.isCalibrated {
                breakChartSegments()
            }
        }
        let values = [("Yaw", motion.displayAngles.yaw), ("Pitch", motion.displayAngles.pitch), ("Roll", motion.displayAngles.roll)]
        for (axis, radians) in values {
            let degrees = radians * 180 / .pi
            if let previous = chartPoints.last(where: { $0.axis == axis }),
               abs(previous.degrees - degrees) > 180 {
                chartSegments[axis, default: 0] += 1
            }
            chartSequence += 1
            chartPoints.append(AttitudeChartPoint(
                id: chartSequence, timestamp: motion.raw.timestamp, axis: axis,
                degrees: degrees, segment: chartSegments[axis, default: 0]
            ))
        }
        chartPoints.removeAll { $0.timestamp < motion.raw.timestamp - 10 }
        if chartPoints.count > 330 { chartPoints.removeFirst(chartPoints.count - 330) }
        lastPlottedMotion = motion
    }

    private func breakChartSegments() {
        for axis in ["Yaw", "Pitch", "Roll"] { chartSegments[axis, default: 0] += 1 }
    }

    private func clearChart() {
        chartPoints.removeAll(keepingCapacity: true)
        lastPlottedMotion = nil
        breakChartSegments()
    }

    private func didCalibrate() {
        if isDisplayPaused {
            clearChartOnResume = true
        } else {
            clearChart()
        }
    }

    private func clearDisplay() {
        displayedMotion = nil
        isDisplayPaused = false
        clearChartOnResume = false
        localMessage = nil
        clearChart()
    }
}
