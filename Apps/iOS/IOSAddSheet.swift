import SwiftUI
import TorrentKit
import TorrentUI

/// Confirms a torrent before adding: which files to download and whether to start now.
struct IOSAddSheet: View {
    var store: TorrentStore
    var add: PendingAdd

    @State private var wanted: Set<Int>
    @State private var start = true

    init(store: TorrentStore, add: PendingAdd) {
        self.store = store
        self.add = add
        _wanted = State(initialValue: Set(add.preview.files.map(\.index)))
    }

    private var preview: TorrentPreview { add.preview }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview.name).font(.headline).lineLimit(3)
                        Text(summary).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        if preview.isPrivate {
                            Label("Private torrent: peers only come from its trackers", systemImage: "lock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if preview.files.count > 1 {
                    Section {
                        ForEach(preview.files, id: \.index) { file in
                            Button {
                                if wanted.contains(file.index) { wanted.remove(file.index) } else { wanted.insert(file.index) }
                            } label: {
                                HStack {
                                    Image(systemName: wanted.contains(file.index) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(wanted.contains(file.index) ? Color.accentColor : .secondary)
                                    Text(file.path.split(separator: "/").dropFirst().joined(separator: "/").isEmpty
                                         ? file.name : file.path.split(separator: "/").dropFirst().joined(separator: "/"))
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(Format.bytes(file.size)).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Files")
                            Spacer()
                            Button(wanted.count == preview.files.count ? "Select None" : "Select All") {
                                wanted = wanted.count == preview.files.count ? [] : Set(preview.files.map(\.index))
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    }
                }
                Section {
                    Toggle("Start downloading right away", isOn: $start)
                } footer: {
                    if store.isRemote, let mac = store.backend?.displayName {
                        Text("Downloads on \(mac), into its download folder.")
                    } else {
                        Text("Saved to On My iPhone › Torrent, visible in the Files app.")
                    }
                }
            }
            .navigationTitle(preview.isMagnet ? "Add Magnet Link" : "Add Torrent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.dismiss(add) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let priorities = preview.files.isEmpty || wanted.count == preview.files.count
                            ? nil
                            : preview.files.sorted { $0.index < $1.index }.map { wanted.contains($0.index) ? 4 : 0 }
                        store.accept(add, folder: store.downloadFolder, filePriorities: priorities, start: start)
                    }
                    .disabled(!preview.files.isEmpty && wanted.isEmpty)
                }
            }
        }
        .presentationDetents(preview.files.count > 1 ? [.large] : [.medium, .large])
    }

    private var summary: String {
        if preview.isMagnet { return String(localized: "Files and size appear once details arrive from peers") }
        let size = preview.files.filter { wanted.contains($0.index) }.reduce(Int64(0)) { $0 + $1.size }
        let files = preview.files.count == 1 ? String(localized: "1 file") : String(localized: "\(preview.files.count) files")
        return wanted.count == preview.files.count
            ? "\(Format.bytes(preview.totalSize)) · \(files)"
            : String(localized: "\(Format.bytes(size)) of \(Format.bytes(preview.totalSize)) · \(wanted.count) of \(files)")
    }
}
