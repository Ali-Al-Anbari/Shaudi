//
//  GenreStats.swift
//  Shaudi
//

import Foundation

struct GenreTag: Hashable, Sendable {
    let name: String
    let weight: Int
}

enum GenreStatsPolicy {
    nonisolated static let meaningfulListeningThreshold: TimeInterval = 30
    nonisolated static let maximumGenresPerTrack = 3
    nonisolated static let populatedCacheTTL: TimeInterval = 90 * 24 * 60 * 60
    nonisolated static let emptyCacheTTL: TimeInterval = 30 * 24 * 60 * 60
    nonisolated static let failureRetryInterval: TimeInterval = 24 * 60 * 60
}

enum GenreTagNormalizer {
    private nonisolated static let aliases: [String: String] = [
        "hip hop": "Hip-Hop",
        "hiphop": "Hip-Hop",
        "rap": "Hip-Hop",
        "trap": "Trap",
        "pop": "Pop",
        "pop punk": "Pop Punk",
        "punk": "Punk",
        "punk rock": "Punk Rock",
        "rock": "Rock",
        "alternative": "Alternative",
        "alternative rock": "Alternative Rock",
        "alt rock": "Alternative Rock",
        "indie": "Indie",
        "indie rock": "Indie Rock",
        "rnb": "R&B",
        "r and b": "R&B",
        "rhythm and blues": "R&B",
        "soul": "Soul",
        "electronic": "Electronic",
        "dance": "Dance",
        "house": "House",
        "techno": "Techno",
        "metal": "Metal",
        "heavy metal": "Heavy Metal",
        "country": "Country",
        "folk": "Folk",
        "jazz": "Jazz",
        "blues": "Blues",
        "reggae": "Reggae",
        "latin": "Latin",
        "reggaeton": "Reggaeton",
        "disco": "Disco",
        "funk": "Funk",
        "emo": "Emo",
        "grunge": "Grunge",
        "k pop": "K-Pop"
    ]

    nonisolated static func normalizedGenre(for tag: String) -> String? {
        aliases[normalizedKey(for: tag)]
    }

    nonisolated static func normalizedGenres(
        from tags: [GenreTag],
        maximumCount: Int = GenreStatsPolicy.maximumGenresPerTrack
    ) -> [String] {
        guard maximumCount > 0 else {
            return []
        }

        var weights: [String: Int] = [:]
        var firstPositions: [String: Int] = [:]
        for (index, tag) in tags.enumerated() {
            guard let genre = normalizedGenre(for: tag.name) else {
                continue
            }

            weights[genre] = max(weights[genre] ?? 0, tag.weight)
            firstPositions[genre] = min(firstPositions[genre] ?? index, index)
        }

        return weights.keys.sorted { first, second in
            let firstWeight = weights[first] ?? 0
            let secondWeight = weights[second] ?? 0
            if firstWeight != secondWeight {
                return firstWeight > secondWeight
            }
            return (firstPositions[first] ?? .max) < (firstPositions[second] ?? .max)
        }
        .prefix(maximumCount)
        .map { $0 }
    }

    private nonisolated static func normalizedKey(for value: String) -> String {
        MusicMetadataText.decoded(value)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

struct GenreTagCacheState: Equatable, Sendable {
    let genres: [String]
    let fetchedAt: Date?
    let lastAttemptAt: Date?

    nonisolated func lookupDecision(now: Date = .now) -> GenreLookupDecision {
        if let fetchedAt {
            let ttl = genres.isEmpty
                ? GenreStatsPolicy.emptyCacheTTL
                : GenreStatsPolicy.populatedCacheTTL
            if now.timeIntervalSince(fetchedAt) < ttl {
                return .cached
            }
        }

        if let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < GenreStatsPolicy.failureRetryInterval
        {
            return .retryDeferred
        }

        return .lookup
    }
}

enum GenreLookupDecision: Equatable, Sendable {
    case lookup
    case cached
    case retryDeferred
}

protocol GenreTagFetching: Sendable {
    func topTags(artist: String, title: String) async throws -> [GenreTag]
}

actor GenreLookupCoordinator {
    private var inFlightKeys: Set<String> = []

    func lookup(
        cacheState: GenreTagCacheState,
        cacheKey: String,
        artist: String,
        title: String,
        fetcher: any GenreTagFetching,
        now: Date = .now
    ) async -> GenreLookupResult {
        switch cacheState.lookupDecision(now: now) {
        case .cached:
            return .cached
        case .retryDeferred:
            return .retryDeferred
        case .lookup:
            break
        }

        guard inFlightKeys.insert(cacheKey).inserted else {
            return .inFlight
        }
        defer { inFlightKeys.remove(cacheKey) }

        do {
            let tags = try await fetcher.topTags(artist: artist, title: title)
            return .success(
                GenreTagNormalizer.normalizedGenres(from: tags)
            )
        } catch {
            return .failed
        }
    }
}

enum GenreLookupResult: Equatable, Sendable {
    case success([String])
    case cached
    case retryDeferred
    case inFlight
    case failed
}

struct FavoriteGenre: Identifiable, Equatable {
    let name: String
    let listeningDuration: TimeInterval
    let percentage: Int

    var id: String { name }
}

enum FavoriteGenreCalculator {
    nonisolated static func favorites(
        from records: [(genres: [String], listeningDuration: TimeInterval)]
    ) -> [FavoriteGenre] {
        var durations: [String: TimeInterval] = [:]

        for record in records where record.listeningDuration > 0 {
            let genres = Array(Set(record.genres)).sorted()
            guard !genres.isEmpty else {
                continue
            }

            let contribution = record.listeningDuration / Double(genres.count)
            for genre in genres {
                durations[genre, default: 0] += contribution
            }
        }

        let classifiedDuration = durations.values.reduce(0, +)
        guard classifiedDuration > 0 else {
            return []
        }

        return durations.map { name, duration in
            FavoriteGenre(
                name: name,
                listeningDuration: duration,
                percentage: Int((duration / classifiedDuration * 100).rounded())
            )
        }
        .sorted { first, second in
            if first.listeningDuration != second.listeningDuration {
                return first.listeningDuration > second.listeningDuration
            }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }
}
