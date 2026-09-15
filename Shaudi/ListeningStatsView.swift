import SwiftData
import SwiftUI

struct ListeningStatsView: View {
    @EnvironmentObject private var appearanceSettings: AppearanceSettings

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var tracks: [Track]

    private var totalListeningTime: TimeInterval {
        tracks.reduce(0) { $0 + $1.totalListenedDuration }
    }

    private var totalPlays: Int {
        tracks.reduce(0) { $0 + $1.playCount }
    }

    private var uniqueTracksPlayed: Int {
        tracks.count { $0.playCount > 0 || $0.totalListenedDuration > 0 }
    }

    private var hasListeningStats: Bool {
        totalPlays > 0 || totalListeningTime > 0
    }

    private var topTracks: [Track] {
        Array(
            tracks
                .filter { $0.playCount > 0 }
                .sorted { first, second in
                    if first.playCount != second.playCount {
                        return first.playCount > second.playCount
                    }

                    if first.totalListenedDuration != second.totalListenedDuration {
                        return first.totalListenedDuration > second.totalListenedDuration
                    }

                    return first.title.localizedStandardCompare(second.title) == .orderedAscending
                }
                .prefix(5)
        )
    }

    private var mostListenedTracks: [Track] {
        Array(
            tracks
                .filter { $0.totalListenedDuration > 0 }
                .sorted { first, second in
                    if first.totalListenedDuration != second.totalListenedDuration {
                        return first.totalListenedDuration > second.totalListenedDuration
                    }

                    if first.playCount != second.playCount {
                        return first.playCount > second.playCount
                    }

                    return first.title.localizedStandardCompare(second.title) == .orderedAscending
                }
                .prefix(5)
        )
    }

    private var recentlyPlayedTracks: [Track] {
        Array(
            tracks
                .compactMap { track -> (track: Track, date: Date)? in
                    guard let date = track.lastPlayedAt else {
                        return nil
                    }

                    return (track, date)
                }
                .sorted { first, second in
                    if first.date != second.date {
                        return first.date > second.date
                    }

                    return first.track.title.localizedStandardCompare(second.track.title)
                        == .orderedAscending
                }
                .prefix(5)
                .map(\.track)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Listening Stats")
                    .font(ShaudiTheme.scriptFont(size: 34, relativeTo: .title))
                    .foregroundStyle(ShaudiTheme.accent)
                    .accessibilityAddTraits(.isHeader)

                summary

                if hasListeningStats {
                    if !topTracks.isEmpty {
                        statsSection("Top Tracks") {
                            ForEach(Array(topTracks.enumerated()), id: \.element.persistentModelID) {
                                index,
                                track in
                                StatsTrackRow(
                                    rank: index + 1,
                                    track: track,
                                    detail: "\(track.playCount) \(track.playCount == 1 ? "play" : "plays")"
                                )
                            }
                        }
                    }

                    if !mostListenedTracks.isEmpty {
                        statsSection("Most Listened") {
                            ForEach(
                                Array(mostListenedTracks.enumerated()),
                                id: \.element.persistentModelID
                            ) { index, track in
                                StatsTrackRow(
                                    rank: index + 1,
                                    track: track,
                                    detail: formattedListeningTime(track.totalListenedDuration)
                                )
                            }
                        }
                    }

                    if !recentlyPlayedTracks.isEmpty {
                        statsSection("Recently Played") {
                            ForEach(recentlyPlayedTracks) { track in
                                RecentlyPlayedTrackRow(track: track)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Start Listening",
                        systemImage: "music.note.list",
                        description: Text("Start listening to build your stats.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(ShaudiTheme.dashboardBackground)
        .navigationBarTitleDisplayMode(.inline)
        .tint(appearanceSettings.primaryColor)
    }

    private var summary: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 12
        ) {
            summaryCard("Total Listening Time", value: formattedListeningTime(totalListeningTime))
            summaryCard("Total Plays", value: "\(totalPlays)")
            summaryCard("Unique Tracks Played", value: "\(uniqueTracksPlayed)")
                .gridCellColumns(2)
        }
    }

    private func summaryCard(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(ShaudiTheme.bodyFont(size: 25, relativeTo: .title2).weight(.semibold))
                .foregroundStyle(ShaudiTheme.dashboardPrimaryText)

            Text(title)
                .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            ShaudiTheme.dashboardCard,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func statsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(ShaudiTheme.bodyFont(size: 19, relativeTo: .headline).weight(.semibold))
                .foregroundStyle(ShaudiTheme.accent)

            VStack(spacing: 0, content: content)
                .padding(.horizontal, 14)
                .background(
                    ShaudiTheme.dashboardCard,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
    }

    private func formattedListeningTime(_ duration: TimeInterval) -> String {
        guard duration > 0 else {
            return "0 min"
        }

        let totalMinutes = max(1, Int((duration / 60).rounded()))
        guard totalMinutes >= 60 else {
            return "\(totalMinutes) min"
        }

        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }
}

private struct StatsTrackRow: View {
    let rank: Int
    let track: Track
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline).weight(.semibold))
                .foregroundStyle(ShaudiTheme.accent)
                .frame(width: 18)

            artwork

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline))
                    .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                    .lineLimit(1)

                if let artist = track.displayArtist, !artist.isEmpty {
                    Text(artist)
                        .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(detail)
                .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var artwork: some View {
        if let thumbnailURL = track.thumbnailURL {
            AsyncImage(url: thumbnailURL) { phase in
                if case let .success(image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    artworkPlaceholder
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.headline)
            .foregroundStyle(ShaudiTheme.lavender)
            .frame(width: 42, height: 42)
            .background(ShaudiTheme.lavender.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct RecentlyPlayedTrackRow: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.displayTitle)
                .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline))
                .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                .lineLimit(1)

            HStack(spacing: 6) {
                if let artist = track.displayArtist, !artist.isEmpty {
                    Text(artist)
                        .lineLimit(1)
                }

                if track.displayArtist?.isEmpty == false {
                    Text("•")
                }

                if let lastPlayedAt = track.lastPlayedAt {
                    Text(lastPlayedAt.formatted(date: .abbreviated, time: .shortened))
                        .lineLimit(1)
                }
            }
            .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
            .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
    }
}
