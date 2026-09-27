import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// .torrent files. Registered as a document type in a later phase; until then any data file is accepted.
    static let torrentFile = UTType(filenameExtension: "torrent", conformingTo: .data) ?? .data
}

struct AddMagnetSheet: View {
    var onAdd: (String) -> Void
    @State private var link = ""
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        link.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("magnet:?")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("magnet:?xt=urn:btih:…", text: $link, axis: .vertical)
                        .lineLimit(3...6)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { link = first }
                    }
                } footer: {
                    Text("Paste a magnet link. Details download from peers after it's added.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Magnet Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(link)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 260)
        #endif
    }
}

struct NoTorrentsView: View {
    var engineVersion: String
    var onOpenFile: () -> Void
    var onAddMagnet: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Torrents", systemImage: "arrow.down.circle")
        } description: {
            Text("Add a torrent file or a magnet link to start downloading.")
        } actions: {
            Button("Open Torrent File…", action: onOpenFile)
                .buttonStyle(.borderedProminent)
            Button("Add Magnet Link…", action: onAddMagnet)
        }
        .overlay(alignment: .bottom) {
            Text("libtorrent \(engineVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding()
        }
    }
}
