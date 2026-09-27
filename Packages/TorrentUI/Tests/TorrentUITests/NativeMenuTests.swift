#if os(macOS)
import AppKit
import Testing
@testable import TorrentUI

/// Menu items must reach their closures through AppKit's normal target/action path.
@MainActor
struct NativeMenuTests {
    func fire(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        _ = NSApplication.shared
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    @Test func contextMenuItemsRunTheirActions() {
        var ran: [String] = []
        var chosen: PiecePriority?
        let menu = NativePriorityMenu.menu(
            actions: [MenuAction("Open", systemImage: "arrow.up.forward.app") { ran.append("open") },
                      MenuAction("Show in Finder", systemImage: "folder") { ran.append("reveal") }],
            current: .normal, action: { chosen = $0 }
        )
        let actionable = menu.items.filter { $0.action != nil }
        #expect(actionable.count == 6)
        for item in actionable {
            #expect(item.action.map { NSStringFromSelector($0) } == "performMenuAction:")
            #expect(fire(item), "\(item.title) did not run")
        }
        #expect(ran == ["open", "reveal"])
        #expect(chosen == .skip) // last item fired
    }

    @Test func genericMenuKeepsStateAndSkipsDoubleSeparators() {
        var ran = 0
        let menu = NativePriorityMenu.menu([
            .action(MenuAction("Pause", systemImage: "pause") { ran += 1 }),
            .separator, .separator,
            .action(MenuAction("In Order", systemImage: "arrow.right", isChecked: true) { ran += 10 }),
            .action(MenuAction("Remove", systemImage: "trash", isEnabled: false) { ran += 100 }),
            .separator,
        ])
        #expect(menu.items.map(\.isSeparatorItem) == [false, true, false, false])
        #expect(menu.items[2].state == .on)
        #expect(!menu.items[3].isEnabled)
        #expect(fire(menu.items[0]) && fire(menu.items[2]))
        #expect(ran == 11)
    }

    @Test func popUpButtonItemsRunTheirActions() {
        var chosen: [PiecePriority] = []
        let items = NativePriorityMenu.items(current: nil) { chosen.append($0) }
        for item in items { #expect(fire(item)) }
        #expect(chosen == PiecePriority.menuOrder)
    }
}
#endif
