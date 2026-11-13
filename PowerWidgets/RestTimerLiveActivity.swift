import ActivityKit
import WidgetKit
import SwiftUI

/// Rest countdown on the Lock Screen and in the Dynamic Island. The countdown text and
/// progress run on the system clock, so they stay accurate without the app updating them.
/// Once rest is over the activity goes stale and shows a "next set" prompt.
struct RestTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestTimerAttributes.self) { context in
            LockScreenView(state: context.state, isOver: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let isOver = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Rest", systemImage: "timer")
                        .font(.headline)
                        .foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(state: state, isOver: isOver)
                        .font(.title2.bold())
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !state.exerciseName.isEmpty {
                            Text("Next: \(state.exerciseName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        CountdownBar(state: state, isOver: isOver)
                    }
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                CountdownText(state: state, isOver: isOver)
                    .frame(maxWidth: 48)
            } minimal: {
                if isOver {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                } else {
                    let start = state.endDate.addingTimeInterval(-TimeInterval(state.totalSeconds))
                    ProgressView(timerInterval: start...max(start, state.endDate), countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        Image(systemName: "timer")
                    }
                    .progressViewStyle(.circular)
                    .tint(.orange)
                }
            }
            .keylineTint(.orange)
        }
    }
}

private struct LockScreenView: View {
    let state: RestTimerAttributes.ContentState
    let isOver: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(isOver ? "Rest is over" : "Resting", systemImage: isOver ? "checkmark.circle.fill" : "timer")
                    .font(.headline)
                    .foregroundStyle(isOver ? .green : .orange)
                Spacer()
                CountdownText(state: state, isOver: isOver)
                    .font(.system(size: 34, weight: .bold))
            }
            if !state.exerciseName.isEmpty {
                Text(isOver ? "Time for your next set of \(state.exerciseName)" : "Next: \(state.exerciseName)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            CountdownBar(state: state, isOver: isOver)
        }
        .padding()
        .foregroundStyle(.white)
    }
}

private struct CountdownText: View {
    let state: RestTimerAttributes.ContentState
    let isOver: Bool

    var body: some View {
        if isOver {
            Text("Go!")
                .foregroundStyle(.green)
        } else {
            Text(timerInterval: Date.now...max(Date.now, state.endDate), countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct CountdownBar: View {
    let state: RestTimerAttributes.ContentState
    let isOver: Bool

    var body: some View {
        let start = state.endDate.addingTimeInterval(-TimeInterval(state.totalSeconds))
        if isOver {
            ProgressView(value: 0)
                .tint(.green)
        } else {
            ProgressView(timerInterval: start...max(start, state.endDate), countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(.orange)
        }
    }
}
