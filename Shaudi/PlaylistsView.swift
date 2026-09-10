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
    @State private var isShowingAddTracks = false

    private var tracks: [Track] {
        playlist.tracks.sorted { $0.dateAdded > $1.dateAdded }
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView(
                    "No Tracks",
                    systemImage: "music.note",
                    description: Text("Add tracks from your Library.")
                )
            } else {
                List {
                    ForEach(tracks) { track in
                        NavigationLink {
                            TrackDetailView(track: track)
                        } label: {
                            Text(track.title)
                        }
                    }
                    .onDelete(perform: removeTracks)
                }
            }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            Menu {
                Button {
                    isShowingAddTracks = true
                } label: {
                    Label("Add Tracks", systemImage: "plus")
                }

                Button {
                    isShowingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            } label: {
                Label("Playlist Actions", systemImage: "ellipsis.circle")
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
        .sheet(isPresented: $isShowingAddTracks) {
            AddTracksView(playlist: playlist)
        }
    }

    private func removeTracks(at offsets: IndexSet) {
        for index in offsets {
            let track = tracks[index]
            playlist.tracks.removeAll { $0 === track }
        }
    }
}

private struct AddTracksView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var libraryTracks: [Track]

    let playlist: Playlist

    @State private var selectedTracks: Set<ObjectIdentifier> = []
    @State private var isShowingNewTrack = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        isShowingNewTrack = true
                    } label: {
                        Label("Create New Track", systemImage: "plus")
                    }
                }

                Section("Library") {
                    if libraryTracks.isEmpty {
                        Text("No tracks in Library.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(libraryTracks) { track in
                            Button {
                                toggleSelection(of: track)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(track.title)
                                            .foregroundStyle(.primary)

                                        if isAlreadyAdded(track) {
                                            Text("Already in Playlist")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    Image(
                                        systemName: isAlreadyAdded(track) || isSelected(track)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                }
                            }
                            .disabled(isAlreadyAdded(track))
                        }
                    }
                }
            }
            .navigationTitle("Add Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(addButtonTitle) {
                        addSelectedTracks()
                        dismiss()
                    }
                    .disabled(selectedTracks.isEmpty)
                }
            }
            .sheet(isPresented: $isShowingNewTrack) {
                TrackEditorView(
                    title: "New Track",
                    actionTitle: "Create"
                ) { title, youtubeURL in
                    let track = Track(
                        title: title,
                        youtubeURL: youtubeURL,
                        youtubeVideoID: ""
                    )

                    modelContext.insert(track)
                    add(track)
                }
            }
        }
    }

    private var addButtonTitle: String {
        selectedTracks.isEmpty ? "Add" : "Add (\(selectedTracks.count))"
    }

    private func isAlreadyAdded(_ track: Track) -> Bool {
        playlist.tracks.contains { $0 === track }
    }

    private func isSelected(_ track: Track) -> Bool {
        selectedTracks.contains(ObjectIdentifier(track))
    }

    private func toggleSelection(of track: Track) {
        guard !isAlreadyAdded(track) else {
            return
        }

        let identifier = ObjectIdentifier(track)

        if selectedTracks.contains(identifier) {
            selectedTracks.remove(identifier)
        } else {
            selectedTracks.insert(identifier)
        }
    }

    private func addSelectedTracks() {
        for track in libraryTracks where isSelected(track) {
            add(track)
        }
    }

    private func add(_ track: Track) {
        guard !isAlreadyAdded(track) else {
            return
        }

        playlist.tracks.append(track)
    }
}
