import Foundation

/// The priority levels offered in the UI, mapped onto libtorrent's 0...7 scale.
public enum PiecePriority: UInt8, CaseIterable, Identifiable, Sendable {
    case skip = 0
    case lowest = 1
    case normal = 4
    case highest = 7

    public var id: UInt8 { rawValue }

    /// Buckets any engine level into the nearest UI level.
    public init(level: Int) {
        switch level {
        case ...0: self = .skip
        case 1...3: self = .lowest
        case 4: self = .normal
        default: self = .highest
        }
    }

    /// Order used in menus, most urgent first.
    public static let menuOrder: [PiecePriority] = [.highest, .normal, .lowest, .skip]

    public var title: String {
        switch self {
        case .highest: String(localized: "Highest")
        case .normal: String(localized: "Normal")
        case .lowest: String(localized: "Lowest")
        case .skip: String(localized: "Don’t Download")
        }
    }

    public var systemImage: String {
        switch self {
        case .highest: "arrow.up.to.line"
        case .normal: "equal"
        case .lowest: "arrow.down.to.line"
        case .skip: "nosign"
        }
    }
}
