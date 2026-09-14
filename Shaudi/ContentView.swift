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
        .tint(appearanceSettings.primaryColor)
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
    @ObservedObject var playbackManager: PlaybackManager
    let onOpen: () -> Void

    private var isPlaying: Bool {
        if case .playing = playbackManager.state {
            return true
        }

        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    artwork

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playbackManager.currentPlayableTrack?.title ?? "")
                            .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let channelTitle = playbackManager.currentPlayableTrack?.channelTitle,
                           !channelTitle.isEmpty
                        {
                            Text(channelTitle)
                                .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Now Playing")

            miniPlayerControl(
                systemImage: "backward.fill",
                label: "Previous",
                isEnabled: playbackManager.hasPreviousTrack
            ) {
                playbackManager.previousTrack()
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

            miniPlayerControl(
                systemImage: "forward.fill",
                label: "Next",
                isEnabled: playbackManager.hasNextTrack
            ) {
                playbackManager.nextTrack()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .shaudiGlassSurface(
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
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

    private var artwork: some View {
        Group {
            if let thumbnailURL = playbackManager.currentPlayableTrack?.thumbnailURL {
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

    private var artworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.headline)
            .foregroundStyle(ShaudiTheme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var playbackManager: PlaybackManager
    @State private var playbackTime: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var isShowingCoverPicker = false
    @State private var selectedCover: PhotosPickerItem?
    @State private var customCoverMedia: TrackCoverMedia?
    @State private var dismissOffset: CGFloat = 0

    private let artworkHorizontalInset: CGFloat = 48
    private let maximumArtworkSize: CGFloat = 360
    private let artworkCornerRadius: CGFloat = 24
    private let trackSwipeDistance: CGFloat = 90
    private let trackSwipePredictedDistance: CGFloat = 180

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

                VStack(spacing: 0) {
                    topBar

                    Spacer(minLength: 18)

                    artworkFrame(size: artworkSize)
                        .gesture(playerSwipeGesture)

                    Spacer(minLength: 28)

                    metadata

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
            }
        }
        .offset(y: dismissOffset)
        .tint(ShaudiTheme.accent)
        .photosPicker(
            isPresented: $isShowingCoverPicker,
            selection: $selectedCover,
            matching: .images
        )
        .onAppear {
            reloadCustomCover()
            updatePlaybackTime()
        }
        .onReceive(playbackClock) { _ in
            guard !isScrubbing else {
                return
            }

            updatePlaybackTime()
        }
        .onChange(of: playbackManager.currentPlayableTrack?.id) { _, _ in
            reloadCustomCover()
            updatePlaybackTime()
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

            Spacer()

            Text("NOW PLAYING")
                .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption).weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.76))

            Spacer()

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
        }
        .foregroundStyle(.white)
    }

    private func artworkFrame(size: CGFloat) -> some View {
        artwork
            .frame(width: size, height: size)
            .background(ShaudiTheme.accent.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.42), radius: 24, y: 14)
    }

    private var artwork: some View {
        Group {
            switch customCoverMedia {
            case .image(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .animatedGIF(let image):
                AnimatedTrackCover(image: image)
            case nil:
                normalArtwork
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var normalArtwork: some View {
        Group {
            if let thumbnailURL = playbackManager.currentPlayableTrack?.thumbnailURL {
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

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(playbackManager.currentPlayableTrack?.title ?? "")
                .font(ShaudiTheme.bodyFont(size: 25, relativeTo: .title2).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(playbackManager.currentPlayableTrack?.channelTitle ?? "Unknown artist")
                .font(ShaudiTheme.bodyFont(size: 17, relativeTo: .body))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        playbackManager.seek(to: playbackTime)
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
        guard
            let duration = playbackManager.currentPlayableTrack?.duration,
            duration.isFinite,
            duration > 0
        else {
            return nil
        }

        return duration
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
        guard let currentTime = playbackManager.currentPlaybackTime else {
            return
        }

        if let playbackDuration {
            playbackTime = min(max(0, currentTime), playbackDuration)
        } else {
            playbackTime = max(0, currentTime)
        }
    }

    private var currentTrack: Track? {
        playbackManager.currentTrack
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
    }

    private func universalArtworkSize(for geometry: GeometryProxy) -> CGFloat {
        let availableWidth = max(0, geometry.size.width - artworkHorizontalInset)
        let availableHeight = max(0, geometry.size.height * 0.40)
        return min(availableWidth, availableHeight, maximumArtworkSize)
    }

    private var playerSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)

                if verticalDistance > horizontalDistance, value.translation.height > 0 {
                    dismissOffset = value.translation.height
                }
            }
            .onEnded { value in
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)

                if horizontalDistance > verticalDistance {
                    handleTrackSwipe(value)
                    return
                }

                let projectedOffset = value.predictedEndTranslation.height
                let isVerticalDismiss = value.translation.height > 0
                    && verticalDistance > horizontalDistance
                let shouldDismiss = isVerticalDismiss
                    && (value.translation.height > 140 || projectedOffset > 300)

                guard shouldDismiss else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        dismissOffset = 0
                    }
                    return
                }

                withAnimation(.easeOut(duration: 0.14)) {
                    dismissOffset = max(dismissOffset, 280)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    dismiss()
                }
            }
    }

    private func handleTrackSwipe(_ value: DragGesture.Value) {
        let horizontalTranslation = value.translation.width
        let predictedTranslation = value.predictedEndTranslation.width
        let reachedThreshold = abs(horizontalTranslation) > trackSwipeDistance
            || abs(predictedTranslation) > trackSwipePredictedDistance

        guard reachedThreshold else {
            return
        }

        if horizontalTranslation < 0 {
            playbackManager.nextTrack()
        } else {
            playbackManager.previousTrack()
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

#Preview {
    ContentView()
        .environmentObject(PlaybackManager())
        .modelContainer(for: [Track.self, Playlist.self], inMemory: true)
}
