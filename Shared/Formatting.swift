import Foundation
import TorrentKit

enum Format {
    static func bytes(_ n: Int64) -> String {
        n.formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    static func rate(_ n: Int64) -> String {
        "\(bytes(n))/s"
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(value > 0 && value < 0.1 ? 1 : 0)))
    }

    /// nil when the ETA is unknown.
    static func eta(_ seconds: TimeInterval) -> String? {
        guard seconds >= 0, seconds.isFinite else { return nil }
        return Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    static func state(_ t: TorrentStatus) -> String {
        if let error = t.errorMessage { return String(localized: "Error: \(error)") }
        if t.isPaused { return String(localized: "Paused") }
        if t.isQueued { return String(localized: "Queued") }
        return switch t.state {
        case .checkingResumeData: String(localized: "Resuming")
        case .checkingFiles: String(localized: "Checking files")
        case .downloadingMetadata: String(localized: "Getting details")
        case .downloading: String(localized: "Downloading")
        case .finished: String(localized: "Finished")
        case .seeding: String(localized: "Seeding")
        @unknown default: String(localized: "Unknown")
        }
    }
}
