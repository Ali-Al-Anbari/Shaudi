//
//  LibraryTrackRow.swift
//  Shaudi
//

import SwiftData
import SwiftUI

struct LibraryTrackRow: View {
    let track: Track
    let isCurrentlyPlaying: Bool
    let isSelected: Bool
    let isSelectionMode: Bool
    let play: () -> Void
    let toggleSelection: () -> Void
    let showInfo: () -> Void
    let trim: () -> Void
    let edit: () -> Void
    let addToPlaylist: () -> Void
    let playNext: () -> Void
    let addToQueue: () -> Void
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
                        Text(track.displayTitle)
                            .font(
                                isCurrentlyPlaying
                                    ? ShaudiTheme.bodyFont(size: 17, relativeTo: .headline).weight(.semibold)
                                    : ShaudiTheme.bodyFont(size: 17, relativeTo: .headline)
                            )
                            .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                            .lineLimit(2)

                        if let artist = track.displayArtist, !artist.isEmpty {
                            Text(artist)
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

                    Button(action: trim) {
                        Label("Trim Song", systemImage: "scissors")
                    }

                    Button(action: edit) {
                        Label("Edit Song", systemImage: "pencil")
                    }

                    Button(action: addToPlaylist) {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }

                    Button(action: playNext) {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }

                    Button(action: addToQueue) {
                        Label("Add to Queue", systemImage: "text.badge.plus.fill")
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

func mostPlayedTracks(from tracks: [Track]) -> [Track] {
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

func titleComesBefore(_ first: Track, _ second: Track) -> Bool {
    let titleOrder = first.title.localizedCaseInsensitiveCompare(second.title)
    if titleOrder != .orderedSame {
        return titleOrder == .orderedAscending
    }

    return first.youtubeVideoID < second.youtubeVideoID
}

func deleteTrackFromLibrary(_ track: Track, in modelContext: ModelContext) {
    if let coverID = track.customCoverID {
        ArtworkStorage.deleteTrackCover(for: coverID)
    }

    let containingPlaylists = track.playlists
    for playlist in containingPlaylists {
        playlist.tracks.removeAll { $0 === track }
    }

    modelContext.delete(track)
}
