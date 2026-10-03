import ActivityKit
import Foundation

struct NavigationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var destinationName: String
        var remainingTimeText: String
        var remainingDistanceText: String
        var etaText: String
        var modeSymbolName: String
        var isPaused: Bool
    }

    var destinationName: String
}
