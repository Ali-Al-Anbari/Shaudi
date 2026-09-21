//
//  PlaylistsView.swift
//  Shaudi
//

import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PlaylistsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appearanceSettings: AppearanceSettings

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @State private var isShowingNewPlaylist = false

    var body: some View {
        NavigationStack {
            playlistList
            .navigationBarTitleDisplayMode(.inline)
        }
        .overlay {
            if isShowingNewPlaylist {
                ShaudiPlaylistNameModal(
                    title: "Create Playlist",
                    isPresented: $isShowingNewPlaylist
                ) { name in
                    modelContext.insert(Playlist(name: name))
                }
            }
        }
        .tint(appearanceSettings.primaryColor)
        .toolbarBackground(ShaudiTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var playlistList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Playlists")
                    .font(ShaudiTheme.scriptFont(size: 34, relativeTo: .title))
                    .foregroundStyle(ShaudiTheme.accent)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 12)

                Button {
                    isShowingNewPlaylist = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ShaudiTheme.accent)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Playlist")
            }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 4)

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
        .background(ShaudiTheme.canvas)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 13) {
            PlaylistArtworkView(playlist: playlist)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(playlist.name)
                .font(ShaudiTheme.bodyFont(size: 17, relativeTo: .headline))
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

struct PlaylistRecommendationRequestState {
    private(set) var activeID: UUID?
    private(set) var signature: [String] = []

    mutating func begin(signature: [String]) -> UUID {
        let id = UUID()
        activeID = id
        self.signature = signature
        return id
    }

    mutating func invalidate() {
        activeID = nil
    }

    func matches(_ id: UUID, signature currentSignature: [String]) -> Bool {
        activeID == id && signature == currentSignature
    }
}

struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var playbackManager: PlaybackManager
    @ObservedObject private var feedbackStore = RecommendationFeedbackStore.shared

    let playlist: Playlist

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var libraryTracks: [Track]

    @State private var isShowingRename = false
    @State private var isShowingAddTracks = false
    @State private var isShowingPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var editingArtworkImage: UIImage?
    @State private var isShowingArtworkCropper = false
    @State private var artworkErrorMessage: String?
    @State private var isPlaylistVisible = false
    @State private var infoTrack: Track?
    @State private var editingTrack: Track?
    @State private var trimmingTrack: Track?
    @State private var playlistTrack: Track?

    @State private var recommendationResult = PlaylistRecommendationResult(
        visibleRecommendations: [],
        spareResolved: [],
        deferredCandidates: []
    )
    @State private var isRecommendationsLoading = false
    @State private var isFindingMore = false
    @State private var recommendationsErrorMessage: String?
    @State private var recommendationTask: Task<Void, Never>?
    @State private var findMoreTask: Task<Void, Never>?
    @State private var recommendationRequest = PlaylistRecommendationRequestState()
    @State private var recommendationRotation = 0
    @State private var manualAddedVideoIDs: Set<String> = []
    @State private var quickAddErrorMessage: String?

    private let warmupTrackLimit = 10

    private struct PlaylistWarmupCandidate {
        enum Source: String {
            case statsPriority = "stats"
            case playbackOrder = "playback-order"
        }

        let videoID: String
        let source: Source
    }

    private var tracks: [Track] {
        playlist.tracksInPlaybackOrder
    }

    private var firstPlayableTrack: Track? {
        tracks.first {
            !$0.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    private var hasPlayableTrack: Bool {
        if let firstPlayableTrack {
            return true
        }
        return false
    }

    private var trackOrderSignature: [String] {
        PlaylistRecommendationService.shared.trackSignature(for: tracks)
    }

    private func playlistWarmupCandidates(
        for playbackOrder: [Track],
        maxCount: Int
    ) -> [PlaylistWarmupCandidate] {
        let indexedTracks = Array(playbackOrder.enumerated())
        let tracksWithHistory = indexedTracks
            .filter {
                $0.element.playCount > 0
                    || $0.element.totalListenedDuration > 0
                    || $0.element.lastPlayedAt != nil
            }
            .sorted { lhs, rhs in
                let leftIndex = lhs.offset
                let leftTrack = lhs.element
                let rightIndex = rhs.offset
                let rightTrack = rhs.element

                if leftTrack.playCount != rightTrack.playCount {
                    return leftTrack.playCount > rightTrack.playCount
                }

                if leftTrack.totalListenedDuration != rightTrack.totalListenedDuration {
                    return leftTrack.totalListenedDuration > rightTrack.totalListenedDuration
                }

                switch (leftTrack.lastPlayedAt, rightTrack.lastPlayedAt) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    break
                }

                return leftIndex < rightIndex
            }

        var seenVideoIDs: Set<String> = []
        var candidates: [PlaylistWarmupCandidate] = []

        func appendCandidate(_ track: Track, source: PlaylistWarmupCandidate.Source) {
            guard candidates.count < maxCount else {
                return
            }

            let videoID = track.youtubeVideoID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !videoID.isEmpty, seenVideoIDs.insert(videoID).inserted else {
                return
            }

            candidates.append(PlaylistWarmupCandidate(videoID: videoID, source: source))
        }

        for indexedTrack in tracksWithHistory {
            appendCandidate(indexedTrack.element, source: .statsPriority)
        }

        for indexedTrack in indexedTracks {
            appendCandidate(indexedTrack.element, source: .playbackOrder)
        }

        return candidates
    }

    private func logPlaylistWarmupCandidates(_ candidates: [PlaylistWarmupCandidate]) {
#if DEBUG
        let descriptions = candidates.map { "\($0.videoID):\($0.source.rawValue)" }
            .joined(separator: ", ")
        print("[PlaylistWarmup] selected=[\(descriptions)]")
#endif
    }

    var body: some View {
        ZStack {
            playlistSurface

            VStack(spacing: 0) {
                PlaylistDetailControlStripView(
                    playlist: playlist,
                    hasPlayableTrack: hasPlayableTrack,
                    isShuffleEnabled: playbackManager.isShuffleEnabled,
                    repeatMode: playbackManager.repeatMode,
                    onPlay: { handlePlaylistPlayButton() },
                    onToggleShuffle: { playbackManager.toggleShuffle() },
                    onToggleRepeat: { playbackManager.toggleRepeatMode() }
                )

                Group {
                    if tracks.isEmpty {
                        ContentUnavailableView(
                            "No Tracks",
                            systemImage: "music.note",
                            description: Text("Add some songs to get recommendations.")
                        )
                    } else {
                        List {
                            ForEach(tracks) { track in
                                let isCurrentlyPlaying = playbackManager.isCurrentTrack(track)
                                    || playbackManager.isCurrentPlayable(track.youtubeVideoID)

                                PlaylistTrackRowView(
                                    track: track,
                                    isCurrentlyPlaying: isCurrentlyPlaying,
                                    onPlay: {
                                        playbackManager.play(
                                            track,
                                            in: tracks,
                                            origin: .playlist(playlist.persistentModelID)
                                        )
                                    },
                                    onShowInfo: { infoTrack = track },
                                    onTrim: { trimmingTrack = track },
                                    onEdit: { editingTrack = track },
                                    onAddToPlaylist: { playlistTrack = track },
                                    onPlayNext: { playbackManager.playNext(track) },
                                    onAddToQueue: { playbackManager.addToQueue(track) },
                                    onRemoveFromPlaylist: {
                                        playlist.tracks.removeAll { $0 === track }
                                    }
                                )
                                .listRowBackground(Color.clear)
                                .listRowInsets(
                                    EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12)
                                )
                                .listRowSeparator(.hidden)
                            }

                            PlaylistRecommendationsSectionView(
                                result: recommendationResult,
                                isLoading: isRecommendationsLoading,
                                isFindingMore: isFindingMore,
                                errorMessage: recommendationsErrorMessage,
                                onRefresh: { handleRefreshRecommendations() },
                                onRetry: { loadRecommendations(forceRefresh: true) },
                                onFindMore: { handleFindMore() },
                                onPlay: { item in handlePlayRecommendation(item) },
                                onAdd: { item in handleAddRecommendation(item) },
                                onPlayNext: { item in
                                    let track = trackForRecommendation(item)
                                    playbackManager.playNext(track)
                                },
                                onAddToQueue: { item in
                                    let track = trackForRecommendation(item)
                                    playbackManager.addToQueue(track)
                                },
                                onAddToPlaylist: { item in
                                    let track = trackForRecommendation(item)
                                    playlistTrack = track
                                },
                                onReject: { item in handleRejectRecommendation(item) }
                            )
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
        }
        .tint(ShaudiTheme.accent)
        .navigationBarTitleDisplayMode(.inline)
        // The navigation controller owns the status-bar/Dynamic Island area. Give
        // it the same surface that starts the sticky playlist header so no parent
        // navigation background shows through above the detail content.
        .toolbarBackground(ShaudiTheme.card, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationDestination(isPresented: Binding(
            get: { infoTrack != nil },
            set: { if !$0 { infoTrack = nil } }
        )) {
            if let infoTrack {
                TrackDetailView(
                    track: infoTrack,
                    queue: tracks,
                    playbackOrigin: .playlist(playlist.persistentModelID)
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
        .onAppear {
            isPlaylistVisible = true
            updatePlaylistWarmup()
            loadRecommendations()
        }
        .onDisappear {
            isPlaylistVisible = false
            playbackManager.cancelPlaylistWarmup()
            invalidateRecommendationRequests()
        }
        .onChange(of: trackOrderSignature) { oldSignature, newSignature in
            updatePlaylistWarmup()
            handleTrackSignatureChange(oldSignature: oldSignature, newSignature: newSignature)
        }
        .onChange(of: feedbackStore.snapshot.excludedArtistNames) {
            invalidateRecommendationRequests()
            let playlistID = String(describing: playlist.persistentModelID)
            recommendationResult = PlaylistRecommendationService.shared.revalidate(
                recommendationResult, for: tracks, playlistID: playlistID
            )
        }
        .onChange(of: playbackManager.isShuffleEnabled) {
            updatePlaylistWarmup()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                updatePlaylistWarmup()
            } else if isPlaylistVisible {
                playbackManager.cancelPlaylistWarmup()
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

                if playlist.artworkID != nil {
                    Button(role: .destructive) {
                        removePlaylistArtwork()
                    } label: {
                        Label("Remove Playlist Photo", systemImage: "trash")
                    }
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
        .alert(
            "Couldn’t Change Playlist Cover",
            isPresented: Binding(
                get: { artworkErrorMessage != nil },
                set: { if !$0 { artworkErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(artworkErrorMessage ?? "Please choose a different image.")
        }
        .alert(
            "Couldn’t Add to Playlist",
            isPresented: Binding(
                get: { quickAddErrorMessage != nil },
                set: { if !$0 { quickAddErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                quickAddErrorMessage = nil
            }
        } message: {
            Text(quickAddErrorMessage ?? "Please try again.")
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
    }


    private var playlistSurface: some View {
        ZStack {
            ShaudiTheme.canvas

            LinearGradient(
                colors: [
                    ShaudiTheme.lavender.opacity(0.09),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }


    private func trackForRecommendation(_ item: ResolvedRecommendation) -> Track {
        TrackPersistence.transientTrack(for: item)
    }

    private func handlePlayRecommendation(_ item: ResolvedRecommendation) {
        let playable = PlayableTrack(
            youtubeVideoID: item.youtubeResult.youtubeVideoID,
            title: item.title,
            channelTitle: item.artist,
            thumbnailURL: item.youtubeResult.thumbnailURL,
            duration: item.youtubeResult.duration
        )
        playbackManager.play(playable, canonicalIdentity: item.songIdentity)
    }

    private func loadRecommendations(forceRefresh: Bool = false) {
        invalidateRecommendationRequests()
        guard !tracks.isEmpty else {
            recommendationResult = PlaylistRecommendationResult(
                visibleRecommendations: [],
                spareResolved: [],
                deferredCandidates: []
            )
            isRecommendationsLoading = false
            recommendationsErrorMessage = nil
            return
        }

        let currentTracks = tracks
        let signature = trackOrderSignature
        let requestID = recommendationRequest.begin(signature: signature)
        let playlistID = String(describing: playlist.persistentModelID)
        let rotation = recommendationRotation
        isRecommendationsLoading = true
        recommendationsErrorMessage = nil

        recommendationTask = Task { @MainActor in
            do {
                let results = try await PlaylistRecommendationService.shared.recommendations(
                    for: currentTracks,
                    playlistID: playlistID,
                    rotation: rotation,
                    forceRefresh: forceRefresh,
                    currentTracks: { tracks },
                    isCurrent: {
                        isPlaylistVisible && recommendationRequest.matches(
                            requestID, signature: trackOrderSignature
                        )
                    }
                )
                guard !Task.isCancelled, isPlaylistVisible,
                      recommendationRequest.matches(requestID, signature: trackOrderSignature)
                else { return }
                recommendationResult = results
                isRecommendationsLoading = false
            } catch is CancellationError {
                guard recommendationRequest.matches(requestID, signature: trackOrderSignature) else { return }
                isRecommendationsLoading = false
            } catch {
                guard !Task.isCancelled, isPlaylistVisible,
                      recommendationRequest.matches(requestID, signature: trackOrderSignature)
                else { return }
                recommendationsErrorMessage = error.localizedDescription
                isRecommendationsLoading = false
            }
        }
    }

    private func handleFindMore() {
        guard !isFindingMore, recommendationResult.canFindMore else { return }
        invalidateRecommendationRequests()
        let currentTracks = tracks
        let signature = trackOrderSignature
        let requestID = recommendationRequest.begin(signature: signature)
        let playlistID = String(describing: playlist.persistentModelID)
        let startingResult = recommendationResult
        isFindingMore = true

        findMoreTask = Task { @MainActor in
            do {
                let updated = try await PlaylistRecommendationService.shared.findMore(
                    for: currentTracks,
                    playlistID: playlistID,
                    currentResult: startingResult,
                    currentTracks: { tracks },
                    isCurrent: {
                        isPlaylistVisible && recommendationRequest.matches(
                            requestID, signature: trackOrderSignature
                        )
                    }
                )
                guard !Task.isCancelled, isPlaylistVisible,
                      recommendationRequest.matches(requestID, signature: trackOrderSignature)
                else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    recommendationResult = updated
                }
                isFindingMore = false
            } catch is CancellationError {
                guard recommendationRequest.matches(requestID, signature: trackOrderSignature) else { return }
                isFindingMore = false
            } catch {
                guard !Task.isCancelled, isPlaylistVisible,
                      recommendationRequest.matches(requestID, signature: trackOrderSignature)
                else { return }
                isFindingMore = false
            }
        }
    }

    private func invalidateRecommendationRequests() {
        recommendationRequest.invalidate()
        recommendationTask?.cancel()
        findMoreTask?.cancel()
        recommendationTask = nil
        findMoreTask = nil
        isRecommendationsLoading = false
        isFindingMore = false
    }

    private func handleRefreshRecommendations() {
        guard !isRecommendationsLoading, !isFindingMore else { return }
        recommendationRotation += 1
        let playlistID = String(describing: playlist.persistentModelID)
        PlaylistRecommendationService.shared.cache.remove(playlistID: playlistID)
        loadRecommendations(forceRefresh: true)
    }

    private func handleAddRecommendation(_ item: ResolvedRecommendation) {
        let videoID = item.youtubeResult.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !videoID.isEmpty else { return }

        guard let _ = PlaylistRecommendationService.shared.addRecommendation(
            item,
            to: playlist,
            in: modelContext,
            existingLibraryTracks: libraryTracks
        ) else {
            #if DEBUG
            print("[PlaylistRecommendations] Quick add failed for videoID: \(videoID)")
            #endif
            quickAddErrorMessage = "Couldn’t add song to playlist. Please try again."
            return
        }

        manualAddedVideoIDs.insert(videoID)

        let playlistID = String(describing: playlist.persistentModelID)
        withAnimation(.easeInOut(duration: 0.2)) {
            recommendationResult = PlaylistRecommendationService.shared.consumeVisibleRecommendation(
                item,
                from: recommendationResult,
                playlistID: playlistID,
                currentTracks: tracks
            )
        }
    }

    private func handleRejectRecommendation(_ item: ResolvedRecommendation) {
        let playlistID = String(describing: playlist.persistentModelID)
        withAnimation(.easeInOut(duration: 0.2)) {
            recommendationResult = PlaylistRecommendationService.shared.rejectRecommendation(
                item,
                from: recommendationResult,
                playlistID: playlistID,
                currentTracks: tracks
            )
        }
    }

    private func handleTrackSignatureChange(oldSignature: [String], newSignature: [String]) {
        invalidateRecommendationRequests()
        let playlistID = String(describing: playlist.persistentModelID)
        recommendationResult = PlaylistRecommendationService.shared.revalidate(
            recommendationResult, for: tracks, playlistID: playlistID
        )
        func videoIDs(in signature: [String]) -> Set<String> {
            Set(signature.map { String($0.prefix { $0 != "\u{1F}" }) })
        }
        let newlyAdded = videoIDs(in: newSignature).subtracting(videoIDs(in: oldSignature))
        if !newlyAdded.isEmpty && newlyAdded.isSubset(of: manualAddedVideoIDs) {
            return
        }
        PlaylistRecommendationService.shared.cache.remove(playlistID: playlistID)
        loadRecommendations(forceRefresh: true)
    }

    private func handlePlaylistPlayButton() {
        playbackManager.restartPlaylist(
            tracks,
            playlistID: playlist.persistentModelID
        )
    }

    private func updatePlaylistWarmup() {
        guard
            isPlaylistVisible,
            scenePhase == .active,
            !playbackManager.hasActivePlaylistQueue(
                for: playlist.persistentModelID
            )
        else {
            return
        }

        let effectiveOrder = playbackManager.effectivePlaylistOrder(
            tracks,
            playlistID: playlist.persistentModelID
        )
        let candidates = playlistWarmupCandidates(
            for: effectiveOrder,
            maxCount: warmupTrackLimit
        )
        logPlaylistWarmupCandidates(candidates)
        playbackManager.warmPlaylist(
            candidates.map(\.videoID),
            playlistID: playlist.persistentModelID
        )
    }

    private func prepareSelectedArtwork(_ selectedPhoto: PhotosPickerItem?) {
        guard let selectedPhoto else {
            return
        }

        Task { @MainActor in
            defer { self.selectedPhoto = nil }
            guard let data = try? await selectedPhoto.loadTransferable(type: Data.self) else {
                artworkErrorMessage = "The selected image could not be loaded."
                return
            }

            let declaresGIF = selectedPhoto.supportedContentTypes.contains {
                $0.conforms(to: .gif)
            }
            if declaresGIF || ArtworkStorage.isGIFData(data) {
                savePlaylistGIFArtwork(data)
                return
            }

            guard let image = UIImage(data: data) else {
                artworkErrorMessage = "The selected image format is not supported."
                return
            }
            editingArtworkImage = image
            isShowingArtworkCropper = true
        }
    }

    private func savePlaylistArtwork(_ image: UIImage) {
        replacePlaylistArtwork { artworkID in
            try ArtworkStorage.savePlaylistImage(image, for: artworkID)
        }
    }

    private func savePlaylistGIFArtwork(_ data: Data) {
        replacePlaylistArtwork { artworkID in
            try ArtworkStorage.savePlaylistGIF(data, for: artworkID)
        }
    }

    private func replacePlaylistArtwork(
        using save: (UUID) throws -> Void
    ) {
        let previousArtworkID = playlist.artworkID
        let newArtworkID = UUID()

        do {
            try save(newArtworkID)
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
            artworkErrorMessage = error.localizedDescription
#if DEBUG
            print("[Artwork] Playlist save failed: \(error.localizedDescription)")
#endif
        }
    }

    private func removePlaylistArtwork() {
        guard let artworkID = playlist.artworkID else {
            return
        }

        playlist.artworkID = nil
        do {
            try modelContext.save()
            ArtworkStorage.deletePlaylistImage(for: artworkID)
        } catch {
            playlist.artworkID = artworkID
            artworkErrorMessage = error.localizedDescription
        }
    }
}
