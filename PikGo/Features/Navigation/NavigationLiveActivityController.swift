import ActivityKit
import Foundation

@MainActor
final class NavigationLiveActivityController {
    static let shared = NavigationLiveActivityController()

    private var activity: Activity<NavigationActivityAttributes>?
    private var lastPublishedState: NavigationActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast

    private init() {}

    func start(state: NavigationActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let activity {
            Task { await publish(state, on: activity, force: true) }
            return
        }

        let attributes = NavigationActivityAttributes(destinationName: state.destinationName)
        let content = ActivityContent(state: state, staleDate: nil)
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            lastPublishedState = state
            lastUpdate = Date()
        } catch {
            activity = nil
        }
    }

    func update(state: NavigationActivityAttributes.ContentState, force: Bool = false) {
        guard let activity else {
            start(state: state)
            return
        }
        Task { await publish(state, on: activity, force: force) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastPublishedState = nil
        lastUpdate = .distantPast
        let finalState = activity.content.state
        Task {
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }

    private func publish(
        _ state: NavigationActivityAttributes.ContentState,
        on activity: Activity<NavigationActivityAttributes>,
        force: Bool
    ) async {
        let minimumInterval: TimeInterval = AppRuntimeState.shared.isActive ? 6 : 12
        if !force,
           Date().timeIntervalSince(lastUpdate) < minimumInterval,
           lastPublishedState == state {
            return
        }
        if !force,
           Date().timeIntervalSince(lastUpdate) < minimumInterval,
           lastPublishedState?.remainingTimeText == state.remainingTimeText,
           lastPublishedState?.remainingDistanceText == state.remainingDistanceText,
           lastPublishedState?.isPaused == state.isPaused {
            return
        }

        await activity.update(ActivityContent(state: state, staleDate: nil))
        lastPublishedState = state
        lastUpdate = Date()
    }
}
