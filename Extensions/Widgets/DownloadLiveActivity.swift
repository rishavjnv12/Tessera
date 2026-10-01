import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TesseraWidgets: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(16)
                .activitySystemActionForegroundColor(.accentColor)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ProgressRing(progress: state.progress, phase: state.phase)
                        .frame(width: 36, height: 36)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.percentText)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressView(value: state.progress)
                            .tint(state.phase == .paused ? .secondary : .accentColor)
                        DetailLine(state: state)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                ProgressRing(progress: state.progress, phase: state.phase)
                    .frame(width: 18, height: 18)
            } compactTrailing: {
                Text(state.percentText)
                    .monospacedDigit()
                    .foregroundStyle(state.phase == .paused ? .secondary : Color.accentColor)
            } minimal: {
                ProgressRing(progress: state.progress, phase: state.phase)
                    .frame(width: 18, height: 18)
            }
        }
    }
}

private struct LockScreenView: View {
    var state: DownloadActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ProgressRing(progress: state.progress, phase: state.phase)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(state.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(state.percentText).font(.headline).monospacedDigit()
                }
                ProgressView(value: state.progress)
                    .tint(state.phase == .paused ? .secondary : .accentColor)
                DetailLine(state: state)
            }
        }
    }
}

private struct DetailLine: View {
    var state: DownloadActivityAttributes.ContentState

    var body: some View {
        HStack {
            switch state.phase {
            case .downloading:
                Label(state.rateText, systemImage: "arrow.down")
                Spacer()
                if let eta = state.etaText { Text("\(eta) left") }
            case .paused:
                Label("Paused. Open Tessera to continue.", systemImage: "pause.fill")
                Spacer()
            case .finished:
                Label("Finished", systemImage: "checkmark.circle.fill")
                Spacer()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }
}

private struct ProgressRing: View {
    var progress: Double
    var phase: DownloadActivityAttributes.ContentState.Phase

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(phase == .paused ? Color.secondary : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: phase == .finished ? "checkmark" : phase == .paused ? "pause.fill" : "arrow.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(phase == .paused ? Color.secondary : Color.accentColor)
        }
    }
}
