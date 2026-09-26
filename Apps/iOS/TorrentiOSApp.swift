import SwiftUI
import TorrentUI

@main
struct TorrentiOSApp: App {
    @State private var engine = EngineModel()

    var body: some Scene {
        WindowGroup {
            EngineStatusView(info: engine.info)
                .task { await engine.runSelfTest() }
        }
    }
}
