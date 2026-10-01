import AppKit
import SwiftUI
import TesseraKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = TorrentStore()
    private var dock: DockProgress?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        store.onFinished = { [weak self] event in self?.notifyFinished(event) }
        dock = DockProgress(store: store)
    }

    /// .torrent files opened from Finder and magnet links clicked in a browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        store.open(urls)
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown() // saves progress for every torrent
    }

    // MARK: Notifications

    private func notifyFinished(_ event: TorrentEvent) {
        guard store.settings.notifyWhenFinished, let id = event.torrentID else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Download Finished")
        content.body = event.torrentName ?? ""
        content.sound = .default
        content.userInfo = ["torrentID": id]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { center.add(request) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["torrentID"] as? String
        await MainActor.run {
            store.selectionRequest = id
            NSApp.activate()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@main
struct TesseraMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage(AppSettings.menuBarKey) private var showInMenuBar = true

    var body: some Scene {
        Window("Tessera", id: "main") {
            MainWindow(store: delegate.store)
        }
        .defaultSize(width: 1180, height: 720)
        .commands { TorrentCommands() }

        Settings {
            SettingsView(store: delegate.store)
        }

        // Bound to plain UserDefaults, not the observable store: reading the store here made the
        // scene graph update itself in a loop (100% CPU, unresponsive at launch).
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarContent(store: delegate.store)
        } label: {
            Image(systemName: "arrow.down.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
