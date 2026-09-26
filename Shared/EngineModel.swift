import Foundation
import Observation
import OSLog
import TorrentKit
import TorrentUI

/// Bridges TorrentKit build info into the UI and logs it at launch.
@Observable
final class EngineModel {
    private(set) var info = EngineInfo(
        libtorrentVersion: BuildInfo.libtorrentVersion,
        opensslVersion: BuildInfo.opensslVersion,
        boostVersion: BuildInfo.boostVersion,
        selfTest: .running
    )

    private let logger = Logger(subsystem: "io.github.rishavjnv12.Torrent", category: "engine")

    func runSelfTest() async {
        let line = "libtorrent \(info.libtorrentVersion), OpenSSL \(info.opensslVersion), Boost \(info.boostVersion)"
        logger.notice("\(line, privacy: .public)")
        print("[TorrentKit] \(line)")

        let failure = await Task.detached(priority: .userInitiated) { BuildInfo.runSelfTest() }.value
        if let failure {
            info.selfTest = .failed(failure)
            logger.error("Self-test failed: \(failure, privacy: .public)")
            print("[TorrentKit] self-test FAILED: \(failure)")
        } else {
            info.selfTest = .passed
            logger.notice("Self-test passed")
            print("[TorrentKit] self-test passed")
        }
    }
}
