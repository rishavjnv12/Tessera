import Foundation
import Observation

/// Fakes a download so the piece map can be previewed and profiled without a network.
@Observable
@MainActor
public final class PieceMapSimulator {
    public private(set) var map: PieceMap
    private var generator = SplitMix64(seed: 42)

    public init(pieceCount: Int = 25_000, pieceLength: Int = 256 * 1024, fileCount: Int = 12) {
        var files: [PieceMap.File] = []
        let per = max(1, pieceCount / fileCount)
        for i in 0..<fileCount {
            let first = i * per
            let last = i == fileCount - 1 ? pieceCount - 1 : min(pieceCount - 1, first + per - 1)
            guard first <= last else { break }
            files.append(.init(id: i, path: "Demo/Part \(i + 1).mkv", size: Int64(last - first + 1) * Int64(pieceLength), pieces: first...last))
        }
        var fill = [UInt8](repeating: PieceMap.missing, count: pieceCount)
        var priority = [UInt8](repeating: 4, count: pieceCount)
        var availability = [UInt16](repeating: 0, count: pieceCount)
        var rng = SplitMix64(seed: 7)
        for i in 0..<pieceCount {
            if rng.next() % 100 < 22 { fill[i] = PieceMap.have }
            availability[i] = Self.availability(at: i, count: pieceCount, rng: &rng)
        }
        if let skipped = files.last?.pieces { for i in skipped { priority[i] = 0; fill[i] = PieceMap.missing } }
        if let high = files.first?.pieces { for i in high.prefix(400) { priority[i] = 7 } }
        map = PieceMap(
            pieceLength: pieceLength, totalSize: Int64(pieceCount) * Int64(pieceLength),
            fill: fill, priority: priority, availability: availability, tracksAvailability: true, files: files
        )
    }

    /// Advances the fake download twice per second until the task is cancelled.
    public func run() async {
        while !Task.isCancelled {
            step()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    public func setPriority(_ priority: PiecePriority, pieces: ClosedRange<Int>) {
        for i in pieces where i < map.pieceCount { map.priority[i] = priority.rawValue }
    }

    public func setPriority(_ priority: PiecePriority, files ids: Set<Int>) {
        for file in map.files where ids.contains(file.id) {
            if let pieces = file.pieces { setPriority(priority, pieces: pieces) }
        }
    }

    public func step() {
        var next = map
        var active = 0
        for i in 0..<next.pieceCount where next.fill[i] != PieceMap.missing && next.fill[i] != PieceMap.have {
            active += 1
            let advanced = Int(next.fill[i]) + Int(generator.next() % 90)
            next.fill[i] = advanced >= 255 ? PieceMap.have : UInt8(advanced)
        }
        // Start new pieces. Like libtorrent, the highest priority level with missing pieces goes first.
        var started = 0
        let wanted = next.priority.indices.filter { next.fill[$0] == PieceMap.missing && next.priority[$0] > 0 }
        if let top = wanted.map({ next.priority[$0] }).max() {
            var candidates = wanted.filter { next.priority[$0] == top }
            while active + started < 60, started < 40, !candidates.isEmpty {
                let pick = Int(generator.next() % UInt64(candidates.count))
                next.fill[candidates.remove(at: pick)] = 1
                started += 1
            }
        }
        for _ in 0..<200 {
            let i = Int(generator.next() % UInt64(next.pieceCount))
            next.availability[i] = Self.availability(at: i, count: next.pieceCount, rng: &generator)
        }
        map = next
    }
}

extension PieceMapSimulator {
    /// Swarm-like availability: most pieces are common, with a few rare stretches.
    static func availability(at index: Int, count: Int, rng: inout SplitMix64) -> UInt16 {
        let position = Double(index) / Double(max(1, count))
        let wave = 5 + 3 * sin(position * 2 * .pi * 3) // regions of more and fewer peers
        let noise = Double(rng.next() % 5) - 2
        if rng.next() % 100 < 2 { return 0 }
        return UInt16(max(0, min(12, (wave + noise).rounded())))
    }
}

/// Small deterministic generator so previews look the same every time.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
