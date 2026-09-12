//
//  PlaylistsView.swift
//  Shaudi
//

import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct PlaylistsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @State private var isShowingNewPlaylist = false

    var body: some View {
        NavigationStack {
            playlistList
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

    private var playlistList: some View {
        List {
            ForEach(playlists) { playlist in
                NavigationLink {
                    PlaylistDetailView(playlist: playlist)
                } label: {
                    playlistRow(playlist)
                }
                .listRowBackground(ShaudiTheme.card)
                .listRowSeparator(.hidden)
            }
            .onDelete(perform: deletePlaylists)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ShaudiTheme.canvas)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ShaudiTheme.accent.opacity(0.14))

                Image(systemName: "rectangle.stack.fill")
                    .font(.headline)
                    .foregroundStyle(ShaudiTheme.accent)
            }
            .frame(width: 42, height: 42)

            Text(playlist.name)
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
    }

    private func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            let playlist = playlists[index]
            if let artworkID = playlist.artworkID {
                ArtworkStorage.deletePlaylistImage(for: artworkID)
            }
            modelContext.delete(playlist)
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
            .scrollContentBackground(.hidden)
            .background(ShaudiTheme.canvas)
            .tint(ShaudiTheme.accent)
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

struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let playlist: Playlist

    @State private var isShowingRename = false
    @State private var isShowingAddTracks = false
    @State private var isShowingPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var editingArtworkImage: UIImage?
    @State private var isShowingArtworkCropper = false

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
                            TrackDetailView(
                                track: track,
                                queue: tracks,
                                playbackOrigin: .playlist(playlist.persistentModelID)
                            )
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(ShaudiTheme.lavender)
                                    .frame(width: 28, height: 28)
                                    .background(ShaudiTheme.lavender.opacity(0.14), in: Circle())

                                Text(track.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 5)
                        }
                        .listRowBackground(ShaudiTheme.card)
                        .listRowSeparator(.hidden)
                    }
                    .onDelete(perform: removeTracks)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(ShaudiTheme.canvas)
            }
        }
        .tint(ShaudiTheme.accent)
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(playlist.name)
                    .font(ShaudiTheme.scriptFont(size: 25, relativeTo: .title2))
                    .foregroundStyle(ShaudiTheme.accent)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
        }
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

                Button {
                    isShowingPhotoPicker = true
                } label: {
                    Label("Change Playlist Photo", systemImage: "photo")
                }
            } label: {
                Label("Playlist Actions", systemImage: "ellipsis.circle")
            }
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: selectedPhoto) { _, photo in
            prepareSelectedArtwork(photo)
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
        .sheet(isPresented: $isShowingArtworkCropper) {
            if let editingArtworkImage {
                ImageCropEditor(
                    image: editingArtworkImage,
                    title: "Adjust Playlist Photo",
                    cropAspectRatio: 1,
                    outputSize: ArtworkStorage.playlistOutputSize,
                    cornerRadius: 18
                ) { croppedImage in
                    savePlaylistArtwork(croppedImage)
                }
            }
        }
    }

    private func removeTracks(at offsets: IndexSet) {
        for index in offsets {
            let track = tracks[index]
            playlist.tracks.removeAll { $0 === track }
        }
    }

    private func prepareSelectedArtwork(_ selectedPhoto: PhotosPickerItem?) {
        guard let selectedPhoto else {
            return
        }

        Task { @MainActor in
            defer { self.selectedPhoto = nil }
            guard
                let data = try? await selectedPhoto.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                return
            }

            editingArtworkImage = image
            isShowingArtworkCropper = true
        }
    }

    private func savePlaylistArtwork(_ image: UIImage) {
        let previousArtworkID = playlist.artworkID
        let newArtworkID = UUID()

        do {
            try ArtworkStorage.savePlaylistImage(image, for: newArtworkID)
            playlist.artworkID = newArtworkID

            do {
                try modelContext.save()
            } catch {
                playlist.artworkID = previousArtworkID
                ArtworkStorage.deletePlaylistImage(for: newArtworkID)
                throw error
            }

            if let previousArtworkID {
                ArtworkStorage.deletePlaylistImage(for: previousArtworkID)
            }
        } catch {
#if DEBUG
            print("[Artwork] Playlist save failed: \(error.localizedDescription)")
#endif
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
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ShaudiTheme.canvas)
            .tint(ShaudiTheme.accent)
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
                ) { request in
                    if let existingTrack = libraryTracks.first(where: {
                        $0.youtubeVideoID == request.youtubeVideo.id
                    }) {
                        guard !isAlreadyAdded(existingTrack) else {
                            return "This YouTube video is already in this Playlist."
                        }

                        add(existingTrack)
                        return nil
                    }

                    guard let metadata = request.metadata else {
                        return "Fetch the YouTube metadata before creating this track."
                    }

                    let track = Track(
                        title: metadata.title,
                        youtubeURL: request.youtubeVideo.url,
                        youtubeVideoID: request.youtubeVideo.id,
                        channelTitle: metadata.channelTitle,
                        thumbnailURL: metadata.thumbnailURL,
                        duration: metadata.duration,
                        metadataLastRefreshed: .now
                    )

                    modelContext.insert(track)
                    add(track)
                    return nil
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
