//
//  PlaylistDetailComponents.swift
//  Shaudi
//

import SwiftUI

struct PlaylistDetailControlStripView: View {
    let playlist: Playlist
    let hasPlayableTrack: Bool
    let isShuffleEnabled: Bool
    let repeatMode: PlaybackManager.RepeatMode
    let onPlay: () -> Void
    let onToggleShuffle: () -> Void
    let onToggleRepeat: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onPlay()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(ShaudiTheme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasPlayableTrack)
            .opacity(hasPlayableTrack ? 1 : 0.45)
            .accessibilityLabel("Start Playlist")

            PlaylistArtworkView(playlist: playlist)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            Text(playlist.name)
                .font(ShaudiTheme.scriptFont(size: 25, relativeTo: .title3))
                .foregroundStyle(ShaudiTheme.accent)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 4)

            playbackModeButton(
                title: "Shuffle",
                systemImage: "shuffle",
                isActive: isShuffleEnabled
            ) {
                onToggleShuffle()
            }

            playbackModeButton(
                title: "Repeat",
                systemImage: repeatMode == .one ? "repeat.1" : "repeat",
                isActive: repeatMode != .off,
                stateDescription: repeatModeDescription
            ) {
                onToggleRepeat()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            LinearGradient(
                colors: [
                    ShaudiTheme.card,
                    ShaudiTheme.card.opacity(0.62),
                    ShaudiTheme.canvas.opacity(0.12)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func playbackModeButton(
        title: String,
        systemImage: String,
        isActive: Bool,
        stateDescription: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? ShaudiTheme.accent : Color.secondary)
                .frame(width: 38, height: 38)
                .background(
                    isActive ? ShaudiTheme.accent.opacity(0.16) : Color.clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(stateDescription ?? (isActive ? "On" : "Off"))
    }

    private var repeatModeDescription: String {
        switch repeatMode {
        case .off:
            return "Off"
        case .playlist:
            return "Playlist"
        case .one:
            return "One song"
        }
    }
}

struct PlaylistTrackRowView: View {
    let track: Track
    let isCurrentlyPlaying: Bool
    let onPlay: () -> Void
    let onShowInfo: () -> Void
    let onTrim: () -> Void
    let onEdit: () -> Void
    let onAddToPlaylist: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onRemoveFromPlaylist: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onPlay()
            } label: {
                HStack(spacing: 13) {
                    trackArtwork(track)

                    Text(track.displayTitle)
                        .font(
                            isCurrentlyPlaying
                                ? ShaudiTheme.bodyFont(size: 17, relativeTo: .headline).weight(.semibold)
                                : ShaudiTheme.bodyFont(size: 17, relativeTo: .headline)
                        )
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    onShowInfo()
                } label: {
                    Label("Show Info", systemImage: "info.circle")
                }

                Button {
                    onTrim()
                } label: {
                    Label("Trim Song", systemImage: "scissors")
                }

                Button {
                    onEdit()
                } label: {
                    Label("Edit Song", systemImage: "pencil")
                }

                Button {
                    onAddToPlaylist()
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }

                Button {
                    onPlayNext()
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    onAddToQueue()
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus.fill")
                }

                Button(role: .destructive) {
                    onRemoveFromPlaylist()
                } label: {
                    Label("Remove from Playlist", systemImage: "minus.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Song actions")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(
            isCurrentlyPlaying
                ? ShaudiTheme.accent.opacity(0.16)
                : ShaudiTheme.card.opacity(0.58),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func trackArtwork(_ track: Track) -> some View {
        Group {
            if let thumbnailURL = track.thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        trackArtworkPlaceholder
                    }
                }
            } else {
                trackArtworkPlaceholder
            }
        }
        .frame(width: 44, height: 44)
        .background(ShaudiTheme.lavender.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var trackArtworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.headline)
            .foregroundStyle(ShaudiTheme.lavender)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlaylistRecommendationsSectionView: View {
    let result: PlaylistRecommendationResult
    let isLoading: Bool
    let isFindingMore: Bool
    let errorMessage: String?
    let onRefresh: () -> Void
    let onRetry: () -> Void
    let onFindMore: () -> Void
    let onPlay: (ResolvedRecommendation) -> Void
    let onAdd: (ResolvedRecommendation) -> Void
    let onPlayNext: (ResolvedRecommendation) -> Void
    let onAddToQueue: (ResolvedRecommendation) -> Void
    let onAddToPlaylist: (ResolvedRecommendation) -> Void
    let onReject: (ResolvedRecommendation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recommended for this playlist")
                    .font(ShaudiTheme.bodyFont(size: 19, relativeTo: .headline).weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isLoading ? ShaudiTheme.accent.opacity(0.4) : ShaudiTheme.accent)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLoading || isFindingMore)
                .accessibilityLabel("Refresh recommendations")
            }
            .padding(.horizontal, 4)
            .padding(.top, 16)

            if isLoading && result.visibleRecommendations.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(ShaudiTheme.accent)
                    Text("Finding recommendations…")
                        .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
            } else if errorMessage != nil && result.visibleRecommendations.isEmpty {
                VStack(spacing: 6) {
                    Text("Couldn’t load recommendations.")
                        .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)

                    Button("Retry") {
                        onRetry()
                    }
                    .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .footnote).weight(.semibold))
                    .foregroundStyle(ShaudiTheme.accent)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 14)
            } else {
                ForEach(result.visibleRecommendations, id: \.youtubeResult.youtubeVideoID) { item in
                    PlaylistRecommendationRowView(
                        item: item,
                        onPlay: { onPlay(item) },
                        onAdd: { onAdd(item) },
                        onPlayNext: { onPlayNext(item) },
                        onAddToQueue: { onAddToQueue(item) },
                        onAddToPlaylist: { onAddToPlaylist(item) },
                        onReject: { onReject(item) }
                    )
                }

                if result.canFindMore {
                    findMoreButton
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 12, trailing: 12))
        .listRowSeparator(.hidden)
    }

    private var findMoreButton: some View {
        Button {
            onFindMore()
        } label: {
            HStack(spacing: 8) {
                if isFindingMore {
                    ProgressView()
                        .tint(ShaudiTheme.accent)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(isFindingMore ? "Finding more…" : "Find More")
                    .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline).weight(.semibold))
            }
            .foregroundStyle(ShaudiTheme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                ShaudiTheme.card.opacity(0.58),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(ShaudiTheme.accent.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isFindingMore)
        .padding(.top, 4)
        .accessibilityLabel(isFindingMore ? "Finding more recommendations" : "Find more recommendations")
    }
}

struct PlaylistRecommendationRowView: View {
    let item: ResolvedRecommendation
    let onPlay: () -> Void
    let onAdd: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onAddToPlaylist: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onPlay()
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: item.youtubeResult.thumbnailURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            trackArtworkPlaceholder
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(ShaudiTheme.lavender.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(item.artist)
                            .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(item.title) by \(item.artist)")

            Spacer(minLength: 4)

            Button {
                onAdd()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(ShaudiTheme.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add to playlist")

            Menu {
                Button {
                    onPlayNext()
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    onAddToQueue()
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus.fill")
                }

                Button {
                    onAddToPlaylist()
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }

                Button(role: .destructive) {
                    onReject()
                } label: {
                    Label("Not for this playlist", systemImage: "hand.thumbsdown")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Song actions")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(
            ShaudiTheme.card.opacity(0.58),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var trackArtworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.headline)
            .foregroundStyle(ShaudiTheme.lavender)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
