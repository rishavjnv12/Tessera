import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Share → Torrent": collects .torrent files and magnet links and leaves them in the app's
/// inbox. The app adds them the next time it opens.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model, onDone: { [weak self] in self?.finish() }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { await model.load(items) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@Observable
final class ShareModel {
    enum State {
        case loading
        case found([Inbox.Item])
        case nothing
        case saved(Int)
        case failed(String)
    }

    var state: State = .loading

    private static let torrentType = UTType(importedAs: "org.bittorrent.torrent")

    func load(_ items: [NSExtensionItem]) async {
        var found: [Inbox.Item] = []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(Self.torrentType.identifier),
               let data = try? await provider.loadData(for: Self.torrentType) {
                found.append(.torrent(data: data, name: provider.suggestedName.map { "\($0).torrent" } ?? "Shared.torrent"))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = try? await provider.loadObject(ofClass: URL.self) {
                if url.scheme?.lowercased() == "magnet" {
                    found.append(.magnet(url.absoluteString))
                } else if url.pathExtension.lowercased() == "torrent",
                          let (data, _) = try? await URLSession.shared.data(from: url) {
                    found.append(.torrent(data: data, name: url.lastPathComponent))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadObject(ofClass: String.self) {
                let links = text.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.lowercased().hasPrefix("magnet:") }
                found += links.map { Inbox.Item.magnet($0) }
            }
        }
        state = found.isEmpty ? .nothing : .found(found)
    }

    func save(_ items: [Inbox.Item]) {
        do {
            for item in items { try Inbox.add(item) }
            state = .saved(items.count)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private extension NSItemProvider {
    var suggestedNameOrNil: String? { suggestedName }

    func loadData(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    func loadObject<T: _ObjectiveCBridgeable>(ofClass: T.Type) async throws -> T where T._ObjectiveCType: NSItemProviderReading {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: T.self) { value, error in
                if let value { continuation.resume(returning: value) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}

private struct ShareView: View {
    var model: ShareModel
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Torrent")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isFinished ? "Done" : "Cancel", action: onDone)
                    }
                    if case .found(let items) = model.state {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") { model.save(items) }
                        }
                    }
                }
        }
    }

    private var isFinished: Bool {
        if case .saved = model.state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .found(let items):
            List(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .torrent(_, let name):
                    Label(name, systemImage: "doc")
                case .magnet(let link):
                    Label(Inbox.name(ofMagnet: link) ?? String(localized: "Magnet link"), systemImage: "link")
                }
            }
        case .nothing:
            ContentUnavailableView("Nothing to Add", systemImage: "questionmark.circle",
                                   description: Text("Share a .torrent file or a magnet link."))
        case .saved(let count):
            ContentUnavailableView {
                Label(count == 1 ? "Added to Torrent" : "\(count) Added to Torrent", systemImage: "checkmark.circle.fill")
            } description: {
                Text("Open Torrent to start downloading.")
            }
        case .failed(let message):
            ContentUnavailableView("Couldn’t Add", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }
}
