import Foundation

/// State of every piece in a torrent, independent of the engine that produced it.
public struct PieceMap: Sendable, Equatable {
    /// Values in `fill`: 0 missing, 1...254 downloading (share of blocks received), 255 downloaded.
    public static let missing: UInt8 = 0
    public static let have: UInt8 = 255

    public var pieceLength: Int
    public var totalSize: Int64
    public var fill: [UInt8]
    /// 0 skip, 1 lowest, 4 normal, 7 highest.
    public var priority: [UInt8]
    /// Connected peers that have each piece.
    public var availability: [UInt16]
    /// False while seeding: the engine does not count availability then.
    public var tracksAvailability: Bool
    /// Files and the pieces they span, for boundaries and hover details.
    public var files: [File]

    public struct File: Sendable, Equatable, Identifiable {
        public var id: Int
        public var path: String
        public var size: Int64
        /// Inclusive range. nil for empty files.
        public var pieces: ClosedRange<Int>?

        public init(id: Int, path: String, size: Int64, pieces: ClosedRange<Int>?) {
            self.id = id
            self.path = path
            self.size = size
            self.pieces = pieces
        }

        public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    }

    public init(
        pieceLength: Int, totalSize: Int64, fill: [UInt8], priority: [UInt8], availability: [UInt16],
        tracksAvailability: Bool, files: [File] = []
    ) {
        precondition(priority.count == fill.count && availability.count == fill.count, "arrays must have one entry per piece")
        self.pieceLength = pieceLength
        self.totalSize = totalSize
        self.fill = fill
        self.priority = priority
        self.availability = availability
        self.tracksAvailability = tracksAvailability
        self.files = files
    }

    public static let empty = PieceMap(pieceLength: 0, totalSize: 0, fill: [], priority: [], availability: [], tracksAvailability: false)

    public var pieceCount: Int { fill.count }

    /// Share of one piece that is downloaded, 0...1.
    public static func fraction(_ fill: UInt8) -> Double {
        switch fill {
        case missing: 0
        case have: 1
        default: Double(fill - 1) / 253 * 0.98 + 0.01 // never shows as fully empty or full
        }
    }

    public var summary: Summary {
        var s = Summary()
        for i in fill.indices {
            switch fill[i] {
            case Self.have: s.downloaded += 1
            case Self.missing: break
            default: s.downloading += 1
            }
            if priority[i] == 0 { s.skipped += 1 }
        }
        return s
    }

    public struct Summary: Equatable, Sendable {
        public var downloaded = 0
        public var downloading = 0
        public var skipped = 0
    }

    /// Files that hold bytes of any piece in `pieces`.
    public func files(overlapping pieces: ClosedRange<Int>) -> [File] {
        files.filter { $0.pieces?.overlaps(pieces) ?? false }
    }
}

// MARK: - Deltas

/// The pieces that changed between two maps of the same torrent.
public struct PieceMapDelta: Sendable, Equatable {
    public var indices: [Int32] = []
    public var fill: [UInt8] = []
    public var priority: [UInt8] = []
    public var availability: [UInt16] = []
    public var tracksAvailability: Bool

    /// True when applying it would change nothing. `tracksAvailability` is compared by the caller.
    public var isEmpty: Bool { indices.isEmpty }
    public var count: Int { indices.count }
}

extension PieceMap {
    /// Changes needed to turn `self` into `newer`. nil when the piece count differs,
    /// e.g. when metadata just arrived; send the full map then.
    public func delta(to newer: PieceMap) -> PieceMapDelta? {
        guard newer.pieceCount == pieceCount, newer.pieceLength == pieceLength else { return nil }
        var delta = PieceMapDelta(tracksAvailability: newer.tracksAvailability)
        for i in 0..<pieceCount
        where fill[i] != newer.fill[i] || priority[i] != newer.priority[i] || availability[i] != newer.availability[i] {
            delta.indices.append(Int32(i))
            delta.fill.append(newer.fill[i])
            delta.priority.append(newer.priority[i])
            delta.availability.append(newer.availability[i])
        }
        return delta
    }

    public mutating func apply(_ delta: PieceMapDelta) {
        for (k, index) in delta.indices.enumerated() {
            let i = Int(index)
            guard i >= 0, i < pieceCount else { continue }
            fill[i] = delta.fill[k]
            priority[i] = delta.priority[k]
            availability[i] = delta.availability[k]
        }
        tracksAvailability = delta.tracksAvailability
    }
}

// MARK: - Cells

/// Several pieces aggregated into one on-screen cell.
public struct PieceCell: Sendable, Equatable {
    /// Share of the cell's bytes that is downloaded, 0...1.
    public var fraction: Double
    /// At least one piece is being downloaded right now.
    public var isActive: Bool
    /// Highest priority among the pieces. Shows that something in the cell was raised.
    public var maxPriority: UInt8
    /// All pieces are skipped.
    public var isSkipped: Bool
    /// Rarest piece in the cell.
    public var minAvailability: UInt16
}

extension PieceMap {
    /// Aggregates pieces `range` into one cell.
    public func cell(for range: Range<Int>) -> PieceCell {
        var total = 0.0
        var active = false
        var maxPriority: UInt8 = 0
        var allSkipped = true
        var minAvailability = UInt16.max
        for i in range {
            let f = fill[i]
            total += Self.fraction(f)
            if f != Self.have && f != Self.missing { active = true }
            maxPriority = max(maxPriority, priority[i])
            if priority[i] != 0 { allSkipped = false }
            minAvailability = min(minAvailability, availability[i])
        }
        return PieceCell(
            fraction: range.isEmpty ? 0 : total / Double(range.count),
            isActive: active,
            maxPriority: maxPriority,
            isSkipped: allSkipped && !range.isEmpty,
            minAvailability: range.isEmpty ? 0 : minAvailability
        )
    }
}
