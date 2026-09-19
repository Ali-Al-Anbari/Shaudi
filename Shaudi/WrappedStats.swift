import Foundation

enum WrappedPeriod: String, CaseIterable, Identifiable {
    case thisYear = "This Year"
    case allTime = "All Time"

    var id: Self { self }

    func startDate(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now)?.start
        case .allTime:
            return nil
        }
    }

    func displayTitle(now: Date, calendar: Calendar) -> String {
        switch self {
        case .thisYear:
            return String(calendar.component(.year, from: now))
        case .allTime:
            return rawValue
        }
    }
}

struct WrappedSong: Identifiable, Equatable {
    let identityKey: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let listenedDuration: TimeInterval
    let playCount: Int

    var id: String { identityKey }
}

enum WrappedPersonality: String, Equatable {
    case explorer
    case loyalist
    case repeatOffender
    case deepListener

    var title: String {
        switch self {
        case .explorer: "The Explorer"
        case .loyalist: "The Loyalist"
        case .repeatOffender: "The Repeat Offender"
        case .deepListener: "The Deep Listener"
        }
    }

    var detail: String {
        switch self {
        case .explorer:
            "Your listening crosses artists freely. Curiosity keeps the next song close."
        case .loyalist:
            "When an artist feels right, you stay awhile and make their catalog feel like home."
        case .repeatOffender:
            "Some songs deserve another spin. And another. You know exactly what hits."
        case .deepListener:
            "You settle into songs and let them unfold instead of rushing to what comes next."
        }
    }
}

struct WrappedSummary: Equatable {
    let period: WrappedPeriod
    let periodTitle: String
    let totalListenedDuration: TimeInterval
    let playCount: Int
    let topSongs: [WrappedSong]
    let topArtists: [ListeningHistoryStats.TopArtist]
    let favoriteGenres: [FavoriteGenre]
    let mostReplayedSong: WrappedSong?
    let personality: WrappedPersonality?

    var hasData: Bool {
        totalListenedDuration > 0 && playCount > 0
    }

    var topSong: WrappedSong? { topSongs.first }
    var topArtist: ListeningHistoryStats.TopArtist? { topArtists.first }
    var favoriteGenre: FavoriteGenre? { favoriteGenres.first }
}

@MainActor
enum WrappedStatsBuilder {
    private struct SongAccumulator {
        var identityKey: String
        var title: String
        var artist: String
        var artworkURL: URL?
        var artworkDate: Date?
        var listenedDuration: TimeInterval
        var playCount: Int
    }

    static func build(
        entries: [ListeningHistoryEntry],
        tracks: [Track] = [],
        period: WrappedPeriod,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> WrappedSummary {
        let startDate = period.startDate(now: now, calendar: calendar)
        let qualifying = entries.filter { entry in
            guard entry.confirmedPlay, entry.startedAt <= now else {
                return false
            }
            return startDate.map { entry.startedAt >= $0 } ?? true
        }
        let listenedEntries = qualifying.filter {
            $0.listenedDuration.isFinite && $0.listenedDuration > 0
        }
        let totalDuration = listenedEntries.reduce(0) { $0 + $1.listenedDuration }

        let allTopArtists = ListeningHistoryStats.topArtists(
            from: qualifying,
            limit: Int.max
        )
        let songs = aggregatedSongs(from: qualifying)
        let topSongs = Array(songs.sorted(by: topSongOrder).prefix(5))
        let replayed = songs
            .filter { $0.playCount > 1 }
            .sorted(by: replayOrder)
            .first
        let mostReplayed = replayed?.identityKey == topSongs.first?.identityKey
            ? nil
            : replayed

        let genresByVideoID = trackGenresByVideoID(tracks)
        let favoriteGenres = FavoriteGenreCalculator.favorites(
            from: listenedEntries.map { entry in
                let videoID = normalizedVideoID(entry.youtubeVideoID)
                let genres = entry.cachedGenreTags.isEmpty
                    ? genresByVideoID[videoID] ?? []
                    : entry.cachedGenreTags
                return (genres: genres, listeningDuration: entry.listenedDuration)
            }
        )

        return WrappedSummary(
            period: period,
            periodTitle: period.displayTitle(now: now, calendar: calendar),
            totalListenedDuration: totalDuration,
            playCount: qualifying.count,
            topSongs: topSongs,
            topArtists: Array(allTopArtists.prefix(5)),
            favoriteGenres: Array(favoriteGenres.prefix(5)),
            mostReplayedSong: mostReplayed,
            personality: personality(
                entries: listenedEntries,
                songs: songs,
                artists: allTopArtists,
                totalDuration: totalDuration
            )
        )
    }

    private static func aggregatedSongs(
        from entries: [ListeningHistoryEntry]
    ) -> [WrappedSong] {
        var accumulators: [String: SongAccumulator] = [:]

        for entry in entries {
            let identity = ListeningHistoryStats.identity(for: entry)
            let normalizedTitle = SongNormalization.baseTitle(identity.title)
            let normalizedArtist = SongNormalization.text(identity.artist)
            let fallbackID = normalizedVideoID(entry.youtubeVideoID)
            let identityKey: String
            if normalizedTitle.isEmpty {
                identityKey = fallbackID.isEmpty ? "entry:\(entry.id.uuidString)" : "video:\(fallbackID)"
            } else {
                identityKey = normalizedArtist + "\u{1F}" + normalizedTitle
            }

            let displayTitle = identity.title.isEmpty ? "Unknown Song" : identity.title
            let displayArtist = identity.artist.isEmpty ? "Unknown Artist" : identity.artist
            let listenedDuration = entry.listenedDuration.isFinite
                ? max(0, entry.listenedDuration)
                : 0

            if var song = accumulators[identityKey] {
                song.listenedDuration += listenedDuration
                song.playCount += 1
                if let artworkURL = entry.artworkURL,
                   song.artworkDate.map({ entry.startedAt > $0 }) ?? true
                {
                    song.artworkURL = artworkURL
                    song.artworkDate = entry.startedAt
                }
                accumulators[identityKey] = song
            } else {
                accumulators[identityKey] = SongAccumulator(
                    identityKey: identityKey,
                    title: displayTitle,
                    artist: displayArtist,
                    artworkURL: entry.artworkURL,
                    artworkDate: entry.artworkURL == nil ? nil : entry.startedAt,
                    listenedDuration: listenedDuration,
                    playCount: 1
                )
            }
        }

        return accumulators.values
            .filter { $0.listenedDuration > 0 }
            .map {
                WrappedSong(
                    identityKey: $0.identityKey,
                    title: $0.title,
                    artist: $0.artist,
                    artworkURL: $0.artworkURL,
                    listenedDuration: $0.listenedDuration,
                    playCount: $0.playCount
                )
            }
    }

    private static func topSongOrder(_ first: WrappedSong, _ second: WrappedSong) -> Bool {
        if first.listenedDuration != second.listenedDuration {
            return first.listenedDuration > second.listenedDuration
        }
        if first.playCount != second.playCount {
            return first.playCount > second.playCount
        }
        if first.artist != second.artist {
            return first.artist.localizedStandardCompare(second.artist) == .orderedAscending
        }
        return first.title.localizedStandardCompare(second.title) == .orderedAscending
    }

    private static func replayOrder(_ first: WrappedSong, _ second: WrappedSong) -> Bool {
        if first.playCount != second.playCount {
            return first.playCount > second.playCount
        }
        return topSongOrder(first, second)
    }

    private static func personality(
        entries: [ListeningHistoryEntry],
        songs: [WrappedSong],
        artists: [ListeningHistoryStats.TopArtist],
        totalDuration: TimeInterval
    ) -> WrappedPersonality? {
        let engagedPlayCount = entries.count
        guard engagedPlayCount > 0, totalDuration > 0 else {
            return nil
        }

        let uniqueSongCount = songs.count
        let repeatShare = Double(max(0, engagedPlayCount - uniqueSongCount))
            / Double(engagedPlayCount)
        let maximumSongPlays = songs.map(\.playCount).max() ?? 0
        if engagedPlayCount >= 6, maximumSongPlays >= 3, repeatShare >= 0.35 {
            return .repeatOffender
        }

        let artistDiversity = Double(artists.count) / Double(engagedPlayCount)
        let topArtistShare = (artists.first?.listenedDuration ?? 0) / totalDuration
        if engagedPlayCount >= 5,
           artists.count >= 5,
           artistDiversity >= 0.60,
           topArtistShare < 0.45
        {
            return .explorer
        }

        let ratioEntries = entries.compactMap { entry -> Double? in
            guard
                let duration = entry.authoritativeDuration,
                duration.isFinite,
                duration > 0
            else {
                return nil
            }
            return min(max(entry.listenedDuration / duration, 0), 1)
        }
        let deepCount = ratioEntries.count { $0 >= 0.60 }
        if ratioEntries.count >= 3,
           Double(deepCount) / Double(ratioEntries.count) >= 0.70
        {
            return .deepListener
        }

        if engagedPlayCount >= 4,
           (artists.first?.eventCount ?? 0) >= 3,
           topArtistShare >= 0.50
        {
            return .loyalist
        }

        return nil
    }

    private static func trackGenresByVideoID(_ tracks: [Track]) -> [String: [String]] {
        var result: [String: Set<String>] = [:]
        for track in tracks {
            let videoID = normalizedVideoID(track.youtubeVideoID)
            guard !videoID.isEmpty, !track.cachedGenreTags.isEmpty else {
                continue
            }
            result[videoID, default: []].formUnion(track.cachedGenreTags)
        }
        return result.mapValues { $0.sorted() }
    }

    private static func normalizedVideoID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
