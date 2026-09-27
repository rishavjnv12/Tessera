import Foundation
import OSLog

/// Where downloads go, and (on Mac) keeping access to folders outside the sandbox.
enum DownloadFolders {
    /// ~/Torrent on Mac, Documents/Torrent on iPhone. Created if missing.
    static var defaultFolder: URL {
        #if os(macOS)
        // Inside the sandbox, the home directory APIs return the app's container. The real home
        // comes from the user database; the entitlement allows ~/Torrent/.
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let folder = URL(filePath: home, directoryHint: .isDirectory).appending(path: "Torrent", directoryHint: .isDirectory)
        #else
        let folder = URL.documentsDirectory.appending(path: "Torrent", directoryHint: .isDirectory)
        #endif
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func folder(for settings: AppSettings) -> URL {
        if let path = settings.downloadFolderPath, FileManager.default.fileExists(atPath: path) {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return defaultFolder
    }
}

#if os(macOS)
/// Remembers folders the user picked (Settings, add sheet) as security-scoped bookmarks, and
/// reopens them at launch so torrents saved there keep working after a relaunch.
enum FolderAccess {
    private static let key = "folderBookmarks"
    private static let logger = Logger(subsystem: "io.github.rishavjnv12.Torrent", category: "folders")

    /// Call once at launch, before the engine starts.
    static func restoreAll() {
        var bookmarks = stored
        for (path, data) in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) else {
                logger.error("Lost access to \(path, privacy: .public)")
                bookmarks[path] = nil
                continue
            }
            if url.startAccessingSecurityScopedResource(), stale,
               let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                bookmarks[path] = fresh
            }
        }
        stored = bookmarks
    }

    /// Keeps access to a folder the user just picked. Access stays open for the app's lifetime.
    static func remember(_ url: URL) {
        let url = url.resolvingSymlinksInPath()
        guard url.path != DownloadFolders.defaultFolder.path,
              let data = try? url.bookmarkData(options: .withSecurityScope) else { return }
        _ = url.startAccessingSecurityScopedResource()
        stored[url.path] = data
    }

    private static var stored: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
#endif
