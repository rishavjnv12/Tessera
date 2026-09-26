import SwiftUI
import TorrentUI

@main
struct TorrentMacApp: App {
    @State private var engine = EngineModel()

    var body: some Scene {
        WindowGroup {
            EngineStatusView(info: engine.info)
                .frame(minWidth: 480, minHeight: 420)
                .task { await engine.runSelfTest() }
        }
        .windowResizability(.contentMinSize)
    }
}
