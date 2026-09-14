//
//  LibraryView.swift
//  Shaudi
//

import SwiftData
import SwiftUI
import UIKit

struct LibraryView: View {
    private struct PlaylistPageSlot: Identifiable {
        let id: String
        let playlist: Playlist?
        let fillerIndex: Int
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var appearanceSettings: AppearanceSettings

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var tracks: [Track]

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @State private var heroImage: UIImage?
    @State private var selectedPlaylistPage = 0
    @State private var dashboardContentWidth: CGFloat = 360
    @State private var isLibraryVisible = false
    @State private var isSelectingTracks = false
    @State private var selectedTrackIDs: Set<PersistentIdentifier> = []
    @State private var isShowingDeleteConfirmation = false
    @State private var infoTrack: Track?
    private let loveMessages = ["made with love", "For my little macaroon", "love lives here", "don't forget bf!!", "you're my favorite", "♡"]
    private let playlistPageSize = 6
    private let playlistColumnSpacing: CGFloat = 12
    private let playlistRowSpacing: CGFloat = 12
    private let playlistArtworkTitleSpacing: CGFloat = 7
    private let playlistTitleHeight: CGFloat = 20
    private let playlistPageVerticalPadding: CGFloat = 2

    private var dashboardPlaylists: [Playlist] {
        playlists.enumerated().sorted { first, second in
            switch (first.element.lastPlayedAt, second.element.lastPlayedAt) {
            case let (firstDate?, secondDate?):
                if firstDate != secondDate {
                    return firstDate > secondDate
                }
                return first.offset < second.offset
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return first.offset < second.offset
            }
        }
        .map(\.element)
    }

    private var dashboardPageCount: Int {
        max(1, (dashboardPlaylists.count + playlistPageSize - 1) / playlistPageSize)
    }

    private var rankedTracks: [Track] {
        mostPlayedTracks(from: tracks)
    }

    private var dashboardTracks: [Track] {
        Array(rankedTracks.prefix(10))
    }

    private var dashboardPlaylistIDs: [PersistentIdentifier] {
        dashboardPlaylists.map(\.persistentModelID)
    }

    private var visibleDashboardWarmupCandidates: [PlaybackManager.DashboardWarmupCandidate] {
        let startIndex = selectedPlaylistPage * playlistPageSize
        guard startIndex < dashboardPlaylists.count else {
            return []
        }

        let endIndex = min(startIndex + playlistPageSize, dashboardPlaylists.count)
        return dashboardPlaylists[startIndex..<endIndex].compactMap { playlist in
            let candidate = playlist.tracksInPlaybackOrder
                .first { !$0.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            guard let candidate else {
                return nil
            }

            return PlaybackManager.DashboardWarmupCandidate(
                playlistID: playlist.persistentModelID,
                videoID: candidate.youtubeVideoID
            )
        }
    }

    private var playlistPagerHeight: CGFloat {
        let totalColumnSpacing = playlistColumnSpacing * 2
        let artworkWidth = max(0, (dashboardContentWidth - totalColumnSpacing) / 3)
        let cardHeight = artworkWidth
            + playlistArtworkTitleSpacing
            + playlistTitleHeight
        let gridHeight = cardHeight * 2
            + playlistRowSpacing
            + playlistPageVerticalPadding * 2
        let pageControlHeight: CGFloat = dashboardPageCount > 1 ? 24 : 0
        return gridHeight + pageControlHeight
    }

    private func playlistPageSlots(for page: Int) -> [PlaylistPageSlot] {
        (0..<playlistPageSize).map { slot in
            let playlistIndex = page * playlistPageSize + slot
            guard playlistIndex < dashboardPlaylists.count else {
                return PlaylistPageSlot(
                    id: "filler-\(playlistIndex)",
                    playlist: nil,
                    fillerIndex: playlistIndex
                )
            }

            let playlist = dashboardPlaylists[playlistIndex]
            return PlaylistPageSlot(
                id: "playlist-\(String(describing: playlist.persistentModelID))",
                playlist: playlist,
                fillerIndex: playlistIndex
            )
        }
    }

    var body: some View {
        NavigationStack {
            dashboard
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadBannerImage()
            }
            .onChange(of: appearanceSettings.bannerRevision) {
                loadBannerImage()
            }
        }
        .tint(appearanceSettings.primaryColor)
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroBanner
                sectionHeader("Library")
                playlistPager
                collectionHeader
                collection
                NavigationLink {
                    CollectionView()
                } label: {
                    Label("Show All", systemImage: "arrow.right")
                        .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline).weight(.semibold))
                        .foregroundStyle(ShaudiTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
            .scrollIndicators(.hidden)
        .background(ShaudiTheme.dashboardBackground)
        .onAppear {
            isLibraryVisible = true
            updateDashboardWarmup()
        }
        .onDisappear {
            isLibraryVisible = false
            playbackManager.cancelDashboardWarmup()
        }
        .onChange(of: selectedPlaylistPage) {
            updateDashboardWarmup()
        }
        .onChange(of: dashboardPlaylistIDs) {
            let lastPage = max(0, dashboardPageCount - 1)
            let validPage = min(selectedPlaylistPage, lastPage)
            if validPage == selectedPlaylistPage {
                updateDashboardWarmup()
            } else {
                selectedPlaylistPage = validPage
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                updateDashboardWarmup()
            } else if isLibraryVisible {
                playbackManager.cancelDashboardWarmup()
            }
        }
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

    private var heroBanner: some View {
        GeometryReader { geometry in
            ZStack {
                if let heroImage {
                    Image(uiImage: heroImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    LinearGradient(colors: [ShaudiTheme.lavender.opacity(0.8), ShaudiTheme.accent.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: ShaudiTheme.accent.opacity(0.18), radius: 12, y: 6)
        .accessibilityLabel("Library poster")
    }

    private var playlistPager: some View {
        TabView(selection: $selectedPlaylistPage) {
            ForEach(0..<dashboardPageCount, id: \.self) { page in
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .flexible(),
                            spacing: playlistColumnSpacing,
                            alignment: .top
                        ),
                        count: 3
                    ),
                    spacing: playlistRowSpacing
                ) {
                    ForEach(playlistPageSlots(for: page)) { slot in
                        if let playlist = slot.playlist {
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                playlistCard(playlist)
                            }
                            .buttonStyle(.plain)
                        } else {
                            loveCard(at: slot.fillerIndex)
                        }
                    }
                }
                .padding(.vertical, playlistPageVerticalPadding)
                .tag(page)
            }
        }
        .frame(height: playlistPagerHeight)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        dashboardContentWidth = geometry.size.width
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        dashboardContentWidth = width
                    }
            }
        }
        .tabViewStyle(
            .page(indexDisplayMode: dashboardPageCount > 1 ? .automatic : .never)
        )
    }

    private var collection: some View {
        Group {
            if dashboardTracks.isEmpty {
                ContentUnavailableView("Your Library Is Quiet", systemImage: "music.note.list", description: Text("Add a track to start your collection."))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(dashboardTracks) { track in
                        libraryTrackRow(track)
                    }
                }
            }
        }
    }

    private var collectionHeader: some View {
        HStack(spacing: 12) {
            NavigationLink {
                CollectionView()
            } label: {
                sectionHeader("My Collection")
            }
            .buttonStyle(.plain)

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

    private func libraryTrackRow(_ track: Track) -> some View {
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(ShaudiTheme.scriptFont(size: 34, relativeTo: .title))
            .foregroundStyle(ShaudiTheme.accent)
            .accessibilityAddTraits(.isHeader)
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: playlistArtworkTitleSpacing) {
            playlistArtwork(playlist)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(playlist.name)
                .font(ShaudiTheme.bodyFont(size: 15))
                .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: .infinity,
                    minHeight: playlistTitleHeight,
                    maxHeight: playlistTitleHeight,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func playlistArtwork(_ playlist: Playlist) -> some View {
        PlaylistArtworkView(playlist: playlist)
    }

    private func updateDashboardWarmup() {
        guard isLibraryVisible, scenePhase == .active else {
            return
        }

        playbackManager.warmDashboardPage(
            visibleDashboardWarmupCandidates,
            page: selectedPlaylistPage
        )
    }

    private func loveCard(at index: Int) -> some View {
        VStack(spacing: 8) {
            Image(systemName: index.isMultiple(of: 2) ? "heart.fill" : "sparkles")
                .font(.title3)
                .foregroundStyle(ShaudiTheme.accent.opacity(0.72))
            Text(loveMessages[index % loveMessages.count])
                .font(ShaudiTheme.bodyFont(size: 14))
                .foregroundStyle(ShaudiTheme.accent)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(ShaudiTheme.dashboardPlaceholder, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func loadBannerImage() {
        if let storedImage = ArtworkStorage.bannerImage() {
            heroImage = storedImage
            return
        }

        guard let legacyImage = ArtworkStorage.migratedLegacyBannerImage() else {
            heroImage = nil
            return
        }

        do {
            try ArtworkStorage.saveBannerImage(legacyImage)
            heroImage = legacyImage
            ArtworkStorage.clearLegacyBannerStorage()
        } catch {
#if DEBUG
            print("[Artwork] Banner migration failed: \(error.localizedDescription)")
#endif
            heroImage = legacyImage
        }
    }

}

private struct CollectionView: View {
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
        ) != nil || track.channelTitle?.range(
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

private struct LibraryTrackRow: View {
    let track: Track
    let isCurrentlyPlaying: Bool
    let isSelected: Bool
    let isSelectionMode: Bool
    let play: () -> Void
    let toggleSelection: () -> Void
    let showInfo: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if isSelectionMode {
                    toggleSelection()
                } else {
                    play()
                }
            } label: {
                HStack(spacing: 13) {
                    artwork

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(
                                isCurrentlyPlaying
                                    ? ShaudiTheme.bodyFont(size: 17, relativeTo: .headline).weight(.semibold)
                                    : ShaudiTheme.bodyFont(size: 17, relativeTo: .headline)
                            )
                            .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                            .lineLimit(2)

                        if let channelTitle = track.channelTitle, !channelTitle.isEmpty {
                            Text(channelTitle)
                                .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                                .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? ShaudiTheme.accent : ShaudiTheme.dashboardSecondaryText)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(isSelected ? "Selected" : "Not selected")
            } else {
                Menu {
                    Button {
                        showInfo()
                    } label: {
                        Label("Show Info", systemImage: "info.circle")
                    }

                    Button(role: .destructive) {
                        delete()
                    } label: {
                        Label("Delete from Library", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Song actions")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ShaudiTheme.lavender.opacity(0.16))

            Image(systemName: "music.note")
                .font(.headline)
                .foregroundStyle(ShaudiTheme.lavender)
        }
        .frame(width: 42, height: 42)
    }
}

private func mostPlayedTracks(from tracks: [Track]) -> [Track] {
    tracks.sorted { first, second in
        if first.playCount != second.playCount {
            return first.playCount > second.playCount
        }

        if first.totalListenedDuration != second.totalListenedDuration {
            return first.totalListenedDuration > second.totalListenedDuration
        }

        switch (first.lastPlayedAt, second.lastPlayedAt) {
        case let (firstDate?, secondDate?) where firstDate != secondDate:
            return firstDate > secondDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }

        return titleComesBefore(first, second)
    }
}

private func titleComesBefore(_ first: Track, _ second: Track) -> Bool {
    let titleOrder = first.title.localizedCaseInsensitiveCompare(second.title)
    if titleOrder != .orderedSame {
        return titleOrder == .orderedAscending
    }

    return first.youtubeVideoID < second.youtubeVideoID
}

private func deleteTrackFromLibrary(_ track: Track, in modelContext: ModelContext) {
    if let coverID = track.customCoverID {
        ArtworkStorage.deleteTrackCover(for: coverID)
    }

    let containingPlaylists = track.playlists
    for playlist in containingPlaylists {
        playlist.tracks.removeAll { $0 === track }
    }

    modelContext.delete(track)
}

struct ManualTrackAdditionView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var tracks: [Track]

    var body: some View {
        TrackEditorView(
            title: "New Track",
            actionTitle: "Create"
        ) { request in
            guard !tracks.contains(where: { $0.youtubeVideoID == request.youtubeVideo.id }) else {
                return "This YouTube video is already in Library."
            }

            guard let metadata = request.metadata else {
                return "Fetch the YouTube metadata before creating this track."
            }

            modelContext.insert(
                Track(
                    title: metadata.title,
                    youtubeURL: request.youtubeVideo.url,
                    youtubeVideoID: request.youtubeVideo.id,
                    channelTitle: metadata.channelTitle,
                    thumbnailURL: metadata.thumbnailURL,
                    duration: metadata.duration,
                    metadataLastRefreshed: .now
                )
            )

            return nil
        }
    }
}

struct PlaylistArtworkView: View {
    let playlist: Playlist

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ShaudiTheme.dashboardCard

                if
                    let artworkID = playlist.artworkID,
                    let image = ArtworkStorage.playlistImage(for: artworkID)
                {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else if let thumbnailURL = playlist.tracksInPlaybackOrder
                    .first?.thumbnailURL
                {
                    AsyncImage(url: thumbnailURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private var placeholder: some View {
        Image(systemName: "rectangle.stack.fill")
            .font(.title2)
            .foregroundStyle(ShaudiTheme.accent)
    }
}

struct TrackEditorView: View {
    struct SaveRequest {
        let title: String
        let youtubeVideo: YouTubeURLParser.Video
        let metadata: YouTubeMetadata?
    }

    @Environment(\.dismiss) private var dismiss

    let title: String
    let actionTitle: String
    let onSave: (SaveRequest) -> String?

    @State private var trackTitle: String
    @State private var youtubeURLText: String
    @State private var metadata: YouTubeMetadata?
    @State private var previewedURL: URL?
    @State private var isLoadingMetadata = false
    @State private var errorMessage: String?

    private let initialYouTubeURL: URL?
    private let metadataClient = YouTubeMetadataClient()

    init(
        title: String,
        actionTitle: String,
        initialTrackTitle: String = "",
        initialYouTubeURL: URL? = nil,
        onSave: @escaping (SaveRequest) -> String?
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.initialYouTubeURL = initialYouTubeURL
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

    private var isCreating: Bool {
        initialYouTubeURL == nil
    }

    private var requiresMetadataFetch: Bool {
        guard let parsedYouTubeVideo else {
            return true
        }

        return isCreating || parsedYouTubeVideo.url != initialYouTubeURL
    }

    private var hasCurrentPreview: Bool {
        metadata != nil && previewedURL == parsedYouTubeVideo?.url
    }

    private var canSave: Bool {
        guard !trimmedTitle.isEmpty, parsedYouTubeVideo != nil, !isLoadingMetadata else {
            return false
        }

        return !requiresMetadataFetch || hasCurrentPreview
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isCreating {
                    TextField("Track Title", text: $trackTitle)
                }

                Section("YouTube Video") {
                    TextField("YouTube URL", text: $youtubeURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !trimmedURLText.isEmpty && parsedYouTubeVideo == nil {
                        Text("Enter a valid YouTube video URL.")
                            .foregroundStyle(.red)
                    }

                    if requiresMetadataFetch, parsedYouTubeVideo != nil {
                        Button("Fetch Metadata") {
                            fetchMetadata()
                        }
                        .disabled(isLoadingMetadata)
                    }
                }

                metadataState
            }
            .scrollContentBackground(.hidden)
            .background(ShaudiTheme.canvas)
            .tint(ShaudiTheme.accent)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: youtubeURLText) {
                metadata = nil
                previewedURL = nil
                errorMessage = nil

                if isCreating {
                    trackTitle = ""
                }
            }
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

                        let saveError = onSave(
                            SaveRequest(
                                title: trimmedTitle,
                                youtubeVideo: youtubeVideo,
                                metadata: hasCurrentPreview ? metadata : nil
                            )
                        )

                        if let saveError {
                            errorMessage = saveError
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    @ViewBuilder
    private var metadataState: some View {
        if isLoadingMetadata {
            Section {
                HStack {
                    ProgressView()
                    Text("Loading metadata…")
                }
            }
        } else {
            if let metadata, hasCurrentPreview {
                Section("Preview") {
                    YouTubeMetadataView(
                        title: metadata.title,
                        channelTitle: metadata.channelTitle,
                        thumbnailURL: metadata.thumbnailURL,
                        duration: metadata.duration
                    )
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            } else if requiresMetadataFetch, parsedYouTubeVideo != nil, !hasCurrentPreview {
                Section {
                    Text("Ready to fetch metadata.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fetchMetadata() {
        guard let youtubeVideo = parsedYouTubeVideo else {
            errorMessage = "Enter a valid YouTube video URL."
            return
        }

        let requestedURL = youtubeVideo.url
        isLoadingMetadata = true
        errorMessage = nil
        metadata = nil
        previewedURL = nil

        Task {
            do {
                let fetchedMetadata = try await metadataClient.metadata(for: youtubeVideo.id)
                guard parsedYouTubeVideo?.url == requestedURL else {
                    isLoadingMetadata = false
                    return
                }

                metadata = fetchedMetadata
                previewedURL = requestedURL

                if isCreating {
                    trackTitle = fetchedMetadata.title
                }
            } catch {
                guard parsedYouTubeVideo?.url == requestedURL else {
                    isLoadingMetadata = false
                    return
                }

                errorMessage = error.localizedDescription
            }

            isLoadingMetadata = false
        }
    }
}

private struct YouTubeMetadataView: View {
    let title: String
    let channelTitle: String?
    let thumbnailURL: URL?
    let duration: TimeInterval?

    var body: some View {
        if let thumbnailURL {
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 140)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    Label("Thumbnail unavailable", systemImage: "photo")
                        .foregroundStyle(.secondary)
                @unknown default:
                    EmptyView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }

        LabeledContent("Title", value: title)

        if let channelTitle {
            LabeledContent("Channel", value: channelTitle)
        }

        if let duration {
            LabeledContent("Duration", value: YouTubeDuration.formatted(duration))
        }
    }
}

struct TrackDetailView: View {
    @EnvironmentObject private var playbackManager: PlaybackManager

    let track: Track
    let queue: [Track]
    let playbackOrigin: PlaybackOrigin

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var libraryTracks: [Track]

    @State private var isShowingEdit = false
    @State private var isShowingTrimEditor = false

    var body: some View {
        Form {
            if track.thumbnailURL != nil || track.channelTitle != nil || track.duration != nil {
                Section("YouTube Metadata") {
                    YouTubeMetadataView(
                        title: track.title,
                        channelTitle: track.channelTitle,
                        thumbnailURL: track.thumbnailURL,
                        duration: track.duration
                    )

                    if let metadataLastRefreshed = track.metadataLastRefreshed {
                        LabeledContent(
                            "Last Refreshed",
                            value: metadataLastRefreshed.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }
            }

            Section("Track") {
                Text(track.title)
                    .font(ShaudiTheme.scriptFont(size: 28, relativeTo: .title2))
                    .foregroundStyle(ShaudiTheme.accent)
                    .lineLimit(2)

                LabeledContent("YouTube URL", value: track.youtubeURL.absoluteString)
                LabeledContent(
                    "Date Added",
                    value: track.dateAdded.formatted(date: .abbreviated, time: .shortened)
                )
            }

            Section("Playback") {
                if let currentTrack = playbackManager.currentTrack {
                    LabeledContent("Current Track", value: currentTrack.title)
                }

                playbackControls

                if
                    playbackManager.currentTrack != nil,
                    let metrics = playbackManager.startupMetrics
                {
                    startupTiming(metrics)
                }
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
        .scrollContentBackground(.hidden)
        .background(ShaudiTheme.canvas)
        .tint(ShaudiTheme.accent)
        .navigationTitle(track.title)
        .toolbar {
            Menu {
                Button {
                    isShowingEdit = true
                } label: {
                    Label("Edit Track", systemImage: "pencil")
                }

                Button {
                    isShowingTrimEditor = true
                } label: {
                    Label("Trim Song", systemImage: "scissors")
                }
            } label: {
                Label("Track Actions", systemImage: "ellipsis.circle")
            }
        }
        .sheet(isPresented: $isShowingEdit) {
            TrackEditorView(
                title: "Edit Track",
                actionTitle: "Save",
                initialTrackTitle: track.title,
                initialYouTubeURL: track.youtubeURL
            ) { request in
                let isChangingVideo = request.youtubeVideo.id != track.youtubeVideoID

                if isChangingVideo,
                   libraryTracks.contains(where: {
                       $0 !== track && $0.youtubeVideoID == request.youtubeVideo.id
                   }) {
                    return "This YouTube video is already represented by another Library track."
                }

                if track.youtubeURL != request.youtubeVideo.url {
                    guard let metadata = request.metadata else {
                        return "Fetch the YouTube metadata before changing this URL."
                    }

                    track.youtubeURL = request.youtubeVideo.url
                    track.youtubeVideoID = request.youtubeVideo.id
                    track.channelTitle = metadata.channelTitle
                    track.thumbnailURL = metadata.thumbnailURL
                    track.duration = metadata.duration
                    track.metadataLastRefreshed = .now
                    track.playbackStartTime = nil
                    track.playbackEndTime = nil
                }

                track.title = request.title
                return nil
            }
        }
        .sheet(isPresented: $isShowingTrimEditor) {
            TrackTrimEditorView(track: track)
        }
    }

    @ViewBuilder
    private var playbackControls: some View {
        if playbackManager.isCurrentTrack(track) {
            switch playbackManager.state {
            case .idle:
                playButton("Play Track")

            case .resolving:
                HStack {
                    ProgressView()
                    Text("Resolving audio stream…")
                }
                stopButton

            case .loading:
                HStack {
                    ProgressView()
                    Text("Preparing player…")
                }
                stopButton

            case .playing:
                Label("Playing", systemImage: "speaker.wave.2.fill")
                stopButton

            case .paused:
                Label("Paused", systemImage: "pause.fill")
                stopButton

            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                playButton("Retry")
                stopButton
            }
        } else {
            playButton(playbackManager.currentTrack == nil ? "Play Track" : "Play This Track")

            if let currentTrack = playbackManager.currentTrack {
                Text("Playback continues for \(currentTrack.title).")
                    .foregroundStyle(.secondary)
            }
        }

        if playbackManager.currentTrack != nil {
            queueControls
        }
    }

    private func playButton(_ title: String) -> some View {
        Button(title) {
            playbackManager.play(track, in: queue, origin: playbackOrigin)
        }
        .buttonStyle(.borderedProminent)
        .tint(ShaudiTheme.accent)
    }

    private var queueControls: some View {
        HStack {
            Button {
                playbackManager.previousTrack()
            } label: {
                Label("Previous", systemImage: "backward.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(!playbackManager.hasPreviousTrack)
            .font(.headline)
            .foregroundStyle(ShaudiTheme.accent)
            .frame(width: 44, height: 44)
            .background(ShaudiTheme.accent.opacity(0.12), in: Circle())

            Spacer()

            switch playbackManager.state {
            case .playing:
                Button {
                    playbackManager.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .labelStyle(.iconOnly)
                }
                .font(.title3)
                .foregroundStyle(ShaudiTheme.accent)
                .frame(width: 50, height: 50)
                .background(ShaudiTheme.accent.opacity(0.18), in: Circle())

            case .paused:
                Button {
                    playbackManager.resume()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                }
                .font(.title3)
                .foregroundStyle(ShaudiTheme.accent)
                .frame(width: 50, height: 50)
                .background(ShaudiTheme.accent.opacity(0.18), in: Circle())

            case .idle, .resolving, .loading, .failed:
                Image(systemName: "play.fill")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Play unavailable")
                    .frame(width: 50, height: 50)
            }

            Spacer()

            Button {
                playbackManager.nextTrack()
            } label: {
                Label("Next", systemImage: "forward.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(!playbackManager.hasNextTrack)
            .font(.headline)
            .foregroundStyle(ShaudiTheme.accent)
            .frame(width: 44, height: 44)
            .background(ShaudiTheme.accent.opacity(0.12), in: Circle())
        }
        .buttonStyle(.borderless)
    }

    private var stopButton: some View {
        Button("Stop", role: .destructive) {
            playbackManager.stop()
        }
    }

    private func startupTiming(_ metrics: PlaybackManager.StartupMetrics) -> some View {
        DisclosureGroup("Startup Timing (Temporary)") {
            LabeledContent("Stream Source", value: metrics.streamSource)
            LabeledContent(
                "Stream Resolution",
                value: streamResolutionValue(metrics)
            )
            LabeledContent("Player Start", value: metrics.playerStartTime.map(formatTime) ?? "—")
            LabeledContent("Total Start", value: metrics.totalStartTime.map(formatTime) ?? "—")
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        String(format: "%.3f s", time)
    }

    private func streamResolutionValue(_ metrics: PlaybackManager.StartupMetrics) -> String {
        if let time = metrics.streamResolutionTime {
            return formatTime(time)
        }

        return metrics.streamSource == "In-memory cache" ? "Cache hit" : "—"
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
