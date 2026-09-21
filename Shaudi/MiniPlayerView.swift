//
//  MiniPlayerView.swift
//  Shaudi
//

import SwiftUI

struct MiniPlayerView: View {
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
            .frame(height: 48)
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
#if DEBUG
            if let content = currentPage {
                let artist = miniPlayerArtist(content.artist) ?? ""
                print("[MiniPlayer] title=\"\(content.title)\"")
                print("[MiniPlayer] artist=\"\(artist)\"")
                print("[MiniPlayer] artistEmpty=\(artist.isEmpty)")
            }
#endif
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
            // A saved Track can carry an explicit artist override. Prefer that
            // display identity over the transient playback channel value.
            artist: playbackManager.currentTrack?.displayArtist ?? track.channelTitle,
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
                    .font(.custom("SnellRoundhand", size: 17, relativeTo: .headline))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let artist = miniPlayerArtist(content.artist) {
                    Text(artist)
                        .font(ShaudiTheme.bodyFont(size: 12, relativeTo: .caption))
                        .foregroundStyle(Color.white.opacity(0.84))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func miniPlayerArtist(_ artist: String?) -> String? {
        let trimmed = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
