//
//  LibraryView.swift
//  Shaudi
//

import SwiftData
import SwiftUI
import UIKit
import PhotosUI

struct LibraryView: View {
    private struct PlaylistPageSlot: Identifiable {
        let id: String
        let playlist: Playlist?
        let fillerIndex: Int
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var appearanceSettings: AppearanceSettings

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var tracks: [Track]

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @State private var heroMedia: BannerMedia?
    @State private var selectedPlaylistPage = 0
    @State private var dashboardContentWidth: CGFloat = 360
    @State private var isLibraryVisible = false
    @State private var isSelectingTracks = false
    @State private var selectedTrackIDs: Set<PersistentIdentifier> = []
    @State private var isShowingDeleteConfirmation = false
    @State private var infoTrack: Track?
    @State private var editingTrack: Track?
    @State private var trimmingTrack: Track?
    @State private var playlistTrack: Track?
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
        .tint(appearanceSettings.primaryColor)
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroBanner
                    .scaleEffect(1.05)
                    .padding(.vertical, 8)
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
                if let heroMedia {
                    bannerContent(heroMedia, in: geometry.size)
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

    @ViewBuilder
    private func bannerContent(
        _ media: BannerMedia,
        in viewportSize: CGSize
    ) -> some View {
        switch media {
        case .image(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: viewportSize.width, height: viewportSize.height)
                .clipped()
        case .animatedGIF(let image, let crop):
            let baseSize = ArtworkCrop.baseImageSize(for: image.size, in: viewportSize)
            let effectiveScale = max(1, crop.scale)
            let scaledSize = CGSize(
                width: baseSize.width * effectiveScale,
                height: baseSize.height * effectiveScale
            )
            let offset = crop.clampedOffset(
                scaledSize: scaledSize,
                viewportSize: viewportSize
            )

            AnimatedPlaylistCoverImage(
                image: image,
                showsFirstFrameOnly: reduceMotion
            )
            .frame(width: baseSize.width, height: baseSize.height)
            .scaleEffect(effectiveScale)
            .offset(offset)
            .frame(width: viewportSize.width, height: viewportSize.height)
            .clipped()
        }
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(ShaudiTheme.scriptFont(size: 34, relativeTo: .title))
            .foregroundStyle(ShaudiTheme.accent)
            .accessibilityAddTraits(.isHeader)
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        VStack(alignment: .center, spacing: playlistArtworkTitleSpacing) {
            playlistArtwork(playlist)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(playlist.name)
                .font(ShaudiTheme.bodyFont(size: 15))
                .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(
                    maxWidth: .infinity,
                    minHeight: playlistTitleHeight,
                    maxHeight: playlistTitleHeight,
                    alignment: .top
                )
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
        if let storedMedia = ArtworkStorage.bannerMedia() {
            heroMedia = storedMedia
            return
        }

        guard let legacyImage = ArtworkStorage.migratedLegacyBannerImage() else {
            heroMedia = nil
            return
        }

        do {
            try ArtworkStorage.saveBannerImage(legacyImage)
            heroMedia = .image(legacyImage)
            ArtworkStorage.clearLegacyBannerStorage()
        } catch {
#if DEBUG
            print("[Artwork] Banner migration failed: \(error.localizedDescription)")
#endif
            heroMedia = .image(legacyImage)
        }
    }

}
