//
//  ContentView.swift
//  Shaudi
//
//  Created by Ali Al Anbari on 9/10/26.
//

import Combine
import SwiftUI
import SwiftData
import PhotosUI
import UIKit

private enum RootTab: Hashable {
    case library
    case search
    case playlists
    case settings
}

private struct ShaudiGlassSurface<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    let tint: Color?
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if let tint {
                content.glassEffect(
                    isInteractive
                        ? .regular.tint(tint).interactive()
                        : .regular.tint(tint),
                    in: shape
                )
            } else {
                content.glassEffect(
                    isInteractive ? .regular.interactive() : .regular,
                    in: shape
                )
            }
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.12), in: shape)
                .overlay {
                    shape.stroke(.white.opacity(0.24), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        }
    }
}

private extension View {
    func shaudiGlassSurface<SurfaceShape: Shape>(
        in shape: SurfaceShape,
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            ShaudiGlassSurface(
                shape: shape,
                tint: tint,
                isInteractive: isInteractive
            )
        )
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var appearanceSettings: AppearanceSettings
    @State private var selectedTab: RootTab = .library
    @State private var isShowingNowPlaying = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                LibraryView()
                    .tag(RootTab.library)

                SearchView()
                    .tag(RootTab.search)

                PlaylistsView()
                    .tag(RootTab.playlists)

                SettingsView()
                    .tag(RootTab.settings)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if playbackManager.currentPlayableTrack != nil {
                MiniPlayerView(
                    playbackManager: playbackManager,
                    onOpen: { isShowingNowPlaying = true }
                )
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 6)
            }

            RootTabBar(selectedTab: $selectedTab)
        }
        .fullScreenCover(isPresented: $isShowingNowPlaying) {
            NowPlayingView(playbackManager: playbackManager)
                .presentationBackground(.clear)
        }
        // This is the surface behind every tab and its NavigationStack.  Keeping it
        // safe-area-filling prevents transparent navigation regions from revealing
        // the system's default black window background.
        .background(ShaudiTheme.dashboardBackground.ignoresSafeArea())
        .tint(appearanceSettings.primaryColor)
        .onAppear {
            playbackManager.configureListeningHistory(modelContext: modelContext)
        }
        .onChange(of: playbackManager.playbackStartEvent) { _, event in
            recordRecentlyPlayedPlaylist(for: event)
        }
    }

    private func recordRecentlyPlayedPlaylist(
        for event: PlaybackManager.PlaybackStartEvent?
    ) {
        guard
            let event,
            case .playlist(let playlistID) = event.origin
        else {
            return
        }

        do {
            let playlists = try modelContext.fetch(FetchDescriptor<Playlist>())
            guard let playlist = playlists.first(where: {
                $0.persistentModelID == playlistID
            }) else {
                return
            }

            playlist.lastPlayedAt = .now
            try modelContext.save()

#if DEBUG
            print("[RecentlyPlayed] updated playlist=\(playlistID) track=\(event.trackID)")
#endif
        } catch {
#if DEBUG
            print("[RecentlyPlayed] update failed: \(error.localizedDescription)")
#endif
        }
    }
}

private struct RootTabBar: View {
    @Binding var selectedTab: RootTab
    @EnvironmentObject private var appearanceSettings: AppearanceSettings

    var body: some View {
        HStack(spacing: 4) {
            tabButton(.library, title: "Library", systemImage: "music.note.house")
            tabButton(.search, title: "Search", systemImage: "magnifyingglass")
            tabButton(.playlists, title: "Playlists", systemImage: "music.note.list")
            tabButton(.settings, title: "Settings", systemImage: "gearshape.fill")
        }
        .padding(6)
        .shaudiGlassSurface(in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .safeAreaPadding(.bottom, 8)
    }

    private func tabButton(
        _ tab: RootTab,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))

                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .background {
                if selectedTab == tab {
                    Color.clear
                        .shaudiGlassSurface(
                            in: Capsule(),
                            tint: appearanceSettings.primaryColor,
                            isInteractive: true
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            selectedTab == tab
                ? Color.black
                : Color.white.opacity(0.72)
        )
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }
}

private struct MiniPlayerView: View {
    private enum DragAxis: Equatable {
        case horizontal
        case vertical
    }

    private struct PageContent {
        let title: String
        let artist: String?
        let thumbnailURL: URL?
    }

    @ObservedObject var playbackManager: PlaybackManager
    let onOpen: () -> Void
    @State private var dragAxis: DragAxis?
    @State private var horizontalOffset: CGFloat = 0
    @State private var isGestureSettling = false

    private let gestureDeadZone: CGFloat = 10
    private let swipeDistance: CGFloat = 64
    private let swipePredictedDistance: CGFloat = 120

    private var isPlaying: Bool {
        if case .playing = playbackManager.state {
            return true
        }

        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                let pageWidth = max(1, geometry.size.width)

                ZStack {
                    if horizontalOffset > 0, let previousPage {
                        miniPlayerPage(previousPage)
                            .offset(x: horizontalOffset - pageWidth)
                    }

                    if horizontalOffset < 0, let nextPage {
                        miniPlayerPage(nextPage)
                            .offset(x: horizontalOffset + pageWidth)
                    }

                    if let currentPage {
                        miniPlayerPage(currentPage)
                            .offset(x: horizontalOffset)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .clipped()
                .onTapGesture {
                    guard !isGestureSettling, dragAxis == nil else {
                        return
                    }
                    onOpen()
                }
                .simultaneousGesture(miniPlayerSwipeGesture(pageWidth: pageWidth))
            }
            .frame(height: 44)
            .accessibilityLabel("Open Now Playing")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: "Previous track") {
                if playbackManager.hasPreviousTrack {
                    playbackManager.previousTrack()
                }
            }
            .accessibilityAction(named: "Next track") {
                if playbackManager.hasNextTrack {
                    playbackManager.nextTrack()
                }
            }

            miniPlayerControl(
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                label: isPlaying ? "Pause" : "Play",
                isEnabled: playbackManager.currentPlayableTrack != nil
            ) {
                switch playbackManager.state {
                case .playing:
                    playbackManager.pause()
                case .paused:
                    playbackManager.resume()
                case .idle, .resolving, .loading, .failed:
                    break
                }
            }

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .shaudiGlassSurface(
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .onChange(of: playbackManager.currentPlayableTrack?.id) { _, _ in
            resetMiniPlayerGesture()
        }
    }

    private func miniPlayerControl(
        systemImage: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    isEnabled
                        ? ShaudiTheme.accent
                        : ShaudiTheme.accent.opacity(0.35)
                )
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    private var currentPage: PageContent? {
        guard let track = playbackManager.currentPlayableTrack else {
            return nil
        }
        return PageContent(
            title: track.title,
            artist: track.channelTitle,
            thumbnailURL: track.thumbnailURL
        )
    }

    private var previousPage: PageContent? {
        pageContent(for: playbackManager.previousQueueTrack)
    }

    private var nextPage: PageContent? {
        pageContent(for: playbackManager.nextQueueTrack)
    }

    private func pageContent(for track: Track?) -> PageContent? {
        guard let track else {
            return nil
        }
        return PageContent(
            title: track.displayTitle,
            artist: track.displayArtist,
            thumbnailURL: track.thumbnailURL
        )
    }

    private func miniPlayerPage(_ content: PageContent) -> some View {
        HStack(spacing: 12) {
            artwork(thumbnailURL: content.thumbnailURL)

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let artist = content.artist, !artist.isEmpty {
                    Text(artist)
                        .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func artwork(thumbnailURL: URL?) -> some View {
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
        .frame(width: 44, height: 44)
        .background(ShaudiTheme.accent.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func miniPlayerSwipeGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: gestureDeadZone)
            .onChanged { value in
                guard !isGestureSettling else {
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
                guard dragAxis == .horizontal else {
                    return
                }

                let translation = value.translation.width
                let hasDestination = translation < 0
                    ? nextPage != nil
                    : previousPage != nil
                horizontalOffset = hasDestination
                    ? translation
                    : translation * 0.16
            }
            .onEnded { value in
                guard !isGestureSettling else {
                    return
                }
                guard dragAxis == .horizontal else {
                    resetMiniPlayerGesture()
                    return
                }

                let translation = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let direction = abs(translation) >= gestureDeadZone ? translation : predicted
                let destinationExists = direction < 0
                    ? nextPage != nil
                    : previousPage != nil
                let shouldComplete = destinationExists
                    && (abs(translation) >= swipeDistance
                        || abs(predicted) >= swipePredictedDistance)

                guard shouldComplete else {
                    springMiniPlayerBack()
                    return
                }

                isGestureSettling = true
                let movesToNext = direction < 0
                withAnimation(
                    .easeInOut(duration: 0.22),
                    completionCriteria: .logicallyComplete
                ) {
                    horizontalOffset = movesToNext ? -pageWidth : pageWidth
                } completion: {
                    if movesToNext {
                        playbackManager.nextTrack()
                    } else {
                        playbackManager.previousTrack()
                    }
                    resetMiniPlayerGesture()
                }
            }
    }

    private func springMiniPlayerBack() {
        isGestureSettling = true
        withAnimation(
            .spring(response: 0.34, dampingFraction: 0.84),
            completionCriteria: .logicallyComplete
        ) {
            horizontalOffset = 0
        } completion: {
            dragAxis = nil
            isGestureSettling = false
        }
    }

    private func resetMiniPlayerGesture() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            horizontalOffset = 0
            dragAxis = nil
            isGestureSettling = false
        }
    }

    private var artworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.headline)
            .foregroundStyle(ShaudiTheme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

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

private struct NowPlayingView: View {
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
        .sheet(isPresented: $isShowingPlaylistPicker) {
            NowPlayingPlaylistPicker(
                transientTrack: currentTrack,
                playableTrack: playbackManager.currentPlayableTrack
            )
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
        HStack {
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

            Spacer()

            Text("NOW PLAYING")
                .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption).weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.76))

            Spacer()

            HStack(spacing: 0) {
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

                Menu {
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

private struct NowPlayingPlaylistPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]
    @Query(sort: \Track.dateAdded, order: .reverse)
    private var libraryTracks: [Track]

    let transientTrack: Track?
    let playableTrack: PlayableTrack?

    @State private var isShowingNewPlaylist = false

    var body: some View {
        NavigationStack {
            List {
                Section("Playlists") {
                    if playlists.isEmpty {
                        Text("No playlists yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(playlists) { playlist in
                            Button {
                                addCurrentTrack(to: playlist)
                            } label: {
                                HStack {
                                    Text(playlist.name)
                                    Spacer()
                                    if containsCurrentTrack(in: playlist) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(ShaudiTheme.accent)
                                    } else {
                                        Image(systemName: "plus.circle")
                                            .foregroundStyle(ShaudiTheme.accent)
                                    }
                                }
                            }
                            .disabled(containsCurrentTrack(in: playlist))
                        }
                    }
                }

                Section {
                    Button {
                        isShowingNewPlaylist = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ShaudiTheme.canvas)
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isShowingNewPlaylist) {
                PlaylistNameEditor(
                    title: "New Playlist",
                    actionTitle: "Create"
                ) { name in
                    let playlist = Playlist(name: name)
                    modelContext.insert(playlist)
                    addCurrentTrack(to: playlist)
                    isShowingNewPlaylist = false
                }
            }
        }
    }

    private var currentVideoID: String? {
        let videoID = playableTrack?.youtubeVideoID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return videoID.isEmpty ? nil : videoID
    }

    private func containsCurrentTrack(in playlist: Playlist) -> Bool {
        guard let currentVideoID else {
            return false
        }

        return playlist.tracks.contains {
            $0.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
                == currentVideoID
        }
    }

    private func addCurrentTrack(to playlist: Playlist) {
        guard
            !containsCurrentTrack(in: playlist),
            let track = persistentCurrentTrack()
        else {
            return
        }

        playlist.tracks.append(track)
        try? modelContext.save()
    }

    private func persistentCurrentTrack() -> Track? {
        guard let currentVideoID else {
            return nil
        }

        if let existingTrack = libraryTracks.first(where: {
            $0.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
                == currentVideoID
        }) {
            return existingTrack
        }

        if let transientTrack {
            modelContext.insert(transientTrack)
            return transientTrack
        }

        guard let playableTrack else {
            return nil
        }

        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: currentVideoID)]
        let track = Track(
            title: playableTrack.title,
            youtubeURL: components.url!,
            youtubeVideoID: currentVideoID,
            channelTitle: playableTrack.channelTitle,
            thumbnailURL: playableTrack.thumbnailURL,
            duration: playableTrack.duration,
            metadataLastRefreshed: .now,
            playbackStartTime: playableTrack.playbackStartTime,
            playbackEndTime: playableTrack.playbackEndTime
        )
        modelContext.insert(track)
        return track
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

#Preview {
    ContentView()
        .environmentObject(PlaybackManager())
        .modelContainer(for: [Track.self, Playlist.self], inMemory: true)
}
