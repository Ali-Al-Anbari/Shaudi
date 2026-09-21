//
//  NowPlayingView.swift
//  Shaudi
//

import Combine
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

private struct NowPlayingControlFrameKey: PreferenceKey {
    static var defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func nowPlayingControlRegion() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: NowPlayingControlFrameKey.self,
                    value: [proxy.frame(in: .named("NowPlayingGestureSurface"))]
                )
            }
        }
    }
}

struct NowPlayingView: View {
    private enum DragAxis {
        case horizontal
        case vertical
    }

    private struct PageContent {
        let title: String
        let artist: String
        let thumbnailURL: URL?
        let coverMedia: TrackCoverMedia?
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appearanceSettings: AppearanceSettings
    @ObservedObject var playbackManager: PlaybackManager
    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]
    @State private var playbackTime: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var isShowingCoverPicker = false
    @State private var isShowingPlaylistPicker = false
    @State private var selectedCover: PhotosPickerItem?
    @State private var customCoverMedia: TrackCoverMedia?
    @State private var previousPage: PageContent?
    @State private var nextPage: PageContent?
    @State private var dragAxis: DragAxis?
    @State private var horizontalOffset: CGFloat = 0
    @State private var dismissOffset: CGFloat = 0
    @State private var isGestureSettling = false
    @State private var isGestureSuppressed = false
    @State private var controlFrames: [CGRect] = []
    @State private var isShowingQueue = false

    private let artworkHorizontalInset: CGFloat = 48
    private let maximumArtworkSize: CGFloat = 360
    private let artworkCornerRadius: CGFloat = 24
    private let gestureDeadZone: CGFloat = 10
    private let trackSwipeDistance: CGFloat = 80
    private let trackSwipePredictedDistance: CGFloat = 160
    private let dismissDistance: CGFloat = 120
    private let dismissPredictedDistance: CGFloat = 260

    private let playbackClock = Timer.publish(
        every: 0.25,
        on: .main,
        in: .common
    ).autoconnect()

    private var isPlaying: Bool {
        if case .playing = playbackManager.state {
            return true
        }

        return false
    }

    var body: some View {
        ZStack {
            background

            GeometryReader { geometry in
                let artworkSize = universalArtworkSize(for: geometry)
                let pageWidth = max(
                    0,
                    geometry.size.width - artworkHorizontalInset
                )

                VStack(spacing: 0) {
                    topBar

                    Spacer(minLength: 18)

                    pagingArea(
                        artworkSize: artworkSize,
                        pageWidth: pageWidth
                    )

                    Spacer(minLength: 24)

                    progress

                    Spacer(minLength: 20)

                    playbackControls

                    Spacer(minLength: 22)

                    modeControls
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, max(24, geometry.safeAreaInsets.bottom + 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .coordinateSpace(name: "NowPlayingGestureSurface")
                .onPreferenceChange(NowPlayingControlFrameKey.self) { frames in
                    controlFrames = frames
                }
                .simultaneousGesture(
                    playerSwipeGesture(
                        pageWidth: pageWidth,
                        dismissalHeight: geometry.size.height
                    )
                )
            }
        }
        .offset(y: dismissOffset)
        .tint(ShaudiTheme.accent)
        .photosPicker(
            isPresented: $isShowingCoverPicker,
            selection: $selectedCover,
            matching: .images
        )
        .overlay {
            if isShowingPlaylistPicker {
                ShaudiAddToPlaylistModal(
                    isPresented: $isShowingPlaylistPicker,
                    transientTrack: currentTrack,
                    playableTrack: playbackManager.currentPlayableTrack
                )
            }
        }
        .onAppear {
            resetGestureState()
            reloadCustomCover()
            reloadAdjacentPages()
            updatePlaybackTime()
        }
        .onReceive(playbackClock) { _ in
            guard !isScrubbing else {
                return
            }

            updatePlaybackTime()
        }
        .onChange(of: playbackManager.currentPlayableTrack?.id) { _, _ in
            playbackTime = 0
            reloadCustomCover()
            reloadAdjacentPages()
            updatePlaybackTime()
        }
        .onChange(of: playbackManager.isShuffleEnabled) { _, _ in
            reloadAdjacentPages()
        }
        .onChange(of: playbackManager.repeatMode) { _, _ in
            reloadAdjacentPages()
        }
        .onChange(of: queuePreviewSignature) { _, _ in
            reloadAdjacentPages()
        }
        .onChange(of: selectedCover) { _, selection in
            saveSelectedCover(selection)
        }
        .sheet(isPresented: $isShowingQueue) {
            QueueView(playbackManager: playbackManager)
        }
    }

    private var background: some View {
        ZStack {
            ShaudiTheme.dashboardBackground

            LinearGradient(
                colors: [
                    ShaudiTheme.lavender.opacity(0.20),
                    ShaudiTheme.dashboardBackground,
                    ShaudiTheme.accent.opacity(0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .overlay(.black.opacity(0.22))
        .ignoresSafeArea()
    }

    private var topBar: some View {
        ZStack {
            HStack {
                HStack(spacing: 0) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 19, weight: .bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss Now Playing")
                    .nowPlayingControlRegion()

                    Button {
                        isShowingPlaylistPicker = true
                    } label: {
                        Image(
                            systemName: isCurrentTrackInAPlaylist
                                ? "checkmark.rectangle.stack"
                                : "plus.rectangle.on.folder"
                        )
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(playbackManager.currentPlayableTrack == nil)
                    .accessibilityLabel(
                        isCurrentTrackInAPlaylist
                            ? "Manage playlists"
                            : "Add to playlist"
                    )
                    .nowPlayingControlRegion()
                }

                Spacer()

                HStack(spacing: 0) {
                    Button {
                        isShowingQueue = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View Queue")
                    .nowPlayingControlRegion()

                    Menu {
                        if let identity = playbackManager.currentRecommendationIdentity {
                            RecommendationFeedbackButtons(identity: identity) { action in
                                playbackManager.recordRecommendationFeedback(
                                    action,
                                    for: identity
                                )
                            }

                            Divider()
                        }

                        Button {
                            isShowingCoverPicker = true
                        } label: {
                            Label("Change Cover", systemImage: "photo.on.rectangle")
                        }
                        .disabled(currentTrack == nil)

                        if customCoverMedia != nil {
                            Button(role: .destructive) {
                                removeCustomCover()
                            } label: {
                                Label("Remove Custom Cover", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 19, weight: .bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Now Playing options")
                    .nowPlayingControlRegion()
                }
            }

            Text("NOW PLAYING")
                .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption).weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.76))
        }
        .foregroundStyle(.white)
    }

    private func pagingArea(
        artworkSize: CGFloat,
        pageWidth: CGFloat
    ) -> some View {
        ZStack {
            if horizontalOffset > 0, let previousPage {
                nowPlayingPage(previousPage, artworkSize: artworkSize)
                    .offset(x: horizontalOffset - pageWidth)
            }

            if horizontalOffset < 0, let nextPage {
                nowPlayingPage(nextPage, artworkSize: artworkSize)
                    .offset(x: horizontalOffset + pageWidth)
            }

            if let currentPageContent {
                nowPlayingPage(currentPageContent, artworkSize: artworkSize)
                    .offset(x: horizontalOffset)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: artworkSize + 92)
        .contentShape(Rectangle())
        .clipped()
    }

    private func nowPlayingPage(
        _ content: PageContent,
        artworkSize: CGFloat
    ) -> some View {
        VStack(spacing: 28) {
            artworkFrame(content: content, size: artworkSize)
            metadata(content)
        }
        .frame(maxWidth: .infinity)
    }

    private func artworkFrame(content: PageContent, size: CGFloat) -> some View {
        artwork(content)
            .frame(width: size, height: size)
            .background(ShaudiTheme.accent.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.42), radius: 24, y: 14)
    }

    private func artwork(_ content: PageContent) -> some View {
        Group {
            switch content.coverMedia {
            case .image(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .animatedGIF(let image):
                AnimatedTrackCover(image: image)
            case nil:
                normalArtwork(thumbnailURL: content.thumbnailURL)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func normalArtwork(thumbnailURL: URL?) -> some View {
        Group {
            if let thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        artworkPlaceholder
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
    }

    private func metadata(_ content: PageContent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(content.title)
                .font(.custom("Snell Roundhand", size: 29, relativeTo: .title2))
                .foregroundStyle(appearanceSettings.primaryColor)
                .lineLimit(2)
                .minimumScaleFactor(0.72)

            Text(content.artist)
                .font(.custom("Times New Roman", size: 17, relativeTo: .body))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 64, alignment: .top)
    }

    private var progress: some View {
        VStack(spacing: 7) {
            Slider(
                value: Binding(
                    get: { playbackTime },
                    set: { playbackTime = $0 }
                ),
                in: 0...sliderDuration,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        playbackManager.seek(toPlaybackProgressTime: playbackTime)
                    }
                }
            )
            .tint(ShaudiTheme.accent)
            .disabled(playbackDuration == nil)

            HStack {
                Text(YouTubeDuration.formatted(playbackTime))
                Spacer()
                Text(remainingTimeLabel)
            }
            .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption).monospacedDigit())
            .foregroundStyle(.white.opacity(0.62))
        }
        .nowPlayingControlRegion()
    }

    private var playbackControls: some View {
        HStack(spacing: 18) {
            playerControl(
                systemImage: "shuffle",
                label: "Shuffle \(playbackManager.isShuffleEnabled ? "on" : "off")",
                isEnabled: true,
                isActive: playbackManager.isShuffleEnabled
            ) {
                playbackManager.toggleShuffle()
            }

            playerControl(
                systemImage: "backward.fill",
                label: "Previous",
                isEnabled: playbackManager.hasPreviousTrack,
                size: 46
            ) {
                playbackManager.previousTrack()
            }

            playerControl(
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                label: isPlaying ? "Pause" : "Play",
                isEnabled: playbackManager.currentPlayableTrack != nil,
                size: 72,
                isPrimary: true
            ) {
                togglePlayback()
            }

            playerControl(
                systemImage: "forward.fill",
                label: "Next",
                isEnabled: playbackManager.hasNextTrack,
                size: 46
            ) {
                playbackManager.nextTrack()
            }

            playerControl(
                systemImage: playbackManager.repeatMode == .one ? "repeat.1" : "repeat",
                label: "Repeat \(repeatDescription)",
                isEnabled: true,
                isActive: playbackManager.repeatMode != .off
            ) {
                playbackManager.toggleRepeatMode()
            }
        }
        .frame(maxWidth: .infinity)
        .nowPlayingControlRegion()
    }

    private var modeControls: some View {
        Text("Hey Shaudi, I LOVE YOU!!")
            .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .footnote))
            .foregroundStyle(.white.opacity(0.48))
    }

    private func playerControl(
        systemImage: String,
        label: String,
        isEnabled: Bool,
        size: CGFloat = 40,
        isPrimary: Bool = false,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isPrimary ? 27 : 18, weight: .semibold))
                .foregroundStyle(
                    isEnabled
                        ? (isPrimary ? Color.black : (isActive ? ShaudiTheme.accent : .white))
                        : .white.opacity(0.28)
                )
                .frame(width: size, height: size)
                .background(
                    isPrimary
                        ? ShaudiTheme.accent
                        : Color.white.opacity(isActive ? 0.14 : 0.06),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    private var artworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.largeTitle)
            .foregroundStyle(ShaudiTheme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playbackDuration: TimeInterval? {
        playbackManager.currentEffectivePlaybackDuration
    }

    private var sliderDuration: TimeInterval {
        max(playbackDuration ?? 0, 1)
    }

    private var remainingTimeLabel: String {
        guard let playbackDuration else {
            return "—"
        }

        return "−\(YouTubeDuration.formatted(max(0, playbackDuration - playbackTime)))"
    }

    private func togglePlayback() {
        switch playbackManager.state {
        case .playing:
            playbackManager.pause()
        case .paused:
            playbackManager.resume()
        case .idle, .resolving, .loading, .failed:
            break
        }
    }

    private func updatePlaybackTime() {
        guard let currentTime = playbackManager.currentPlaybackProgressTime else {
            playbackTime = 0
            return
        }

        playbackTime = min(max(0, currentTime), playbackDuration ?? 0)
    }

    private var currentTrack: Track? {
        playbackManager.currentTrack
    }

    private var currentPlaybackVideoID: String? {
        let videoID = playbackManager.currentPlayableTrack?.youtubeVideoID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return videoID.isEmpty ? nil : videoID
    }

    private var isCurrentTrackInAPlaylist: Bool {
        guard let currentPlaybackVideoID else {
            return false
        }

        return playlists.contains { playlist in
            playlist.tracks.contains {
                $0.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
                    == currentPlaybackVideoID
            }
        }
    }

    private var queuePreviewSignature: [String] {
        playbackManager.queue.map(\.youtubeVideoID)
            + ["index:\(playbackManager.currentIndex ?? -1)"]
    }

    private var currentPageContent: PageContent? {
        guard let track = playbackManager.currentPlayableTrack else {
            return nil
        }

        return PageContent(
            title: track.title,
            artist: track.channelTitle ?? "Unknown artist",
            thumbnailURL: track.thumbnailURL,
            coverMedia: customCoverMedia
        )
    }

    private func pageContent(for track: Track?) -> PageContent? {
        guard let track else {
            return nil
        }

        let coverMedia = track.customCoverID.flatMap {
            ArtworkStorage.trackCover(for: $0)
        }

        return PageContent(
            title: track.displayTitle,
            artist: track.displayArtist ?? "Unknown artist",
            thumbnailURL: track.thumbnailURL,
            coverMedia: coverMedia
        )
    }

    private func reloadAdjacentPages() {
        previousPage = pageContent(for: playbackManager.previousQueueTrack)
        nextPage = pageContent(for: playbackManager.nextQueueTrack)
    }

    private func reloadCustomCover() {
        guard let coverID = currentTrack?.customCoverID else {
            customCoverMedia = nil
            return
        }

        customCoverMedia = ArtworkStorage.trackCover(for: coverID)
    }

    private func saveSelectedCover(_ selection: PhotosPickerItem?) {
        guard let selection else {
            return
        }

        Task { @MainActor in
            defer { selectedCover = nil }
            guard let data = try? await selection.loadTransferable(type: Data.self) else {
                return
            }

            do {
                guard let track = currentTrack else {
                    return
                }

                let coverID = track.customCoverID ?? UUID()
                try ArtworkStorage.saveTrackCover(data: data, for: coverID)
                track.customCoverID = coverID
                reloadCustomCover()
                reloadAdjacentPages()
            } catch {
#if DEBUG
                print("[Artwork] Track cover save failed: \(error.localizedDescription)")
#endif
            }
        }
    }

    private func removeCustomCover() {
        guard let track = currentTrack, let coverID = track.customCoverID else {
            return
        }

        ArtworkStorage.deleteTrackCover(for: coverID)
        track.customCoverID = nil
        customCoverMedia = nil
        reloadAdjacentPages()
    }

    private func universalArtworkSize(for geometry: GeometryProxy) -> CGFloat {
        let availableWidth = max(0, geometry.size.width - artworkHorizontalInset)
        let availableHeight = max(0, geometry.size.height * 0.40)
        return min(availableWidth, availableHeight, maximumArtworkSize)
    }

    private func playerSwipeGesture(
        pageWidth: CGFloat,
        dismissalHeight: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isGestureSettling else {
                    return
                }

                if dragAxis == nil,
                    (isScrubbing || controlFrames.contains(where: { $0.contains(value.startLocation) }))
                {
                    isGestureSuppressed = true
                }
                guard !isGestureSuppressed, !isScrubbing else {
                    return
                }

                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)

                if dragAxis == nil {
                    guard max(horizontalDistance, verticalDistance) >= gestureDeadZone else {
                        return
                    }

                    dragAxis = horizontalDistance > verticalDistance
                        ? .horizontal
                        : .vertical
                }

                switch dragAxis {
                case .horizontal:
                    dismissOffset = 0
                    let translation = value.translation.width
                    let hasDestination = translation < 0
                        ? nextPage != nil
                        : previousPage != nil
                    horizontalOffset = hasDestination
                        ? translation
                        : resistedHorizontalOffset(translation)
                case .vertical:
                    horizontalOffset = 0
                    dismissOffset = max(0, value.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { value in
                if isGestureSuppressed || isScrubbing {
                    resetGestureState()
                    return
                }
                guard !isGestureSettling else {
                    return
                }

                switch dragAxis {
                case .horizontal:
                    finishHorizontalDrag(value, pageWidth: pageWidth)
                case .vertical:
                    finishVerticalDrag(value, dismissalHeight: dismissalHeight)
                case nil:
                    springBackToRest()
                }
            }
    }

    private func finishHorizontalDrag(
        _ value: DragGesture.Value,
        pageWidth: CGFloat
    ) {
        let translation = value.translation.width
        let predictedTranslation = value.predictedEndTranslation.width
        let direction = abs(translation) >= gestureDeadZone
            ? translation
            : predictedTranslation
        let destinationExists = direction < 0
            ? nextPage != nil
            : previousPage != nil
        let shouldComplete = destinationExists
            && (abs(translation) >= trackSwipeDistance
                || abs(predictedTranslation) >= trackSwipePredictedDistance)

        guard shouldComplete else {
            springBackToRest()
            return
        }

        isGestureSettling = true
        let isMovingToNext = direction < 0
        let destinationOffset = isMovingToNext ? -pageWidth : pageWidth

        withAnimation(
            .easeInOut(duration: 0.22),
            completionCriteria: .logicallyComplete
        ) {
            horizontalOffset = destinationOffset
        } completion: {
            if isMovingToNext {
                playbackManager.nextTrack()
            } else {
                playbackManager.previousTrack()
            }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                horizontalOffset = 0
                dismissOffset = 0
                dragAxis = nil
                isGestureSettling = false
                isGestureSuppressed = false
            }
        }
    }

    private func finishVerticalDrag(
        _ value: DragGesture.Value,
        dismissalHeight: CGFloat
    ) {
        let downwardTranslation = value.translation.height
        let predictedTranslation = value.predictedEndTranslation.height
        let shouldDismiss = downwardTranslation > 0
            && (downwardTranslation >= dismissDistance
                || predictedTranslation >= dismissPredictedDistance)

        guard shouldDismiss else {
            springBackToRest()
            return
        }

        isGestureSettling = true
        withAnimation(
            .easeOut(duration: 0.22),
            completionCriteria: .logicallyComplete
        ) {
            dismissOffset = max(dismissalHeight + 80, dismissOffset)
        } completion: {
            dismiss()
        }
    }

    private func springBackToRest() {
        isGestureSettling = true
        withAnimation(
            .spring(response: 0.36, dampingFraction: 0.84),
            completionCriteria: .logicallyComplete
        ) {
            horizontalOffset = 0
            dismissOffset = 0
        } completion: {
            dragAxis = nil
            isGestureSettling = false
            isGestureSuppressed = false
        }
    }

    private func resistedHorizontalOffset(_ translation: CGFloat) -> CGFloat {
        translation * 0.16
    }

    private func resetGestureState() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            horizontalOffset = 0
            dismissOffset = 0
            dragAxis = nil
            isGestureSettling = false
            isGestureSuppressed = false
        }
    }

    private var repeatDescription: String {
        switch playbackManager.repeatMode {
        case .off:
            return "off"
        case .playlist:
            return "playlist"
        case .one:
            return "one"
        }
    }
}

private struct AnimatedTrackCover: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.image = image
        imageView.startAnimating()
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        guard imageView.image !== image else {
            return
        }

        imageView.image = image
        imageView.startAnimating()
    }
}
