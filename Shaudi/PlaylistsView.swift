//
//  PlaylistsView.swift
//  Shaudi
//

import SwiftData
import SwiftUI

struct PlaylistsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @State private var isShowingNewPlaylist = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        Text(playlist.name)
                    }
                }
                .onDelete(perform: deletePlaylists)
            }
            .navigationTitle("Playlists")
            .toolbar {
                Button {
                    isShowingNewPlaylist = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
            }
            .sheet(isPresented: $isShowingNewPlaylist) {
                PlaylistNameEditor(
                    title: "New Playlist",
                    actionTitle: "Create"
                ) { name in
                    modelContext.insert(Playlist(name: name))
                }
            }
        }
    }

    private func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(playlists[index])
        }
    }
}

private struct PlaylistNameEditor: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let actionTitle: String
    let onSave: (String) -> Void

    @State private var name: String

    init(
        title: String,
        actionTitle: String,
        initialName: String = "",
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist Name", text: $name)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        onSave(trimmedName)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}

private struct PlaylistDetailView: View {
    let playlist: Playlist

    @State private var isShowingRename = false

    var body: some View {
        Text("Playlist content will appear here.")
            .navigationTitle(playlist.name)
            .toolbar {
                Button("Rename") {
                    isShowingRename = true
                }
            }
            .sheet(isPresented: $isShowingRename) {
                PlaylistNameEditor(
                    title: "Rename Playlist",
                    actionTitle: "Save",
                    initialName: playlist.name
                ) { name in
                    playlist.name = name
                }
            }
    }
}
