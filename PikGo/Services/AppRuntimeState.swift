import UIKit

final class AppRuntimeState {
    static let shared = AppRuntimeState()

    private(set) var isActive = true

    private init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(leftForeground), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(leftForeground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func becameActive() {
        guard !isActive else { return }
        isActive = true
        NotificationCenter.default.post(name: .appRuntimeStateDidChange, object: nil)
    }

    @objc private func leftForeground() {
        guard isActive else { return }
        isActive = false
        NotificationCenter.default.post(name: .appRuntimeStateDidChange, object: nil)
    }
}
