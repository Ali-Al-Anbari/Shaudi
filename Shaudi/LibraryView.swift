//
//  LibraryView.swift
//  Shaudi
//

import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var tracks: [Track]

    @State private var isShowingNewTrack = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(tracks) { track in
                    NavigationLink {
                        TrackDetailView(track: track)
                    } label: {
                        Text(track.title)
                    }
                }
                .onDelete(perform: deleteTracks)
            }
            .navigationTitle("Library")
            .toolbar {
                Button {
                    isShowingNewTrack = true
                } label: {
                    Label("New Track", systemImage: "plus")
                }
            }
            .sheet(isPresented: $isShowingNewTrack) {
                TrackEditorView(
                    title: "New Track",
                    actionTitle: "Create"
                ) { title, youtubeVideo in
                    modelContext.insert(
                        Track(
                            title: title,
                            youtubeURL: youtubeVideo.url,
                            youtubeVideoID: youtubeVideo.id
                        )
                    )
                }
            }
        }
    }

    private func deleteTracks(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(tracks[index])
        }
    }
}

struct TrackEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let actionTitle: String
    let onSave: (String, YouTubeURLParser.Video) -> Void

    @State private var trackTitle: String
    @State private var youtubeURLText: String

    init(
        title: String,
        actionTitle: String,
        initialTrackTitle: String = "",
        initialYouTubeURL: URL? = nil,
        onSave: @escaping (String, YouTubeURLParser.Video) -> Void
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.onSave = onSave
        _trackTitle = State(initialValue: initialTrackTitle)
        _youtubeURLText = State(initialValue: initialYouTubeURL?.absoluteString ?? "")
    }

    private var trimmedTitle: String {
        trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedURLText: String {
        youtubeURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedYouTubeVideo: YouTubeURLParser.Video? {
        YouTubeURLParser.parse(trimmedURLText)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Track Title", text: $trackTitle)

                Section {
                    TextField("YouTube URL", text: $youtubeURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if !trimmedURLText.isEmpty && parsedYouTubeVideo == nil {
                        Text("Enter a valid YouTube video URL.")
                    }
                }
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
                        guard let youtubeVideo = parsedYouTubeVideo else {
                            return
                        }

                        onSave(trimmedTitle, youtubeVideo)
                        dismiss()
                    }
                    .disabled(trimmedTitle.isEmpty || parsedYouTubeVideo == nil)
                }
            }
        }
    }
}

struct TrackDetailView: View {
    let track: Track

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @State private var isShowingEdit = false

    var body: some View {
        Form {
            Section("Track") {
                LabeledContent("Title", value: track.title)
                LabeledContent("YouTube URL", value: track.youtubeURL.absoluteString)
                LabeledContent(
                    "Date Added",
                    value: track.dateAdded.formatted(date: .abbreviated, time: .shortened)
                )
            }

            Section("Playlists") {
                if playlists.isEmpty {
                    Text("No playlists available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(playlists) { playlist in
                        Button {
                            toggleMembership(in: playlist)
                        } label: {
                            HStack {
                                Text(playlist.name)
                                    .foregroundStyle(.primary)

                                Spacer()

                                if isInPlaylist(playlist) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(track.title)
        .toolbar {
            Button("Edit") {
                isShowingEdit = true
            }
        }
        .sheet(isPresented: $isShowingEdit) {
            TrackEditorView(
                title: "Edit Track",
                actionTitle: "Save",
                initialTrackTitle: track.title,
                initialYouTubeURL: track.youtubeURL
            ) { title, youtubeVideo in
                track.title = title

                if track.youtubeURL != youtubeVideo.url {
                    track.youtubeURL = youtubeVideo.url
                    track.youtubeVideoID = youtubeVideo.id
                }
            }
        }
    }

    private func isInPlaylist(_ playlist: Playlist) -> Bool {
        track.playlists.contains { $0 === playlist }
    }

    private func toggleMembership(in playlist: Playlist) {
        if let index = track.playlists.firstIndex(where: { $0 === playlist }) {
            track.playlists.remove(at: index)
        } else {
            track.playlists.append(playlist)
        }
    }
}
