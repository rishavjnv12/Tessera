#if os(macOS)
import AppKit
import SwiftUI

// On macOS the priority menus are plain AppKit menus. SwiftUI-built menu items collapsed to
// a narrow strip when the pointer moved over them (macOS 26), and native menus also match
// Finder and Mail exactly.

/// Runs a closure when a menu item is chosen. Stored in the item's representedObject,
/// because NSMenuItem only holds its target weakly.
///
/// The class and method have explicit Objective-C names: with an implicit name on a `private`
/// class, `#selector` produced a selector with a garbage name at runtime (Swift 6.4), so
/// choosing an item raised "unrecognized selector". Covered by NativeMenuTests.
@objc(TKMenuItemAction)
final class MenuItemAction: NSObject {
    static let selector = #selector(MenuItemAction.performMenuAction(_:))

    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc(performMenuAction:)
    func performMenuAction(_ sender: Any?) { handler() }
}

@MainActor
enum NativePriorityMenu {
    static func items(current: PiecePriority?, action: @escaping (PiecePriority) -> Void) -> [NSMenuItem] {
        PiecePriority.menuOrder.map { priority in
            let target = MenuItemAction { action(priority) }
            let item = NSMenuItem(title: priority.title, action: MenuItemAction.selector, keyEquivalent: "")
            item.target = target
            item.representedObject = target
            item.image = NSImage(systemSymbolName: priority.systemImage, accessibilityDescription: nil)
            item.state = priority == current ? .on : .off
            return item
        }
    }

    static func item(for action: MenuAction) -> NSMenuItem {
        let target = MenuItemAction(action.action)
        let item = NSMenuItem(title: action.title, action: MenuItemAction.selector, keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
        item.isEnabled = action.isEnabled
        item.state = action.isChecked ? .on : .off
        return item
    }

    static func menu(_ items: [ContextMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in items {
            switch entry {
            case .action(let action): menu.addItem(item(for: action))
            case .separator: if menu.items.last.map({ !$0.isSeparatorItem }) ?? false { menu.addItem(.separator()) }
            }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    static func menu(actions: [MenuAction], current: PiecePriority?, action: ((PiecePriority) -> Void)?) -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        menu.autoenablesItems = false
        for extra in actions {
            menu.addItem(item(for: extra))
        }
        if let action {
            if !actions.isEmpty { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "Priority")))
            items(current: current, action: action).forEach(menu.addItem)
        }
        return menu
    }
}

/// A "Priority" pull-down button backed by NSPopUpButton.
struct PriorityPopUpButton: NSViewRepresentable {
    var current: PiecePriority?
    var action: (PiecePriority) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let menu = NSMenu()
        // A pull-down button shows its first item as the button title.
        let title = NSMenuItem(title: String(localized: "Priority"), action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "flag", accessibilityDescription: nil)
        menu.addItem(title)
        NativePriorityMenu.items(current: current, action: action).forEach(menu.addItem)
        button.menu = menu
        button.invalidateIntrinsicContentSize()
    }
}

/// Transparent overlay that shows an AppKit context menu on right-click or Control-click
/// and lets every other event through to the SwiftUI view underneath.
struct NativeContextMenu: NSViewRepresentable {
    var makeMenu: () -> NSMenu?

    func makeNSView(context: Context) -> ContextMenuView {
        ContextMenuView()
    }

    func updateNSView(_ view: ContextMenuView, context: Context) {
        view.makeMenu = makeMenu
    }

    final class ContextMenuView: NSView {
        var makeMenu: (() -> NSMenu?)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isContextClick = event.type == .rightMouseDown
                || event.type == .rightMouseUp
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isContextClick ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            makeMenu?()
        }

        override func mouseDown(with event: NSEvent) {
            // Control-click arrives as a left click.
            if event.modifierFlags.contains(.control), let menu = makeMenu?() {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

extension View {
    /// Right-click menu built with AppKit from a list of items, created when it opens.
    public func nativeContextMenu(_ items: @escaping () -> [ContextMenuItem]) -> some View {
        overlay {
            NativeContextMenu { NativePriorityMenu.menu(items()) }
        }
    }

    /// Right-click menu with `actions`, then the four priority levels when `onSetPriority` is set.
    /// Built with AppKit.
    public func fileContextMenu(actions: [MenuAction], current: PiecePriority?, onSetPriority: ((PiecePriority) -> Void)?) -> some View {
        overlay {
            if onSetPriority != nil || !actions.isEmpty {
                NativeContextMenu { NativePriorityMenu.menu(actions: actions, current: current, action: onSetPriority) }
            }
        }
    }
}
#endif
