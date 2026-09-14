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
                sectionHeader("My Collection")
                collection
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
            if tracks.isEmpty {
                ContentUnavailableView("Your Library Is Quiet", systemImage: "music.note.list", description: Text("Add a track to start your collection."))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(tracks) { track in
                        SwipeableDashboardRow(
                            onDelete: {
                                deleteTrack(track)
                            }
                        ) {
                            TrackDetailView(
                                track: track,
                                queue: tracks,
                                playbackOrigin: .library
                            )
                        } label: {
                            trackRow(track)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    ShaudiTheme.dashboardCard,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
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

    private var libraryList: some View {
        List {
            libraryRows
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ShaudiTheme.canvas)
    }

    @ViewBuilder
    private var libraryRows: some View {
        if tracks.isEmpty {
            ContentUnavailableView(
                "Your Library Is Quiet",
                systemImage: "music.note.list",
                description: Text("Add a track to start your collection.")
            )
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(tracks) { track in
                    NavigationLink {
                        TrackDetailView(
                            track: track,
                            queue: tracks,
                            playbackOrigin: .library
                        )
                    } label: {
                        trackRow(track)
                    }
                    .listRowBackground(ShaudiTheme.card)
                    .listRowSeparator(.hidden)
                }
                .onDelete(perform: deleteTracks)
            } header: {
                Text("All Tracks")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ShaudiTheme.lavender)
            }
        }
    }

    private func deleteTracks(at offsets: IndexSet) {
        for index in offsets {
            deleteTrack(tracks[index])
        }
    }

    private func deleteTrack(_ track: Track) {
        if let coverID = track.customCoverID {
            ArtworkStorage.deleteTrackCover(for: coverID)
        }
        modelContext.delete(track)
    }

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ShaudiTheme.lavender.opacity(0.16))

                Image(systemName: "music.note")
                    .font(.headline)
                    .foregroundStyle(ShaudiTheme.lavender)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(ShaudiTheme.bodyFont(size: 17, relativeTo: .headline))
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
        .padding(.vertical, 5)
    }
}

private struct SwipeableDashboardRow<Destination: View, RowLabel: View>: View {
    private let actionWidth: CGFloat = 88
    let onDelete: () -> Void
    let destination: Destination
    let label: RowLabel

    @State private var offset: CGFloat = 0
    @State private var isDeleteRevealed = false

    init(
        onDelete: @escaping () -> Void,
        @ViewBuilder destination: () -> Destination,
        @ViewBuilder label: () -> RowLabel
    ) {
        self.onDelete = onDelete
        self.destination = destination()
        self.label = label()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                withAnimation(.snappy) {
                    offset = 0
                    isDeleteRevealed = false
                }
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(.red, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            NavigationLink {
                destination
            } label: {
                label
            }
            .buttonStyle(.plain)
            .offset(x: offset)
            .simultaneousGesture(swipeGesture)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                let restingOffset = isDeleteRevealed ? -actionWidth : 0
                offset = min(0, max(-actionWidth, restingOffset + value.translation.width))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                let shouldReveal = value.translation.width < -36
                    || value.predictedEndTranslation.width < -actionWidth
                withAnimation(.snappy) {
                    isDeleteRevealed = shouldReveal
                    offset = shouldReveal ? -actionWidth : 0
                }
            }
    }
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
