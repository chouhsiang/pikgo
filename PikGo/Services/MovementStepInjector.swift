import Foundation

@MainActor
final class MovementStepInjector {
    static let shared = MovementStepInjector()

    private let healthKit = HealthKitManager.shared
    private var timer: Timer?
    private var remainder = 0.0
    private var isMoving = false

    private init() {}

    func setMoving(_ moving: Bool) {
        isMoving = moving
        sync()
    }

    func configurationDidChange() {
        sync()
    }

    private func sync() {
        let shouldRun = isMoving && RouteMovingSteps.isEnabled
        if shouldRun {
            startTimerIfNeeded()
        } else {
            stopTimer()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        remainder = 0
        Task {
            guard healthKit.isHealthDataAvailable else { return }
            try? await healthKit.requestAuthorization()
        }
        let timer = Timer(timeInterval: RouteMovingSteps.writeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.writeIntervalSteps()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        remainder = 0
    }

    private func writeIntervalSteps() {
        guard isMoving, RouteMovingSteps.isEnabled else {
            stopTimer()
            return
        }
        let interval = RouteMovingSteps.writeInterval
        remainder += RouteMovingSteps.stepsPerMinute * interval / 60
        let steps = Int(remainder)
        guard steps > 0 else { return }
        remainder -= Double(steps)
        let end = Date()
        let start = end.addingTimeInterval(-interval)
        Task {
            await healthKit.addStepsQuietly(steps, start: start, end: end)
        }
    }
}
