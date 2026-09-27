import SwiftUI
import TorrentKit
import UIKit

@main
struct TorrentiOSApp: App {
    @State private var store = TorrentStore()
    @State private var liveActivity = LiveActivityController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            IOSContentView(store: store)
                .onOpenURL { store.open([$0]) } // .torrent files from Files, magnet links from Safari
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    store.importInbox()
                    while !Task.isCancelled {
                        liveActivity.refresh(store)
                        UIApplication.shared.isIdleTimerDisabled = store.settings.keepScreenAwake && store.count(.downloading) > 0
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            // iOS suspends the app shortly; save progress and show the downloads as paused first.
            let task = UIApplication.shared.beginBackgroundTask(withName: "Save progress")
            store.saveResumeData()
            liveActivity.markPaused()
            UIApplication.shared.isIdleTimerDisabled = false
            Task {
                try? await Task.sleep(for: .seconds(2))
                UIApplication.shared.endBackgroundTask(task)
            }
        }
    }
}

extension TorrentStore {
    /// Adds what the share extension left in the App Group inbox.
    func importInbox() {
        for item in Inbox.drain() {
            switch item {
            case .torrent(let data, let name): open(torrentData: data, name: name)
            case .magnet(let link): open(magnet: link)
            }
        }
    }
}
