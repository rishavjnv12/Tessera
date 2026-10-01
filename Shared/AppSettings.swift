import Foundation
import TorrentKit

/// User settings, saved in UserDefaults and applied to the engine as they change.
struct AppSettings: Codable, Equatable {
    /// nil uses the default folder (~/Torrent on Mac, the app's Documents folder on iPhone).
    var downloadFolderPath: String?

    /// 0 picks a random port at launch.
    var listenPort = 0
    /// Kilobytes per second. 0 means unlimited.
    var downloadLimitKB = 0
    var uploadLimitKB = 0
    var activeDownloads = 3
    var activeSeeds = 5

    var enableDHT = true
    var enableLocalDiscovery = true
    var enablePeerExchange = true
    var enablePortForwarding = true

    /// Show the add sheet (folder and files) instead of adding right away.
    var askBeforeAdding = true
    var notifyWhenFinished = true
    var showInMenuBar = true
    /// iPhone: stop the screen from locking while something downloads (iOS pauses apps that leave the screen).
    var keepScreenAwake = false
    /// Mac: let paired iPhones and iPads control this Mac over the local network.
    var allowRemoteControl = true

    static let defaultsKey = "settings"
    /// Mirrored into its own UserDefaults key for the menu bar scene (see TorrentMacApp).
    static let menuBarKey = "showInMenuBar"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        if UserDefaults.standard.object(forKey: Self.menuBarKey) as? Bool != showInMenuBar {
            UserDefaults.standard.set(showInMenuBar, forKey: Self.menuBarKey)
        }
    }

    /// Unknown keys keep their defaults, so older saved settings still load.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        downloadFolderPath = try c.decodeIfPresent(String.self, forKey: .downloadFolderPath)
        listenPort = try c.decodeIfPresent(Int.self, forKey: .listenPort) ?? d.listenPort
        downloadLimitKB = try c.decodeIfPresent(Int.self, forKey: .downloadLimitKB) ?? d.downloadLimitKB
        uploadLimitKB = try c.decodeIfPresent(Int.self, forKey: .uploadLimitKB) ?? d.uploadLimitKB
        activeDownloads = try c.decodeIfPresent(Int.self, forKey: .activeDownloads) ?? d.activeDownloads
        activeSeeds = try c.decodeIfPresent(Int.self, forKey: .activeSeeds) ?? d.activeSeeds
        enableDHT = try c.decodeIfPresent(Bool.self, forKey: .enableDHT) ?? d.enableDHT
        enableLocalDiscovery = try c.decodeIfPresent(Bool.self, forKey: .enableLocalDiscovery) ?? d.enableLocalDiscovery
        enablePeerExchange = try c.decodeIfPresent(Bool.self, forKey: .enablePeerExchange) ?? d.enablePeerExchange
        enablePortForwarding = try c.decodeIfPresent(Bool.self, forKey: .enablePortForwarding) ?? d.enablePortForwarding
        askBeforeAdding = try c.decodeIfPresent(Bool.self, forKey: .askBeforeAdding) ?? d.askBeforeAdding
        notifyWhenFinished = try c.decodeIfPresent(Bool.self, forKey: .notifyWhenFinished) ?? d.notifyWhenFinished
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? d.showInMenuBar
        keepScreenAwake = try c.decodeIfPresent(Bool.self, forKey: .keepScreenAwake) ?? d.keepScreenAwake
        allowRemoteControl = try c.decodeIfPresent(Bool.self, forKey: .allowRemoteControl) ?? d.allowRemoteControl
    }

    var sessionSettings: SessionSettings {
        let s = SessionSettings()
        s.listenPort = listenPort
        s.downloadRateLimit = Int64(max(0, downloadLimitKB)) * 1000
        s.uploadRateLimit = Int64(max(0, uploadLimitKB)) * 1000
        s.activeDownloads = activeDownloads
        s.activeSeeds = activeSeeds
        s.enableDHT = enableDHT
        s.enablePEX = enablePeerExchange
        s.enableUPnP = enablePortForwarding
        s.enableNATPMP = enablePortForwarding
        #if os(iOS)
        s.enableLSD = false // needs a multicast entitlement on iOS
        #else
        s.enableLSD = enableLocalDiscovery
        #endif
        return s
    }
}
