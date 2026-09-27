import ActivityKit
import Foundation

/// Live Activity for the Lock Screen and Dynamic Island: one activity for all downloads.
nonisolated struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case downloading
            /// The app left the screen; iOS stops downloads until it comes back.
            case paused
            case finished
        }

        /// A torrent's name, or "3 downloads".
        var title: String
        /// 0...1 over everything downloading.
        var progress: Double
        var downloadRate: Int64
        /// Seconds, or -1 when unknown.
        var eta: Double
        var activeCount: Int
        var phase: Phase
    }
}

nonisolated extension DownloadActivityAttributes.ContentState {
    var percentText: String {
        progress.formatted(.percent.precision(.fractionLength(0)))
    }

    var rateText: String {
        "\(downloadRate.formatted(.byteCount(style: .file, spellsOutZero: false)))/s"
    }

    var etaText: String? {
        guard eta >= 0, eta.isFinite else { return nil }
        return Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}
