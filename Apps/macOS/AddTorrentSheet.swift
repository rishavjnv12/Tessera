import SwiftUI
import TorrentKit
import TorrentUI

/// Shown for each torrent being added: where to save it and which files to download.
struct AddTorrentSheet: View {
    var store: TorrentStore
    var add: PendingAdd

    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL
    @State private var wanted: Set<Int>
    @State private var start = true

    init(store: TorrentStore, add: PendingAdd) {
        self.store = store
        self.add = add
        _folder = State(initialValue: store.downloadFolder)
        _wanted = State(initialValue: Set(add.preview.files.map(\.index)))
    }

    private var preview: TorrentPreview { add.preview }

    private var selectedSize: Int64 {
        preview.files.filter { wanted.contains($0.index) }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: preview.isMagnet ? "link.circle.fill" : "doc.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.name)
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if preview.isPrivate {
                        Label("Private torrent: peers only come from its trackers", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if preview.files.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Files").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(wanted.count == preview.files.count ? "Select None" : "Select All") {
                            wanted = wanted.count == preview.files.count ? [] : Set(preview.files.map(\.index))
                        }
                        .buttonStyle(.borderless)
                    }
                    List(preview.files, id: \.index) { file in
                        Toggle(isOn: Binding(
                            get: { wanted.contains(file.index) },
                            set: { if $0 { wanted.insert(file.index) } else { wanted.remove(file.index) } }
                        )) {
                            HStack {
                                Text(file.path.split(separator: "/").dropFirst().joined(separator: "/").nilIfEmpty ?? file.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(Format.bytes(file.size)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    .listStyle(.bordered)
                    .frame(height: min(260, CGFloat(preview.files.count) * 24 + 12))
                }
            }

            Form {
                LabeledContent("Save to") {
                    HStack {
                        Label(folder.path.abbreviatingHome, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Start downloading right away", isOn: $start)
            }
            .formStyle(.columns)

            HStack {
                if store.pendingAdds.count > 1 {
                    Text("\(store.pendingAdds.count - 1) more waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    store.dismiss(add)
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let priorities = preview.files.isEmpty || wanted.count == preview.files.count
                        ? nil
                        : preview.files.sorted { $0.index < $1.index }.map { wanted.contains($0.index) ? 4 : 0 }
                    store.accept(add, folder: folder, filePriorities: priorities, start: start)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!preview.files.isEmpty && wanted.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var summary: String {
        if preview.isMagnet { return String(localized: "Magnet link · files and size appear once details arrive from peers") }
        let files = preview.files.count == 1 ? String(localized: "1 file") : String(localized: "\(preview.files.count) files")
        if wanted.count == preview.files.count { return "\(Format.bytes(preview.totalSize)) · \(files)" }
        return String(localized: "\(Format.bytes(selectedSize)) of \(Format.bytes(preview.totalSize)) · \(wanted.count) of \(files)")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            FolderAccess.remember(url)
            folder = url.resolvingSymlinksInPath()
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
