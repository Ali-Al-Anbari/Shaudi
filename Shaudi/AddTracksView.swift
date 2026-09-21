//
//  AddTracksView.swift
//  Shaudi
//

import SwiftUI
import SwiftData

struct AddTracksView: View {
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
                                        Text(track.displayTitle)
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
