//
//  QueueView.swift
//  Shaudi
//

import SwiftUI

struct QueueView: View {
    @ObservedObject var playbackManager: PlaybackManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ShaudiTheme.dashboardBackground.ignoresSafeArea()

                if playbackManager.currentPlayableTrack == nil {
                    ContentUnavailableView(
                        "Nothing Playing",
                        systemImage: "music.note",
                        description: Text("Start playing a track to see the queue.")
                    )
                } else {
                    queueList
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(ShaudiTheme.accent)
                }
            }
        }
        .tint(ShaudiTheme.accent)
    }

    // MARK: - List

    private var queueList: some View {
        List {
            // Currently Playing section
            if let current = playbackManager.currentPlayableTrack {
                Section("Now Playing") {
                    queueRow(
                        title: current.title,
                        artist: current.channelTitle,
                        thumbnailURL: current.thumbnailURL,
                        isCurrentTrack: true
                    )
                    .listRowBackground(ShaudiTheme.accent.opacity(0.14))
                }
            }

            // Upcoming section
            let upcoming = playbackManager.upcomingQueueTracks
            if !upcoming.isEmpty {
                Section("Up Next") {
                    ForEach(Array(upcoming.enumerated()), id: \.offset) { offset, track in
                        queueRow(
                            title: track.displayTitle,
                            artist: track.displayArtist,
                            thumbnailURL: track.thumbnailURL,
                            isCurrentTrack: false
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playbackManager.jumpToQueueItem(upcomingIndex: offset)
                            dismiss()
                        }
                        .listRowBackground(ShaudiTheme.dashboardCard)
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted().reversed() {
                            playbackManager.removeFromQueue(upcomingIndex: index)
                        }
                    }
                    .onMove { source, destination in
                        playbackManager.moveQueue(from: source, to: destination)
                    }
                }
            } else {
                Section("Up Next") {
                    Text("No upcoming tracks")
                        .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                        .listRowBackground(ShaudiTheme.dashboardCard)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ShaudiTheme.dashboardBackground)
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - Row

    private func queueRow(
        title: String,
        artist: String?,
        thumbnailURL: URL?,
        isCurrentTrack: Bool
    ) -> some View {
        HStack(spacing: 12) {
            artwork(thumbnailURL: thumbnailURL)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(
                        isCurrentTrack
                            ? ShaudiTheme.bodyFont(size: 16, relativeTo: .headline).weight(.semibold)
                            : ShaudiTheme.bodyFont(size: 16, relativeTo: .headline)
                    )
                    .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                    .lineLimit(2)

                if let artist, !artist.isEmpty {
                    Text(artist)
                        .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isCurrentTrack {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(ShaudiTheme.accent)
            }
        }
        .padding(.vertical, 4)
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

    private var artworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.headline)
            .foregroundStyle(ShaudiTheme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
