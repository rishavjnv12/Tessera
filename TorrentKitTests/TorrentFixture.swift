import CryptoKit
import Foundation

/// Minimal bencode encoder, enough to build .torrent files in tests.
enum Bencode {
    case int(Int)
    case bytes(Data)
    case list([Bencode])
    case dict([String: Bencode])

    static func string(_ s: String) -> Bencode { .bytes(Data(s.utf8)) }

    var encoded: Data {
        switch self {
        case .int(let v):
            return Data("i\(v)e".utf8)
        case .bytes(let d):
            return Data("\(d.count):".utf8) + d
        case .list(let items):
            return Data("l".utf8) + items.reduce(Data()) { $0 + $1.encoded } + Data("e".utf8)
        case .dict(let dict):
            // Keys must be sorted by raw bytes.
            let body = dict.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
                .reduce(Data()) { $0 + Bencode.string($1).encoded + dict[$1]!.encoded }
            return Data("d".utf8) + body + Data("e".utf8)
        }
    }
}

/// A torrent built from generated files on disk.
struct TorrentFixture {
    struct File {
        var path: String // relative to the torrent root, "/"-separated
        var size: Int
    }

    let name: String
    let files: [File]
    let pieceLength: Int
    /// Folder that contains the torrent's root (pass as the seeder's save path).
    let directory: URL
    let torrentData: Data

    var totalSize: Int { files.reduce(0) { $0 + $1.size } }
    var numPieces: Int { (totalSize + pieceLength - 1) / pieceLength }

    /// Location of a file inside `directory` (multi-file torrents nest under `name`).
    func url(of file: File, in folder: URL? = nil) -> URL {
        (folder ?? directory).appending(path: name).appending(path: file.path)
    }

    /// Writes deterministic pseudo-random contents and builds a multi-file v1 torrent.
    static func make(name: String, files: [File], pieceLength: Int = 16 * 1024, in directory: URL) throws -> TorrentFixture {
        var stream = Data()
        for (index, file) in files.enumerated() {
            let bytes = pseudoRandomBytes(count: file.size, seed: UInt64(index + 1))
            let url = directory.appending(path: name).appending(path: file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            stream.append(bytes)
        }

        var pieces = Data()
        var offset = 0
        while offset < stream.count {
            let end = min(offset + pieceLength, stream.count)
            pieces.append(contentsOf: Insecure.SHA1.hash(data: stream[offset..<end]))
            offset = end
        }

        let info: Bencode = .dict([
            "name": .string(name),
            "piece length": .int(pieceLength),
            "pieces": .bytes(pieces),
            "files": .list(files.map { file in
                .dict([
                    "length": .int(file.size),
                    "path": .list(file.path.split(separator: "/").map { .string(String($0)) }),
                ])
            }),
        ])
        let torrent = Bencode.dict([
            "info": info,
            "created by": .string("TorrentKitTests"),
            "comment": .string("Made for tests"),
            "creation date": .int(1_790_000_000),
        ]).encoded
        return TorrentFixture(name: name, files: files, pieceLength: pieceLength, directory: directory, torrentData: torrent)
    }

    private static func pseudoRandomBytes(count: Int, seed: UInt64) -> Data {
        var state = seed &* 0x9E37_79B9_7F4A_7C15
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for i in 0..<count {
                // xorshift64*
                state ^= state >> 12
                state ^= state << 25
                state ^= state >> 27
                buffer[i] = UInt8(truncatingIfNeeded: (state &* 0x2545_F491_4F6C_DD1D) >> 56)
            }
        }
        return data
    }
}
