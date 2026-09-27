import ActivityKit
import Foundation
import OSLog
import TorrentKit

/// Keeps one Live Activity in step with the downloads: started when something downloads while
/// the app is open, marked paused when the app leaves the screen, ended when everything is done.
@MainActor
final class LiveActivityController {
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastState: DownloadActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast
    private let logger = Logger(subsystem: "io.github.rishavjnv12.Torrent", category: "live-activity")

    init() {
        // Activities left over from a previous run show stale numbers; end them.
        for old in Activity<DownloadActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Call about once per second while the app is active.
    func refresh(_ store: TorrentStore) {
        let downloading = store.torrents.filter { TorrentFilter.downloading.includes($0) && $0.hasMetadata }
        guard !downloading.isEmpty else {
            if let activity, let last = lastState {
                var done = last
                done.phase = .finished
                done.progress = 1
                done.downloadRate = 0
                done.eta = -1
                Task { await activity.end(.init(state: done, staleDate: nil), dismissalPolicy: .after(.now + 15 * 60)) }
                self.activity = nil
                lastState = nil
            }
            return
        }
        let wanted = downloading.reduce(Int64(0)) { $0 + $1.totalWanted }
        let done = downloading.reduce(Int64(0)) { $0 + $1.totalWantedDone }
        let rate = downloading.reduce(Int64(0)) { $0 + $1.downloadRate }
        let state = DownloadActivityAttributes.ContentState(
            title: downloading.count == 1 ? downloading[0].name : String(localized: "\(downloading.count) downloads"),
            progress: wanted > 0 ? Double(done) / Double(wanted) : 0,
            downloadRate: rate,
            eta: rate > 0 ? Double(wanted - done) / Double(rate) : -1,
            activeCount: downloading.count,
            phase: .downloading
        )
        if let activity {
            // Updates are rationed by iOS; send at most one every few seconds.
            guard Date().timeIntervalSince(lastUpdate) >= 3, state != lastState else { return }
            lastState = state
            lastUpdate = Date()
            Task { await activity.update(.init(state: state, staleDate: .now + 60)) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(attributes: DownloadActivityAttributes(),
                                                content: .init(state: state, staleDate: .now + 60))
                lastState = state
                lastUpdate = Date()
            } catch {
                logger.error("Live Activity not started: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The app is leaving the screen: iOS will suspend it, so show the downloads as paused.
    func markPaused() {
        guard let activity, var state = lastState else { return }
        state.phase = .paused
        state.downloadRate = 0
        state.eta = -1
        lastState = state
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }
}
