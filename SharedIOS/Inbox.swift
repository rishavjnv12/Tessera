import Foundation

/// Hand-off folder in the App Group. The share extension drops torrents and magnet links here;
/// the app adds them the next time it becomes active. (A share extension cannot open its app.)
enum Inbox {
    static let groupID = "group.io.github.rishavjnv12.Torrent"

    enum Item {
        case torrent(data: Data, name: String)
        case magnet(String)
    }

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    static func add(_ item: Item) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        switch item {
        case .torrent(let data, let name):
            let safe = name.replacingOccurrences(of: "/", with: "-")
            try data.write(to: folder.appending(path: "\(stamp)__\(safe)"), options: .atomic)
        case .magnet(let link):
            try Data(link.utf8).write(to: folder.appending(path: "\(stamp).magnet"), options: .atomic)
        }
    }

    /// Returns everything waiting, oldest first, and empties the folder.
    static func drain() -> [Item] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var items: [Item] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url) else { continue }
            if url.pathExtension == "magnet" {
                if let link = String(data: data, encoding: .utf8) { items.append(.magnet(link)) }
            } else {
                let name = url.lastPathComponent.components(separatedBy: "__").dropFirst().joined(separator: "__")
                items.append(.torrent(data: data, name: name.isEmpty ? url.lastPathComponent : name))
            }
        }
        return items
    }

    /// Display name from a magnet link's "dn" parameter.
    static func name(ofMagnet link: String) -> String? {
        URLComponents(string: link)?.queryItems?.first { $0.name == "dn" }?.value
    }
}
