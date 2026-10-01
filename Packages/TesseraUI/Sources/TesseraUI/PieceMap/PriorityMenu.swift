import SwiftUI

/// "Priority" pull-down with the four levels. The current level is ticked; pass nil when
/// the selection mixes levels.
///
/// On macOS this is a native NSPopUpButton; see NativeMenus+macOS.swift.
public struct PriorityMenu: View {
    public var current: PiecePriority?
    public var action: (PiecePriority) -> Void

    public init(current: PiecePriority?, action: @escaping (PiecePriority) -> Void) {
        self.current = current
        self.action = action
    }

    public var body: some View {
        #if os(macOS)
        PriorityPopUpButton(current: current, action: action)
            .fixedSize()
        #else
        Menu {
            PriorityMenuItems(current: current, action: action)
        } label: {
            Label("Priority", systemImage: "flag")
        }
        #endif
    }
}

/// An extra command shown above the priority levels in a file's context menu.
public struct MenuAction: Identifiable {
    public var id: String { title }
    public var title: String
    public var systemImage: String
    public var isEnabled: Bool
    /// Shows a tick, for on/off settings such as "Download in Order".
    public var isChecked: Bool
    public var action: () -> Void

    public init(_ title: String, systemImage: String, isEnabled: Bool = true, isChecked: Bool = false,
                action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.action = action
    }
}

/// An entry of a context menu built with `nativeContextMenu` (macOS) or `contextMenu` (iOS).
public enum ContextMenuItem {
    case action(MenuAction)
    case separator
}

#if os(iOS)
extension View {
    /// Context menu from a list of items.
    public func nativeContextMenu(_ items: @escaping () -> [ContextMenuItem]) -> some View {
        contextMenu {
            ForEach(Array(items().enumerated()), id: \.offset) { _, item in
                switch item {
                case .action(let a):
                    Button(a.title, systemImage: a.isChecked ? "checkmark" : a.systemImage, action: a.action)
                        .disabled(!a.isEnabled)
                case .separator:
                    Divider()
                }
            }
        }
    }

    /// Context menu with `actions`, then the four priority levels when `onSetPriority` is set.
    public func fileContextMenu(actions: [MenuAction], current: PiecePriority?, onSetPriority: ((PiecePriority) -> Void)?) -> some View {
        contextMenu {
            ForEach(actions) { item in
                Button(item.title, systemImage: item.systemImage, action: item.action)
            }
            if let onSetPriority {
                if !actions.isEmpty { Divider() }
                PriorityMenuItems(current: current, action: onSetPriority)
            }
        }
    }
}
#endif

/// The four levels as checkable menu items, for SwiftUI menus and context menus (iOS).
public struct PriorityMenuItems: View {
    public var current: PiecePriority?
    public var action: (PiecePriority) -> Void

    public init(current: PiecePriority?, action: @escaping (PiecePriority) -> Void) {
        self.current = current
        self.action = action
    }

    public var body: some View {
        Picker("Priority", selection: Binding(get: { current }, set: { if let new = $0 { action(new) } })) {
            ForEach(PiecePriority.menuOrder) { priority in
                Label(priority.title, systemImage: priority.systemImage)
                    .tag(Optional(priority))
            }
        }
        .pickerStyle(.inline)
    }
}

extension PiecePriority {
    /// The shared level of `levels`, or nil when they differ or there are none.
    public static func common(_ levels: some Sequence<PiecePriority>) -> PiecePriority? {
        var iterator = levels.makeIterator()
        guard let first = iterator.next() else { return nil }
        while let next = iterator.next() {
            if next != first { return nil }
        }
        return first
    }
}
