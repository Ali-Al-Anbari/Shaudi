import SwiftData
import SwiftUI

struct ListeningStatsView: View {
    @EnvironmentObject private var appearanceSettings: AppearanceSettings

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var tracks: [Track]
    @Query private var recentHistory: [ListeningHistoryEntry]
    @Query(sort: \ListeningHistoryEntry.startedAt, order: .reverse)
    private var listeningHistory: [ListeningHistoryEntry]

    init() {
        _recentHistory = Query(ListeningHistoryStats.recentDescriptor(limit: 5))
    }

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
        totalPlays > 0 || totalListeningTime > 0 || !recentHistory.isEmpty
    }

    private var favoriteGenres: [FavoriteGenre] {
        FavoriteGenreCalculator.favorites(
            from: tracks.map {
                (genres: $0.cachedGenreTags, listeningDuration: $0.totalListenedDuration)
            }
        )
    }

    private var topArtists: [ListeningHistoryStats.TopArtist] {
        ListeningHistoryStats.topArtists(from: listeningHistory)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Listening Stats")
                    .font(ShaudiTheme.scriptFont(size: 34, relativeTo: .title))
                    .foregroundStyle(ShaudiTheme.accent)
                    .accessibilityAddTraits(.isHeader)

                summary

                if hasListeningStats {
                    favoriteGenresSection
                    topArtistsSection

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

                    if !recentHistory.isEmpty {
                        recentlyPlayedSection
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

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recently Played")
                    .font(ShaudiTheme.bodyFont(size: 19, relativeTo: .headline).weight(.semibold))
                    .foregroundStyle(ShaudiTheme.accent)

                Spacer()

                NavigationLink("Show All") {
                    ListeningHistoryView()
                }
                .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline).weight(.semibold))
            }

            LazyVStack(spacing: 0) {
                ForEach(recentHistory) { entry in
                    ListeningHistoryRow(entry: entry)
                }
            }
            .padding(.horizontal, 14)
            .background(
                ShaudiTheme.dashboardCard,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
    }

    @ViewBuilder
    private var topArtistsSection: some View {
        statsSection("Top Artists") {
            if topArtists.isEmpty {
                Text("Based on listening history recorded by Shaudi.")
                    .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                    .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            } else {
                ForEach(Array(topArtists.enumerated()), id: \.element.id) { index, artist in
                    TopArtistRow(
                        rank: index + 1,
                        artist: artist,
                        detail: formattedListeningTime(artist.listenedDuration)
                    )
                }
            }
        }
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

    @ViewBuilder
    private var favoriteGenresSection: some View {
        statsSection("Favorite Genres") {
            if favoriteGenres.isEmpty {
                Text("Listen to more music to discover your favorite genres.")
                    .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                    .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            } else {
                let maximumDuration = favoriteGenres.first?.listeningDuration ?? 1
                ForEach(Array(favoriteGenres.prefix(5))) { genre in
                    FavoriteGenreRow(
                        genre: genre,
                        maximumDuration: maximumDuration
                    )
                }
            }
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

private struct FavoriteGenreRow: View {
    let genre: FavoriteGenre
    let maximumDuration: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(genre.name)
                    .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline).weight(.semibold))
                    .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(genre.percentage)%")
                    .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline).weight(.semibold))
                    .foregroundStyle(ShaudiTheme.accent)
            }

            GeometryReader { proxy in
                Capsule()
                    .fill(ShaudiTheme.accent)
                    .frame(
                        width: proxy.size.width * min(
                            1,
                            genre.listeningDuration / max(1, maximumDuration)
                        )
                    )
            }
            .frame(height: 6)
            .background(
                ShaudiTheme.accent.opacity(0.14),
                in: Capsule()
            )
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(genre.name), \(genre.percentage) percent")
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

private struct TopArtistRow: View {
    let rank: Int
    let artist: ListeningHistoryStats.TopArtist
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline).weight(.semibold))
                .foregroundStyle(ShaudiTheme.accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(artist.displayArtist)
                    .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline))
                    .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                    .lineLimit(1)

                Text("\(artist.eventCount) \(artist.eventCount == 1 ? "listen" : "listens")")
                    .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                    .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
            }

            Spacer(minLength: 8)

            Text(detail)
                .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
        }
        .padding(.vertical, 11)
    }
}

private struct ListeningHistoryRow: View {
    let entry: ListeningHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.canonicalTitle)
                    .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline))
                    .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if !entry.canonicalArtist.isEmpty {
                        Text(entry.canonicalArtist)
                            .lineLimit(1)
                    }

                    if !entry.canonicalArtist.isEmpty {
                        Text("•")
                    }

                    Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .lineLimit(1)
                }
                .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var artwork: some View {
        if let artworkURL = entry.artworkURL {
            AsyncImage(url: artworkURL) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
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

private struct ListeningHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appearanceSettings: AppearanceSettings
    @State private var entries: [ListeningHistoryEntry] = []
    @State private var reachedEnd = false

    var body: some View {
        Group {
            if entries.isEmpty, reachedEnd {
                ContentUnavailableView(
                    "No Listening History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Songs you listen to will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            ListeningHistoryRow(entry: entry)
                                .padding(.horizontal, 16)
                                .onAppear {
                                    if entry.id == entries.last?.id {
                                        loadNextBatch()
                                    }
                                }

                            Divider().opacity(0.2).padding(.leading, 70)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(ShaudiTheme.dashboardBackground.ignoresSafeArea())
        .navigationTitle("Listening History")
        .navigationBarTitleDisplayMode(.inline)
        .tint(appearanceSettings.primaryColor)
        .task {
            if entries.isEmpty, !reachedEnd {
                loadNextBatch()
            }
        }
    }

    private func loadNextBatch() {
        guard !reachedEnd else {
            return
        }
        var descriptor = ListeningHistoryStats.recentDescriptor(
            limit: ListeningHistoryPolicy.fullHistoryBatchSize
        )
        descriptor.fetchOffset = entries.count
        do {
            let batch = try modelContext.fetch(descriptor)
            entries.append(contentsOf: batch)
            reachedEnd = batch.count < ListeningHistoryPolicy.fullHistoryBatchSize
        } catch {
            reachedEnd = true
        }
    }
}
