import SwiftUI
import TesseraKit

/// What the menu bar commands act on, for one window.
///
/// A single long-lived object (the window keeps it in @State): SwiftUI compares focused values
/// by identity, and handing it a fresh struct of closures on every redraw made it rebuild the
/// main menu, which redrew the window again, a loop that hung the app at launch.
@Observable
final class TorrentActions {
    private(set) var selectionCount = 0
    private(set) var canPause = false
    private(set) var canResume = false
    /// nil when "Download in Order" does not apply (none or several selected, or Download from Start active).
    private(set) var isSequential: Bool?

    @ObservationIgnored var openFile: () -> Void = {}
    @ObservationIgnored var addMagnet: () -> Void = {}
    @ObservationIgnored var pause: () -> Void = {}
    @ObservationIgnored var resume: () -> Void = {}
    @ObservationIgnored var remove: (_ deleteFiles: Bool) -> Void = { _ in }
    @ObservationIgnored var revealInFinder: () -> Void = {}
    @ObservationIgnored var copyMagnetLink: () -> Void = {}
    @ObservationIgnored var toggleSequential: () -> Void = {}
    @ObservationIgnored var pauseAll: () -> Void = {}
    @ObservationIgnored var resumeAll: () -> Void = {}

    /// Updates the menu state; assigns only what changed so the menus are not invalidated needlessly.
    func update(selected: [TorrentStatus]) {
        let single = selected.count == 1 ? selected.first : nil
        let sequential = single.flatMap { $0.fileDownloadingFromStart < 0 && $0.state != .seeding ? $0.isSequential : nil }
        let pausable = selected.contains { !$0.isPaused }
        let resumable = selected.contains(where: \.isPaused)
        if selectionCount != selected.count { selectionCount = selected.count }
        if canPause != pausable { canPause = pausable }
        if canResume != resumable { canResume = resumable }
        if isSequential != sequential { isSequential = sequential }
    }
}

extension FocusedValues {
    @Entry var torrentActions: TorrentActions?
}

struct TorrentCommands: Commands {
    @FocusedValue(\.torrentActions) private var actions
    /// Same key as MainWindow, so the menu and the toolbar button stay in sync.
    @AppStorage("showDetailsPane") private var showDetails = true

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Torrent File…") { actions?.openFile() }
                .keyboardShortcut("o")
            Button("Add Magnet Link…") { actions?.addMagnet() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .sidebar) {
            Button(showDetails ? "Hide Details" : "Show Details") { showDetails.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions == nil)
        }
        CommandMenu("Torrent") {
            Button("Pause") { actions?.pause() }
                .keyboardShortcut(".")
                .disabled(!(actions?.canPause ?? false))
            Button("Resume") { actions?.resume() }
                .keyboardShortcut("/")
                .disabled(!(actions?.canResume ?? false))
            Divider()
            Button("Pause All") { actions?.pauseAll() }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Resume All") { actions?.resumeAll() }
                .keyboardShortcut("/", modifiers: [.command, .option])
                .disabled(actions == nil)
            Divider()
            Toggle("Download in Order", isOn: Binding(
                get: { actions?.isSequential ?? false },
                set: { _ in actions?.toggleSequential() }
            ))
            .disabled(actions?.isSequential == nil)
            Divider()
            Button("Show in Finder") { actions?.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled((actions?.selectionCount ?? 0) == 0)
            Button("Copy Magnet Link") { actions?.copyMagnetLink() }
                .disabled((actions?.selectionCount ?? 0) != 1)
            Divider()
            Button("Remove…") { actions?.remove(false) }
                .keyboardShortcut(.delete)
                .disabled((actions?.selectionCount ?? 0) == 0)
            Button("Remove and Delete Files…") { actions?.remove(true) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled((actions?.selectionCount ?? 0) == 0)
        }
    }
}
