import ActivityKit
import SwiftUI
import WidgetKit

struct NavigationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavigationActivityAttributes.self) { context in
            lockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.isPaused ? "已暫停" : "前往")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(context.state.destinationName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.remainingTimeText)
                            .font(.title3.bold())
                            .minimumScaleFactor(0.7)
                        Text(context.state.etaText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Image(systemName: context.state.modeSymbolName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color(red: 0.07, green: 0.42, blue: 0.26))
                        Text(context.state.remainingDistanceText)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("抵達 \(context.state.etaText)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : context.state.modeSymbolName)
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color(red: 0.07, green: 0.42, blue: 0.26))
            } compactTrailing: {
                Text(compactTime(from: context.state.remainingTimeText))
                    .font(.caption.weight(.bold))
                    .minimumScaleFactor(0.7)
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : context.state.modeSymbolName)
                    .foregroundStyle(Color(red: 0.07, green: 0.42, blue: 0.26))
            }
            .widgetURL(URL(string: "pikgo://navigation"))
        }
    }

    private func lockScreenView(state: NavigationActivityAttributes.ContentState) -> some View {
        HStack(spacing: 14) {
            Image(systemName: state.isPaused ? "pause.circle.fill" : state.modeSymbolName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.isPaused ? "已暫停" : "前往 \(state.destinationName)")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(state.remainingDistanceText)  ·  \(state.etaText)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(state.remainingTimeText)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .activityBackgroundTint(Color(red: 0.07, green: 0.42, blue: 0.26))
        .activitySystemActionForegroundColor(.white)
    }

    private func compactTime(from text: String) -> String {
        if text == "已抵達" {
            return "抵達"
        }
        return text
            .replacingOccurrences(of: "小時 ", with: "時")
            .replacingOccurrences(of: "小時", with: "時")
            .replacingOccurrences(of: "分鐘", with: "分")
    }
}
