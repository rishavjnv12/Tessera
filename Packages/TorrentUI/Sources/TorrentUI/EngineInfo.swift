import Foundation

/// Plain description of the torrent engine, so views never depend on TorrentKit directly.
public struct EngineInfo: Sendable, Equatable {
    public enum SelfTest: Sendable, Equatable {
        case running
        case passed
        case failed(String)
    }

    public var libtorrentVersion: String
    public var opensslVersion: String
    public var boostVersion: String
    public var selfTest: SelfTest

    public init(libtorrentVersion: String, opensslVersion: String, boostVersion: String, selfTest: SelfTest) {
        self.libtorrentVersion = libtorrentVersion
        self.opensslVersion = opensslVersion
        self.boostVersion = boostVersion
        self.selfTest = selfTest
    }

    public static let preview = EngineInfo(
        libtorrentVersion: "2.1.2", opensslVersion: "3.5.8", boostVersion: "1.92", selfTest: .passed
    )
}
