import SwiftUI

@main
struct TorrentiOSApp: App {
    @State private var store = TorrentStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            IOSContentView(store: store)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the app soon after it leaves the screen; save progress first.
            if phase == .background { store.saveResumeData() }
        }
    }
}
