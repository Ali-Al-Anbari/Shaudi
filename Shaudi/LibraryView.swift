//
//  LibraryView.swift
//  Shaudi
//

import SwiftData
import PhotosUI
import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var tracks: [Track]

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @State private var isShowingNewTrack = false
    @State private var isShowingPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var editingHeroImage: UIImage?
    @State private var isShowingCropEditor = false
    @AppStorage("shaudi.library.heroImage") private var heroImageData = ""
    @AppStorage("shaudi.library.heroOffsetX") private var heroOffsetX = 0.0
    @AppStorage("shaudi.library.heroOffsetY") private var heroOffsetY = 0.0
    @AppStorage("shaudi.library.heroScale") private var heroScale = 1.0

    private let loveMessages = ["made with love", "For my little macaroon", "love lives here", "don't forget bf!!", "you're my favorite", "♡"]

    var body: some View {
        NavigationStack {
            dashboard
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button {
                    isShowingNewTrack = true
                } label: {
                    Label("New Track", systemImage: "plus")
                }
            }
            .photosPicker(isPresented: $isShowingPhotoPicker, selection: $selectedPhoto, matching: .images)
            .onChange(of: selectedPhoto) {
                saveSelectedPhoto()
            }
            .sheet(isPresented: $isShowingCropEditor) {
                if let editingHeroImage {
                    BannerCropEditor(
                        image: editingHeroImage,
                        initialOffset: .zero,
                        initialScale: 1
                    ) { offset, scale in
                        heroImageData = editingHeroImage.jpegData(compressionQuality: 0.82)?.base64EncodedString() ?? heroImageData
                        heroOffsetX = offset.width
                        heroOffsetY = offset.height
                        heroScale = scale
                    }
                }
            }
            .sheet(isPresented: $isShowingNewTrack) {
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
        .safeAreaPadding(.bottom, 84)
    }

    private var heroBanner: some View {
        Button {
            isShowingPhotoPicker = true
        } label: {
            GeometryReader { geometry in
                ZStack(alignment: .topTrailing) {
                    if let image = storedHeroImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(heroScale)
                            .offset(x: heroOffsetX * geometry.size.width, y: heroOffsetY * geometry.size.height)
                    } else {
                        LinearGradient(colors: [ShaudiTheme.lavender.opacity(0.8), ShaudiTheme.accent.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.white.opacity(0.82))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    Image(systemName: "pencil.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, ShaudiTheme.accent)
                        .padding(12)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 148)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: ShaudiTheme.accent.opacity(0.18), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Library poster")
        .accessibilityHint("Choose or reposition a photo")
    }

    private var playlistPager: some View {
        let pageCount = max(1, (playlists.count + 5) / 6)
        return TabView {
            ForEach(0..<pageCount, id: \.self) { page in
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(0..<6, id: \.self) { slot in
                        let playlistIndex = page * 6 + slot
                        if playlistIndex < playlists.count {
                            let playlist = playlists[playlistIndex]
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                playlistCard(playlist)
                            }
                            .buttonStyle(.plain)
                        } else {
                            loveCard(at: playlistIndex)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(height: 270)
        .tabViewStyle(.page(indexDisplayMode: pageCount > 1 ? .automatic : .never))
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
                        NavigationLink {
                            TrackDetailView(track: track, queue: tracks)
                        } label: {
                            trackRow(track)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(ShaudiTheme.dashboardCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .onDelete(perform: deleteTracks)
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
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ShaudiTheme.dashboardCard)
                if let thumbnailURL = playlist.tracks.sorted(by: { $0.dateAdded > $1.dateAdded }).first?.thumbnailURL {
                    AsyncImage(url: thumbnailURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill().clipped()
                        } else {
                            Image(systemName: "rectangle.stack.fill").font(.title2).foregroundStyle(ShaudiTheme.accent)
                        }
                    }
                } else {
                    Image(systemName: "rectangle.stack.fill").font(.title2).foregroundStyle(ShaudiTheme.accent)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(playlist.name)
                .font(ShaudiTheme.bodyFont(size: 15))
                .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                .lineLimit(1)
        }
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

    private var storedHeroImage: UIImage? {
        guard let data = Data(base64Encoded: heroImageData) else { return nil }
        return UIImage(data: data)
    }

    private func saveSelectedPhoto() {
        guard let selectedPhoto else { return }
        Task { @MainActor in
            guard let data = try? await selectedPhoto.loadTransferable(type: Data.self) else { return }
            guard let image = UIImage(data: data), let jpegData = image.jpegData(compressionQuality: 0.82) else { return }
            editingHeroImage = UIImage(data: jpegData)
            isShowingCropEditor = true
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
                        TrackDetailView(track: track, queue: tracks)
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
            modelContext.delete(tracks[index])
        }
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

private struct BannerCropEditor: View {
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let initialOffset: CGSize
    let initialScale: CGFloat
    let onSave: (CGSize, CGFloat) -> Void

    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat
    @State private var didSetInitialOffset = false
    @State private var cropWidth: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1

    private let bannerHeight: CGFloat = 148

    init(image: UIImage, initialOffset: CGSize, initialScale: CGFloat, onSave: @escaping (CGSize, CGFloat) -> Void) {
        self.image = image
        self.initialOffset = initialOffset
        self.initialScale = initialScale
        self.onSave = onSave
        _scale = State(initialValue: max(1, initialScale))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 20) {
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(scale * magnification)
                            .offset(x: offset.width * geometry.size.width + dragTranslation.width,
                                    y: offset.height * bannerHeight + dragTranslation.height)
                    }
                    .frame(width: geometry.size.width, height: bannerHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(dragGesture.simultaneously(with: magnificationGesture))

                    Text("Drag and pinch to frame your banner")
                        .font(ShaudiTheme.bodyFont(size: 16))
                        .foregroundStyle(ShaudiTheme.dashboardSecondaryText)

                    Spacer()
                }
                .padding(.top, 24)
                .onAppear {
                    guard !didSetInitialOffset else { return }
                    cropWidth = geometry.size.width
                    offset = initialOffset
                    scale = max(1, initialScale)
                    didSetInitialOffset = true
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave(offset, scale)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Adjust Banner")
            .navigationBarTitleDisplayMode(.inline)
            .background(ShaudiTheme.dashboardBackground)
        }
        .presentationDragIndicator(.visible)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset.width += value.translation.width / max(1, cropWidth)
                offset.height += value.translation.height / bannerHeight
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($magnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                scale = min(max(scale * value, 1), 4)
            }
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

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var libraryTracks: [Track]

    @State private var isShowingEdit = false

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
                }

                track.title = request.title
                return nil
            }
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
            playbackManager.play(track, in: queue)
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
