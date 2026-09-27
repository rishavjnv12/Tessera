import AppKit

/// Draws overall download progress on the Dock icon and shows the number of active downloads.
@MainActor
final class DockProgress {
    private let store: TorrentStore
    private let view = DockTileView()
    private var timer: Timer?

    init(store: TorrentStore) {
        self.store = store
        NSApp.dockTile.contentView = view
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        let progress = store.downloadingProgress
        let count = store.count(.downloading)
        let badge = count > 0 ? "\(count)" : nil
        let rounded = progress.map { ($0 * 200).rounded() / 200 } // redraw at most every 0.5%
        guard rounded != view.progress || NSApp.dockTile.badgeLabel != badge else { return }
        view.progress = rounded
        NSApp.dockTile.badgeLabel = badge
        NSApp.dockTile.display()
    }
}

private final class DockTileView: NSView {
    var progress: Double?

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        guard let progress else { return }
        let inset = bounds.width * 0.12
        let height = bounds.height * 0.1
        let track = NSRect(x: inset, y: bounds.height * 0.08, width: bounds.width - inset * 2, height: height)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
        let inner = track.insetBy(dx: height * 0.18, dy: height * 0.18)
        let fill = NSRect(x: inner.minX, y: inner.minY, width: max(inner.height, inner.width * progress), height: inner.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}
