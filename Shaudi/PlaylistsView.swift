//
//  PlaylistsView.swift
//  Shaudi
//

import SwiftData
import SwiftUI

struct PlaylistsView: View {
    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @State private var isShowingNewPlaylist = false

    var body: some View {
        NavigationStack {
            List(playlists) { playlist in
                NavigationLink {
                    PlaylistDetailView(playlist: playlist)
                } label: {
                    Text(playlist.name)
                }
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
                NewPlaylistView()
            }
        }
    }
}

private struct NewPlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist Name", text: $name)
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        modelContext.insert(Playlist(name: trimmedName))
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

    var body: some View {
        Text("Playlist content will appear here.")
            .navigationTitle(playlist.name)
    }
}
