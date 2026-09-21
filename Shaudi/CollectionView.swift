//
//  CollectionView.swift
//  Shaudi
//

import SwiftData
import SwiftUI

struct CollectionView: View {
    private enum SortOption: String, CaseIterable, Identifiable {
        case mostPlayed = "Most Played"
        case mostListened = "Most Listened"
        case recentlyPlayed = "Recently Played"
        case dateAdded = "Date Added"
        case alphabetical = "A–Z"

        var id: Self { self }
    }

    private enum FilterOption: String, CaseIterable, Identifiable {
        case allSongs = "All Songs"
        case played = "Played"
        case neverPlayed = "Never Played"

        var id: Self { self }
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var playbackManager: PlaybackManager

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var tracks: [Track]

    @State private var isSelectingTracks = false
    @State private var selectedTrackIDs: Set<PersistentIdentifier> = []
    @State private var isShowingDeleteConfirmation = false
    @State private var infoTrack: Track?
    @State private var editingTrack: Track?
    @State private var trimmingTrack: Track?
    @State private var playlistTrack: Track?
    @State private var searchText = ""
    @State private var sortOption: SortOption = .mostPlayed
    @State private var filterOption: FilterOption = .allSongs

    private var displayedTracks: [Track] {
        let filteredTracks = tracks.filter { track in
            matchesFilter(track) && matchesSearch(track)
        }
        return sortedTracks(filteredTracks, by: sortOption)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                searchField
                collectionControls

                if tracks.isEmpty {
                    ContentUnavailableView(
                        "Your Library Is Quiet",
                        systemImage: "music.note.list",
                        description: Text("Add a track to start your collection.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else if displayedTracks.isEmpty {
                    ContentUnavailableView(
                        "No Matching Songs",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search, filter, or sort option.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(displayedTracks) { track in
                            trackRow(track)
                        }
                    }
                }
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .background(ShaudiTheme.dashboardBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(
            get: { infoTrack != nil },
            set: { if !$0 { infoTrack = nil } }
        )) {
            if let infoTrack {
                TrackDetailView(
                    track: infoTrack,
                    queue: tracks,
                    playbackOrigin: .library
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { editingTrack != nil },
            set: { if !$0 { editingTrack = nil } }
        )) {
            if let editingTrack {
                SongEditorView(track: editingTrack)
            }
        }
        .sheet(isPresented: Binding(
            get: { trimmingTrack != nil },
            set: { if !$0 { trimmingTrack = nil } }
        )) {
            if let trimmingTrack {
                TrackTrimEditorView(track: trimmingTrack)
            }
        }
        .overlay {
            if let playlistTrack {
                ShaudiAddToPlaylistModal(
                    isPresented: Binding(
                        get: { self.playlistTrack != nil },
                        set: { if !$0 { self.playlistTrack = nil } }
                    ),
                    transientTrack: playlistTrack
                )
            }
        }
        .alert(
            "Delete \(selectedTrackIDs.count) \(selectedTrackIDs.count == 1 ? "Song" : "Songs")?",
            isPresented: $isShowingDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteSelectedTracks()
            }
        } message: {
            Text("These songs will be removed from your Library and any playlists containing them.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("My Collection")
                .font(ShaudiTheme.scriptFont(size: 34, relativeTo: .title))
                .foregroundStyle(ShaudiTheme.accent)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            if isSelectingTracks {
                Button("Delete") {
                    isShowingDeleteConfirmation = true
                }
                .disabled(selectedTrackIDs.isEmpty)

                Button("Done") {
                    endTrackSelection()
                }
            } else {
                Button("Select") {
                    isSelectingTracks = true
                }
            }
        }
        .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline).weight(.semibold))
        .foregroundStyle(ShaudiTheme.accent)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ShaudiTheme.dashboardSecondaryText)

            TextField("Search title or artist", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            ShaudiTheme.dashboardCard,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var collectionControls: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(SortOption.allCases) { option in
                    Button {
                        sortOption = option
                    } label: {
                        if sortOption == option {
                            Label(option.rawValue, systemImage: "checkmark")
                        } else {
                            Text(option.rawValue)
                        }
                    }
                }
            } label: {
                Label(sortOption.rawValue, systemImage: "arrow.up.arrow.down")
                    .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline).weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                ForEach(FilterOption.allCases) { option in
                    Button {
                        filterOption = option
                    } label: {
                        if filterOption == option {
                            Label(option.rawValue, systemImage: "checkmark")
                        } else {
                            Text(option.rawValue)
                        }
                    }
                }
            } label: {
                Label(filterOption.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                    .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline).weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(ShaudiTheme.accent)
    }

    private func trackRow(_ track: Track) -> some View {
        let isCurrentlyPlaying = playbackManager.isCurrentTrack(track)
            || playbackManager.isCurrentPlayable(track.youtubeVideoID)
        let isSelected = selectedTrackIDs.contains(track.persistentModelID)

        return LibraryTrackRow(
            track: track,
            isCurrentlyPlaying: isCurrentlyPlaying,
            isSelected: isSelected,
            isSelectionMode: isSelectingTracks,
            play: {
                playbackManager.play(track, in: tracks, origin: .library)
            },
            toggleSelection: {
                toggleTrackSelection(track)
            },
            showInfo: {
                infoTrack = track
            },
            trim: {
                trimmingTrack = track
            },
            edit: {
                editingTrack = track
            },
            addToPlaylist: {
                playlistTrack = track
            },
            playNext: {
                playbackManager.playNext(track)
            },
            addToQueue: {
                playbackManager.addToQueue(track)
            },
            delete: {
                deleteTrackFromLibrary(track, in: modelContext)
            }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isSelected
                ? ShaudiTheme.accent.opacity(0.26)
                : (isCurrentlyPlaying ? ShaudiTheme.accent.opacity(0.14) : ShaudiTheme.dashboardCard),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func toggleTrackSelection(_ track: Track) {
        if selectedTrackIDs.contains(track.persistentModelID) {
            selectedTrackIDs.remove(track.persistentModelID)
        } else {
            selectedTrackIDs.insert(track.persistentModelID)
        }
    }

    private func endTrackSelection() {
        isSelectingTracks = false
        selectedTrackIDs.removeAll()
    }

    private func deleteSelectedTracks() {
        let tracksToDelete = tracks.filter {
            selectedTrackIDs.contains($0.persistentModelID)
        }
        tracksToDelete.forEach { track in
            deleteTrackFromLibrary(track, in: modelContext)
        }
        endTrackSelection()
    }

    private func matchesFilter(_ track: Track) -> Bool {
        let hasListeningHistory = track.playCount > 0
            || track.totalListenedDuration > 0
            || track.lastPlayedAt != nil

        switch filterOption {
        case .allSongs:
            return true
        case .played:
            return hasListeningHistory
        case .neverPlayed:
            return !hasListeningHistory
        }
    }

    private func matchesSearch(_ track: Track) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return true
        }

        return track.title.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil || track.displayArtist?.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    private func sortedTracks(_ tracks: [Track], by option: SortOption) -> [Track] {
        tracks.sorted { first, second in
            switch option {
            case .mostPlayed:
                if first.playCount != second.playCount {
                    return first.playCount > second.playCount
                }
                if first.totalListenedDuration != second.totalListenedDuration {
                    return first.totalListenedDuration > second.totalListenedDuration
                }
                if let lastPlayedComparison = sortLastPlayedDate(first, second) {
                    return lastPlayedComparison
                }
            case .mostListened:
                if first.totalListenedDuration != second.totalListenedDuration {
                    return first.totalListenedDuration > second.totalListenedDuration
                }
                if first.playCount != second.playCount {
                    return first.playCount > second.playCount
                }
                if let lastPlayedComparison = sortLastPlayedDate(first, second) {
                    return lastPlayedComparison
                }
            case .recentlyPlayed:
                if let lastPlayedComparison = sortLastPlayedDate(first, second) {
                    return lastPlayedComparison
                }
                if first.playCount != second.playCount {
                    return first.playCount > second.playCount
                }
            case .dateAdded:
                if first.dateAdded != second.dateAdded {
                    return first.dateAdded > second.dateAdded
                }
            case .alphabetical:
                break
            }

            return titleComesBefore(first, second)
        }
    }

    private func sortLastPlayedDate(_ first: Track, _ second: Track) -> Bool? {
        switch (first.lastPlayedAt, second.lastPlayedAt) {
        case let (firstDate?, secondDate?) where firstDate != secondDate:
            return firstDate > secondDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return nil
        }
    }
}
