//
//  RecommendationService.swift
//  Shaudi
//

import Foundation

struct SongIdentity: Hashable {
    let artist: String
    let title: String
    private let normalizedArtist: String
    private let normalizedTitle: String

    init(artist: String, title: String) {
        self.artist = SongNormalization.humanReadable(artist)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = SongNormalization.humanReadable(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedArtist = SongNormalization.text(artist)
        normalizedTitle = SongNormalization.baseTitle(title)
    }

    static func == (lhs: SongIdentity, rhs: SongIdentity) -> Bool {
        lhs.normalizedArtist == rhs.normalizedArtist
            && lhs.normalizedTitle == rhs.normalizedTitle
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedArtist)
        hasher.combine(normalizedTitle)
    }

    var cacheKey: String {
        normalizedArtist + "\u{1F}" + normalizedTitle
    }
}

typealias RecommendationSongIdentity = SongIdentity

struct RecommendationSeed {
    let youtubeVideoID: String
    let rawTitle: String
    let displayedArtist: String?
    let sourceChannel: String?
    let userArtistOverride: String?
    let cleanedArtist: String
    let cleanedTitle: String
    let fallbackTitle: String?
    let artistSource: RecommendationSeedArtistSource
    let identityConfidence: RecommendationIdentityConfidence

    init(
        youtubeVideoID: String,
        rawTitle: String,
        displayedArtist: String?,
        sourceChannel: String?,
        userArtistOverride: String?,
        structuredArtist: String? = nil,
        searchQuery: String? = nil
    ) {
        self.youtubeVideoID = youtubeVideoID
        self.rawTitle = rawTitle
        self.displayedArtist = displayedArtist
        self.sourceChannel = sourceChannel
        self.userArtistOverride = userArtistOverride

        let identity = RecommendationSeedIdentityResolver.resolve(
            rawTitle: rawTitle,
            displayedArtist: displayedArtist,
            channel: sourceChannel,
            userArtistOverride: userArtistOverride,
            structuredArtist: structuredArtist,
            searchQuery: searchQuery
        )
        cleanedArtist = identity.artist
        cleanedTitle = identity.title
        fallbackTitle = identity.fallbackTitle
        artistSource = identity.artistSource
        identityConfidence = identity.confidence

#if DEBUG
        print(
            "[RecommendationIdentity] rawTitle=\(rawTitle) "
                + "rawChannel=\(sourceChannel ?? "")"
        )
        print(
            "[RecommendationIdentity] candidate artist=\(identity.artist) "
                + "title=\(identity.title) source=\(identity.artistSource.rawValue) "
                + "confidence=\(identity.confidence.rawValue)"
        )
        if let sourceChannel, !sourceChannel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let channelConfidence = identity.artistSource == .topicChannel
                || identity.artistSource == .vevoChannel ? "high" : "low"
            print(
                "[RecommendationIdentity] channelCandidate=\(sourceChannel) "
                    + "confidence=\(channelConfidence)"
            )
        }
        print(
            "[RecommendationIdentity] selected artist=\(identity.artist) "
                + "title=\(identity.title) source=\(identity.artistSource.rawValue)"
        )
#endif
    }

    init(
        youtubeVideoID: String,
        canonicalIdentity: SongIdentity,
        youtubeTitle: String,
        youtubeChannel: String,
        authoritativeSource: RecommendationSeedArtistSource = .lastFM
    ) {
        self.youtubeVideoID = youtubeVideoID
        rawTitle = youtubeTitle
        displayedArtist = canonicalIdentity.artist
        sourceChannel = youtubeChannel
        userArtistOverride = nil
        cleanedArtist = canonicalIdentity.artist
        cleanedTitle = canonicalIdentity.title
        fallbackTitle = nil
        artistSource = authoritativeSource
        identityConfidence = .authoritative

#if DEBUG
        print(
            "[RecommendationIdentity] source=\(authoritativeSource.rawValue) "
                + "canonicalArtist=\(canonicalIdentity.artist) "
                + "canonicalTitle=\(canonicalIdentity.title) reparseSkipped=true"
        )
#endif
    }

    var songIdentity: RecommendationSongIdentity {
        RecommendationSongIdentity(artist: cleanedArtist, title: cleanedTitle)
    }

    var confidentSongIdentityForCaching: SongIdentity? {
        guard !cleanedArtist.isEmpty, !cleanedTitle.isEmpty else {
            return nil
        }
        guard identityConfidence >= .high else { return nil }
        return songIdentity
    }
}

enum RecommendationSeedArtistSource: String {
    case lastFM
    case learnedCache
    case userOverride
    case structuredArtist
    case titleArtistSong
    case titleSongArtist
    case topicChannel
    case vevoChannel
    case channelFallback
    case unknown
}

enum RecommendationIdentityConfidence: String, Comparable {
    case low
    case medium
    case high
    case authoritative

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .authoritative: 3
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

private struct RecommendationSeedIdentity {
    let artist: String
    let title: String
    let fallbackTitle: String?
    let artistSource: RecommendationSeedArtistSource
    let confidence: RecommendationIdentityConfidence
}

private enum RecommendationSeedIdentityResolver {
    private struct ParsedTitleIdentity {
        let artist: String
        let title: String
        let source: RecommendationSeedArtistSource
        let confidence: RecommendationIdentityConfidence
    }

    static func resolve(
        rawTitle: String,
        displayedArtist: String?,
        channel: String?,
        userArtistOverride: String?,
        structuredArtist: String? = nil,
        searchQuery: String? = nil
    ) -> RecommendationSeedIdentity {
        let cleanedRawTitle = SongNormalization.displayTitle(rawTitle)
        let structuralTitle = SongNormalization.removingTrailingProductionCredit(
            from: cleanedRawTitle
        )
        let override = nonempty(userArtistOverride).map { SongNormalization.artist($0) }
        let cleanedChannel = nonempty(channel).map { SongNormalization.artist($0) }
        let explicitArtist = nonempty(structuredArtist).map { SongNormalization.artist($0) }
        let topicArtist = channel.flatMap { isTopicChannel($0) ? cleanedChannel : nil }
        let vevoArtist = channel.flatMap { SongNormalization.vevoArtist($0) }
        let parsedTitle = parsedArtistAndTitle(
            from: structuralTitle,
            supportingArtist: topicArtist ?? vevoArtist ?? cleanedChannel,
            searchQuery: searchQuery
        )

        let artist: String
        let artistSource: RecommendationSeedArtistSource
        let confidence: RecommendationIdentityConfidence
        if let override, !override.isEmpty {
            artist = override
            artistSource = .userOverride
            confidence = .authoritative
        } else if let explicitArtist, !explicitArtist.isEmpty {
            artist = explicitArtist
            artistSource = .structuredArtist
            confidence = .high
        } else if let topicArtist, !topicArtist.isEmpty {
            artist = topicArtist
            artistSource = .topicChannel
            confidence = .high
        } else if let parsedTitle {
            artist = parsedTitle.artist
            artistSource = parsedTitle.source
            confidence = parsedTitle.confidence
        } else if let vevoArtist, !vevoArtist.isEmpty {
            artist = vevoArtist
            artistSource = .vevoChannel
            confidence = .high
        } else {
            _ = displayedArtist
            artist = ""
            artistSource = cleanedChannel == nil ? .unknown : .channelFallback
            confidence = .low
        }

        let titleWithFeatures: String
        if override != nil || explicitArtist != nil || topicArtist != nil || vevoArtist != nil {
            titleWithFeatures = SongNormalization.displayTitle(
                cleanedRawTitle,
                removingArtist: artist
            )
        } else if let parsedTitle {
            titleWithFeatures = parsedTitle.title
        } else {
            titleWithFeatures = SongNormalization.displayTitle(
                cleanedRawTitle,
                removingArtist: artist
            )
        }
        let presentationCleanedTitle = SongNormalization.displayTitle(titleWithFeatures)
        let titleWithoutProductionCredit = SongNormalization.removingTrailingProductionCredit(
            from: presentationCleanedTitle
        )
        let canonicalTitle = SongNormalization.displayTitle(
            SongNormalization.removingFeaturedArtistCredit(
                from: titleWithoutProductionCredit
            )
        )
        let fallbackTitle = SongNormalization.text(canonicalTitle)
            == SongNormalization.text(presentationCleanedTitle)
            ? nil
            : presentationCleanedTitle

        return RecommendationSeedIdentity(
            artist: artist,
            title: canonicalTitle,
            fallbackTitle: fallbackTitle,
            artistSource: artistSource,
            confidence: confidence
        )
    }

    private static func parsedArtistAndTitle(
        from value: String,
        supportingArtist: String?,
        searchQuery: String?
    ) -> ParsedTitleIdentity? {
        for separator in ["//", "|", "•"] {
            if let split = split(value, separator: separator),
               isPlausibleArtist(split.right),
               isPlausibleTitle(split.left) {
                return ParsedTitleIdentity(
                    artist: canonicalArtistDisplay(split.right),
                    title: split.left,
                    source: .titleSongArtist,
                    confidence: .high
                )
            }
        }

        if let range = value.range(of: #"(?i)\s+by\s+"#, options: .regularExpression) {
            let song = trimmed(value[..<range.lowerBound])
            let artist = trimmed(value[range.upperBound...])
            if isPlausibleArtist(artist), isPlausibleTitle(song) {
                return ParsedTitleIdentity(
                    artist: canonicalArtistDisplay(artist),
                    title: song,
                    source: .titleSongArtist,
                    confidence: .high
                )
            }
        }

        if let range = value.range(of: #"\s*:\s+"#, options: .regularExpression),
           let candidate = dashCandidate(
               value: value,
               range: range,
               supportingArtist: supportingArtist,
               searchQuery: searchQuery,
               compact: false
           ) {
            return candidate
        }

        if let range = value.range(
            of: #"(?:\s+[-–—]\s*|[-–—]\s+)"#,
            options: .regularExpression
        ), let candidate = dashCandidate(
            value: value,
            range: range,
            supportingArtist: supportingArtist,
            searchQuery: searchQuery,
            compact: false
        ) {
            return candidate
        }

        for index in value.indices where "-–—".contains(value[index]) {
            let next = value.index(after: index)
            let range = index..<next
            if let candidate = dashCandidate(
                value: value,
                range: range,
                supportingArtist: supportingArtist,
                searchQuery: searchQuery,
                compact: true
            ) {
                return candidate
            }
        }
        return nil
    }

    private static func dashCandidate(
        value: String,
        range: Range<String.Index>,
        supportingArtist: String?,
        searchQuery: String?,
        compact: Bool
    ) -> ParsedTitleIdentity? {
        let left = trimmed(value[..<range.lowerBound])
        let right = trimmed(value[range.upperBound...])
        guard isPlausibleArtist(left), isPlausibleTitle(right) else { return nil }

        let support = SongNormalization.text(supportingArtist ?? "")
        let leftKey = SongNormalization.text(left)
        let rightKey = SongNormalization.text(right)
        if !support.isEmpty, support == rightKey, isPlausibleArtist(right) {
            return ParsedTitleIdentity(
                artist: canonicalArtistDisplay(right),
                title: left,
                source: .titleSongArtist,
                confidence: .high
            )
        }

        let query = SongNormalization.text(searchQuery ?? "")
        let querySupportsLeft = !query.isEmpty
            && query.hasPrefix(leftKey)
            && query.contains(rightKey)
        let leftWordCount = left.split(whereSeparator: \.isWhitespace).count
        let hasStrongLeftShape = leftWordCount >= 2
            || left.contains(" & ")
            || left.localizedCaseInsensitiveContains(" feat. ")
            || left.localizedCaseInsensitiveContains(" feat ")
            || left.contains(" x ")
            || left.contains(",")

        if compact, !hasStrongLeftShape, support != leftKey, !querySupportsLeft {
            return nil
        }
        let confidence: RecommendationIdentityConfidence =
            support == leftKey || querySupportsLeft || hasStrongLeftShape ? .high : .medium
        return ParsedTitleIdentity(
            artist: canonicalArtistDisplay(left),
            title: right,
            source: .titleArtistSong,
            confidence: confidence
        )
    }

    private static func split(
        _ value: String,
        separator: String
    ) -> (left: String, right: String)? {
        guard let range = value.range(of: separator) else { return nil }
        return (trimmed(value[..<range.lowerBound]), trimmed(value[range.upperBound...]))
    }

    private static func isPlausibleArtist(_ value: String) -> Bool {
        let wordCount = value.split(whereSeparator: \.isWhitespace).count
        return !value.isEmpty
            && value.count <= 80
            && (1...10).contains(wordCount)
            && value.rangeOfCharacter(from: .alphanumerics) != nil
    }

    private static func isPlausibleTitle(_ value: String) -> Bool {
        !value.isEmpty && value.rangeOfCharacter(from: .alphanumerics) != nil
    }

    private static func canonicalArtistDisplay(_ value: String) -> String {
        let artist = SongNormalization.artist(value)
        let letters = artist.unicodeScalars.filter(CharacterSet.letters.contains)
        guard
            artist.split(whereSeparator: \.isWhitespace).count >= 2,
            !letters.isEmpty,
            letters.allSatisfy({ CharacterSet.lowercaseLetters.contains($0) })
        else {
            return artist
        }
        return artist.localizedCapitalized
    }

    private static func trimmed(_ value: String.SubSequence) -> String {
        String(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTopicChannel(_ value: String) -> Bool {
        value.range(of: #"(?i)\s*-\s*topic\s*$"#, options: .regularExpression) != nil
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct ResolvedRecommendation {
    let artist: String
    let title: String
    let match: Double
    let youtubeResult: YouTubeSearchResult

    var songIdentity: RecommendationSongIdentity {
        SongIdentity(artist: artist, title: title)
    }

    var transportMetadata: RecommendationTransportMetadata {
        RecommendationTransportMetadata(
            canonicalIdentity: songIdentity,
            youtubeTitle: youtubeResult.title,
            youtubeChannel: youtubeResult.channelTitle
        )
    }
}

struct RecommendationTransportMetadata {
    let canonicalIdentity: SongIdentity
    let youtubeTitle: String
    let youtubeChannel: String
}

struct RecommendationBatch {
    let recommendations: [ResolvedRecommendation]
    let reservoirCandidates: [LastFMSimilarTrack]
}

struct RecommendationReservoirResolution {
    let recommendations: [ResolvedRecommendation]
    let unusedCandidates: [LastFMSimilarTrack]
    let exhaustedCurrentPaths: Bool
}

enum RecommendationYouTubeResolutionAttempt {
    case cacheOnly
    case primaryOnly(RecommendationResolutionContext? = nil)
    case officialFallback(RecommendationResolutionContext)
}

private enum RecommendationCandidateResolution {
    case resolved(ResolvedRecommendation)
    case candidateMiss
    case temporarilyUnavailable
    case fallbackUnavailable
}

struct RecommendationCandidateReservoir {
    private(set) var candidates: [LastFMSimilarTrack] = []

    var count: Int {
        candidates.count
    }

    var isEmpty: Bool {
        candidates.isEmpty
    }

    mutating func reset() {
        candidates = []
    }

    mutating func store(
        _ newCandidates: [LastFMSimilarTrack],
        excluding excluded: Set<RecommendationSongIdentity>,
        limit: Int
    ) {
        guard limit > 0 else {
            candidates = []
            return
        }
        let existing = Set(candidates.map {
            RecommendationSongIdentity(artist: $0.artist, title: $0.title)
        })
        var seen = existing.union(excluded)
        let fresh = newCandidates.filter { candidate in
            seen.insert(RecommendationSongIdentity(
                artist: candidate.artist,
                title: candidate.title
            )).inserted
        }
        candidates = Array((fresh + candidates).prefix(limit))
    }

    mutating func take(upTo limit: Int) -> [LastFMSimilarTrack] {
        guard limit > 0, !candidates.isEmpty else {
            return []
        }
        let count = min(limit, candidates.count)
        let result = Array(candidates.prefix(count))
        candidates.removeFirst(count)
        return result
    }
}

@MainActor
struct RecommendationService {
    struct RankedSong {
        let track: LastFMSimilarTrack
        let identity: RecommendationSongIdentity

        var score: Double {
            track.match
        }
    }

    private struct RankedYouTubeResult {
        let result: YouTubeSearchResult
        let score: Int
    }

    typealias SimilarTracksOperation = (
        _ artist: String,
        _ title: String,
        _ limit: Int,
        _ isFallback: Bool
    ) async throws -> [LastFMSimilarTrack]

    typealias TopTracksOperation = (
        _ artist: String,
        _ limit: Int
    ) async throws -> [LastFMTopTrack]

    private let similarTracksOperation: SimilarTracksOperation
    private let topTracksOperation: TopTracksOperation
    private let videoResolver: YouTubeRecommendationResolver
    private let resolutionCache: any YouTubeResolutionCaching
    private let resultLimit = RecommendationRadioPolicy.targetUpcomingCount
    private let candidatePoolLimit = RecommendationRadioPolicy.candidatePoolSize
    private let youtubeResolutionLimit = 12
    private let reservoirCandidateLimit = RecommendationRadioPolicy.candidatePoolSize
    private let topTrackAnchorLimit = 10

    init() {
        let lastFMService = LastFMRecommendationService()
        similarTracksOperation = { artist, title, limit, isFallback in
            try await lastFMService.similarTracks(
                artist: artist,
                title: title,
                limit: limit,
                isFallback: isFallback
            )
        }
        topTracksOperation = { artist, limit in
            try await lastFMService.topTracks(artist: artist, limit: limit)
        }
        videoResolver = YouTubeRecommendationResolver()
        resolutionCache = PersistentYouTubeResolutionCache.shared
    }

    init(
        similarTracks: @escaping (
            _ artist: String,
            _ title: String,
            _ limit: Int
        ) async throws -> [LastFMSimilarTrack],
        topTracks: @escaping TopTracksOperation = { _, _ in [] },
        videoResolver: YouTubeRecommendationResolver,
        resolutionCache: any YouTubeResolutionCaching
    ) {
        similarTracksOperation = { artist, title, limit, _ in
            try await similarTracks(artist, title, limit)
        }
        topTracksOperation = topTracks
        self.videoResolver = videoResolver
        self.resolutionCache = resolutionCache
    }

    func recommendations(
        for seed: RecommendationSeed,
        excludingVideoIDs: Set<String>,
        excludingSongIdentities: Set<RecommendationSongIdentity>,
        context: RecommendationResolutionContext
    ) async throws -> RecommendationBatch {
        let seedArtist = seed.cleanedArtist
        let seedTitle = seed.cleanedTitle
        guard !seedArtist.isEmpty, !seedTitle.isEmpty else {
            recommendationLog("all candidates filtered reason=blank normalized seed")
            return RecommendationBatch(recommendations: [], reservoirCandidates: [])
        }

#if DEBUG
        print("[Recommendations] primaryAnchor=\(seedArtist) - \(seedTitle)")
#endif
        let ranked = try await rankedCandidates(
            for: seed,
            excludingSongIdentities: excludingSongIdentities
        )
#if DEBUG
        print("[Recommendations] candidates after diversity=\(ranked.count)")
#endif
        var selected: [ResolvedRecommendation] = []
        var seenVideoIDs = Set(excludingVideoIDs.map(normalizedVideoID))
        var seenSongs = excludingSongIdentities
        var artistCounts: [String: Int] = [:]
        var deferredForDiversity: [RankedSong] = []
        var fallbackCandidates: [RankedSong] = []
        var temporarilyUnavailableCandidates: [RankedSong] = []
        var attemptedResolutions = 0
        var attemptedSongIdentities = Set<RecommendationSongIdentity>()

        for candidate in ranked {
            try Task.checkCancellation()
            guard selected.count < resultLimit, attemptedResolutions < youtubeResolutionLimit else {
                break
            }

            let normalizedArtist = SongNormalization.text(candidate.track.artist)
            if artistCounts[normalizedArtist, default: 0] >= 2 {
                deferredForDiversity.append(candidate)
                continue
            }

            attemptedResolutions += 1
            attemptedSongIdentities.insert(candidate.identity)
            let outcome = try await safelyResolveCandidate(
                candidate.track,
                attempt: .primaryOnly(context)
            )
            guard case .resolved(let resolved) = outcome else {
                fallbackCandidates.append(candidate)
                if case .temporarilyUnavailable = outcome {
                    temporarilyUnavailableCandidates.append(candidate)
                }
                continue
            }
            let videoID = normalizedVideoID(resolved.youtubeResult.youtubeVideoID)
            guard
                seenVideoIDs.insert(videoID).inserted,
                seenSongs.insert(resolved.songIdentity).inserted
            else {
                recommendationLog("rejected duplicate resolved song=\(resolved.artist) - \(resolved.title)")
                continue
            }
            selected.append(resolved)
            artistCounts[normalizedArtist, default: 0] += 1
        }

        if selected.count < resultLimit {
            for candidate in deferredForDiversity {
                try Task.checkCancellation()
                guard selected.count < resultLimit, attemptedResolutions < youtubeResolutionLimit else {
                    break
                }
                attemptedResolutions += 1
                attemptedSongIdentities.insert(candidate.identity)
                let outcome = try await safelyResolveCandidate(
                    candidate.track,
                    attempt: .primaryOnly(context)
                )
                guard case .resolved(let resolved) = outcome else {
                    fallbackCandidates.append(candidate)
                    if case .temporarilyUnavailable = outcome {
                        temporarilyUnavailableCandidates.append(candidate)
                    }
                    continue
                }
                let videoID = normalizedVideoID(resolved.youtubeResult.youtubeVideoID)
                guard
                    seenVideoIDs.insert(videoID).inserted,
                    seenSongs.insert(resolved.songIdentity).inserted
                else {
                    continue
                }
                selected.append(resolved)
            }
        }

        for candidate in fallbackCandidates {
            try Task.checkCancellation()
            guard selected.count < resultLimit else {
                break
            }
            let outcome = try await safelyResolveCandidate(
                candidate.track,
                attempt: .officialFallback(context.addingResolved(selected.count))
            )
            guard case .resolved(let resolved) = outcome else {
                if case .fallbackUnavailable = outcome,
                   !temporarilyUnavailableCandidates.contains(where: {
                       $0.identity == candidate.identity
                   }) {
                    temporarilyUnavailableCandidates.append(candidate)
                }
                continue
            }
            let videoID = normalizedVideoID(resolved.youtubeResult.youtubeVideoID)
            guard
                seenVideoIDs.insert(videoID).inserted,
                seenSongs.insert(resolved.songIdentity).inserted
            else {
                continue
            }
            selected.append(resolved)
        }

#if DEBUG
        print("[Recommendations] selected=\(selected.count)")
        for (index, item) in selected.enumerated() {
            print("\(index + 1). \(item.artist) - \(item.title)")
        }
#endif
        let selectedIdentities = Set(selected.map(\.songIdentity))
        let deferredIdentities = Set(temporarilyUnavailableCandidates.map(\.identity))
        let reservoirCandidates = Array(ranked.lazy.filter {
            (!attemptedSongIdentities.contains($0.identity)
                || deferredIdentities.contains($0.identity))
                && !selectedIdentities.contains($0.identity)
        }.prefix(reservoirCandidateLimit).map(\.track))
        return RecommendationBatch(
            recommendations: selected,
            reservoirCandidates: reservoirCandidates
        )
    }

    func recommendationsFromReservoir(
        _ candidates: [LastFMSimilarTrack],
        desiredCount: Int,
        excludingVideoIDs: Set<String>,
        excludingSongIdentities: Set<RecommendationSongIdentity>,
        context: RecommendationResolutionContext
    ) async throws -> [ResolvedRecommendation] {
        try await resolveReservoirCandidates(
            candidates,
            desiredCount: desiredCount,
            excludingVideoIDs: excludingVideoIDs,
            excludingSongIdentities: excludingSongIdentities,
            context: context
        ).recommendations
    }

    func resolveReservoirCandidates(
        _ candidates: [LastFMSimilarTrack],
        desiredCount: Int,
        excludingVideoIDs: Set<String>,
        excludingSongIdentities: Set<RecommendationSongIdentity>,
        context: RecommendationResolutionContext
    ) async throws -> RecommendationReservoirResolution {
        guard desiredCount > 0 else {
            return RecommendationReservoirResolution(
                recommendations: [],
                unusedCandidates: candidates,
                exhaustedCurrentPaths: false
            )
        }
        var resolved: [ResolvedRecommendation] = []
        var fallbackCandidates: [LastFMSimilarTrack] = []
        var deferredCandidates: [LastFMSimilarTrack] = []
        var seenVideoIDs = Set(excludingVideoIDs.map(normalizedVideoID))
        var seenSongs = excludingSongIdentities
        var cacheMisses: [LastFMSimilarTrack] = []
        var cacheScannedCount = 0

        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            guard context.isActive else {
                throw CancellationError()
            }
            guard resolved.count < desiredCount else {
                return RecommendationReservoirResolution(
                    recommendations: resolved,
                    unusedCandidates: cacheMisses + Array(candidates[index...]),
                    exhaustedCurrentPaths: false
                )
            }
            let identity = RecommendationSongIdentity(
                artist: candidate.artist,
                title: candidate.title
            )
            guard !seenSongs.contains(identity) else {
                continue
            }
            cacheScannedCount += 1
            let outcome = try await safelyResolveCandidate(
                candidate,
                attempt: .cacheOnly
            )
            guard case .resolved(let recommendation) = outcome else {
                cacheMisses.append(candidate)
                continue
            }
            let videoID = normalizedVideoID(recommendation.youtubeResult.youtubeVideoID)
            guard !videoID.isEmpty, seenVideoIDs.insert(videoID).inserted else {
                continue
            }
            seenSongs.insert(identity)
            resolved.append(recommendation)
        }
#if DEBUG
        print(
            "[Recommendations] cacheRecovery hits=\(resolved.count) "
                + "scanned=\(cacheScannedCount)"
        )
#endif
        guard resolved.count < desiredCount else {
            return RecommendationReservoirResolution(
                recommendations: resolved,
                unusedCandidates: cacheMisses,
                exhaustedCurrentPaths: false
            )
        }

        var nextCandidateIndex = 0
        if videoResolver.isWebSearchCircuitOpen {
            fallbackCandidates = cacheMisses
            deferredCandidates = cacheMisses
            nextCandidateIndex = cacheMisses.count
#if DEBUG
            print("[Recommendations] cacheRecovery webSkipped=true reason=circuitOpen")
#endif
        }
        resolutionLoop: while nextCandidateIndex < cacheMisses.count,
                              resolved.count < desiredCount {
            try Task.checkCancellation()
            guard context.isActive else {
                throw CancellationError()
            }
            let sliceEnd = min(
                nextCandidateIndex + RecommendationRadioPolicy.resolverSliceSize,
                cacheMisses.count
            )
            let resolvedBeforeSlice = resolved.count
            var processedThroughIndex = nextCandidateIndex
            for candidateIndex in nextCandidateIndex..<sliceEnd {
                let candidate = cacheMisses[candidateIndex]
                try Task.checkCancellation()
                guard context.isActive else {
                    throw CancellationError()
                }
                if videoResolver.isWebSearchCircuitOpen {
                    let unavailable = Array(cacheMisses[candidateIndex...])
                    fallbackCandidates.append(contentsOf: unavailable)
                    deferredCandidates.append(contentsOf: unavailable)
                    nextCandidateIndex = cacheMisses.count
#if DEBUG
                    print("[Recommendations] cacheRecovery webSkipped=true reason=circuitOpen")
#endif
                    break resolutionLoop
                }
                processedThroughIndex = candidateIndex + 1
                let outcome = try await safelyResolveCandidate(
                    candidate,
                    attempt: .primaryOnly(context)
                )
                guard case .resolved(let recommendation) = outcome else {
                    fallbackCandidates.append(candidate)
                    if case .temporarilyUnavailable = outcome {
                        deferredCandidates.append(candidate)
                    }
                    continue
                }
                let videoID = normalizedVideoID(recommendation.youtubeResult.youtubeVideoID)
                guard !videoID.isEmpty, seenVideoIDs.insert(videoID).inserted else {
                    continue
                }
                seenSongs.insert(recommendation.songIdentity)
                resolved.append(recommendation)
                if resolved.count >= desiredCount {
                    break
                }
            }
            nextCandidateIndex = processedThroughIndex
#if DEBUG
            if resolved.count == resolvedBeforeSlice {
                print(
                    "[Recommendations] refillSlice resolved=0 "
                        + "remainingReservoir=\(cacheMisses.count - nextCandidateIndex)"
                )
                if nextCandidateIndex < cacheMisses.count {
                    print("[Recommendations] refillContinuing=true")
                }
            }
#endif
        }

        if resolved.count >= desiredCount {
            let remaining = nextCandidateIndex < cacheMisses.count
                ? Array(cacheMisses[nextCandidateIndex...])
                : []
            return RecommendationReservoirResolution(
                recommendations: resolved,
                unusedCandidates: deferredCandidates + remaining,
                exhaustedCurrentPaths: false
            )
        }

        for candidate in fallbackCandidates {
            try Task.checkCancellation()
            guard context.isActive, resolved.count < desiredCount else {
                break
            }
            let outcome = try await safelyResolveCandidate(
                candidate,
                attempt: .officialFallback(context.addingResolved(resolved.count))
            )
            guard case .resolved(let recommendation) = outcome else {
                if case .fallbackUnavailable = outcome,
                   !deferredCandidates.contains(where: {
                       RecommendationSongIdentity(artist: $0.artist, title: $0.title)
                           == RecommendationSongIdentity(artist: candidate.artist, title: candidate.title)
                   }) {
                    deferredCandidates.append(candidate)
                }
                continue
            }
            let videoID = normalizedVideoID(recommendation.youtubeResult.youtubeVideoID)
            guard !videoID.isEmpty, seenVideoIDs.insert(videoID).inserted else {
                continue
            }
            seenSongs.insert(recommendation.songIdentity)
            resolved.append(recommendation)
        }
        let resolvedIdentities = Set(resolved.map(\.songIdentity))
        let stillDeferred = deferredCandidates.filter {
            !resolvedIdentities.contains(RecommendationSongIdentity(
                artist: $0.artist,
                title: $0.title
            ))
        }
        return RecommendationReservoirResolution(
            recommendations: resolved,
            unusedCandidates: stillDeferred,
            exhaustedCurrentPaths: resolved.isEmpty
        )
    }

    func rankedCandidates(
        for seed: RecommendationSeed,
        excludingSongIdentities: Set<RecommendationSongIdentity>
    ) async throws -> [RankedSong] {
        let primary = try await primarySimilarTracks(for: seed)
        let primaryRanked = filteredCandidates(
            primary,
            seed: seed,
            excluding: excludingSongIdentities
        ).sorted(by: rankedSongOrder)
        guard primaryRanked.count < resultLimit else {
            return primaryRanked
        }

#if DEBUG
        if primaryRanked.isEmpty {
            print("[LastFM] trackSimilarEmpty artist=\(seed.cleanedArtist) track=\(seed.cleanedTitle)")
        } else {
            print(
                "[LastFM] trackSimilarInsufficient artist=\(seed.cleanedArtist) "
                    + "track=\(seed.cleanedTitle) usable=\(primaryRanked.count)"
            )
        }
        print("[Recommendations] surrogateFallback requested artist=\(seed.cleanedArtist)")
#endif
        let topTracks: [LastFMTopTrack]
        do {
            topTracks = try await topTracksOperation(seed.cleanedArtist, topTrackAnchorLimit)
        } catch {
#if DEBUG
            print("[Recommendations] surrogateFallback unavailable reason=topTracksFailed")
#endif
            return primaryRanked
        }
        guard let surrogate = surrogateAnchor(from: topTracks, excluding: seed.songIdentity) else {
#if DEBUG
            print("[Recommendations] surrogateFallback unavailable reason=noTopTracks")
#endif
            return primaryRanked
        }

#if DEBUG
        print("[Recommendations] surrogateAnchor=\(surrogate.artist) - \(surrogate.title)")
#endif
        let surrogateCandidates: [LastFMSimilarTrack]
        do {
            surrogateCandidates = try await similarTracksOperation(
                surrogate.artist,
                surrogate.title,
                candidatePoolLimit,
                true
            )
        } catch {
#if DEBUG
            print("[Recommendations] surrogateCandidates received=0")
#endif
            return primaryRanked
        }
#if DEBUG
        print("[Recommendations] surrogateCandidates received=\(surrogateCandidates.count)")
#endif
        guard !surrogateCandidates.isEmpty else {
            return primaryRanked
        }
        return filteredCandidates(
            primary + surrogateCandidates,
            seed: seed,
            excluding: excludingSongIdentities
        ).sorted(by: rankedSongOrder)
    }

    private func primarySimilarTracks(
        for seed: RecommendationSeed
    ) async throws -> [LastFMSimilarTrack] {
        do {
            let primary = try await similarTracksOperation(
                seed.cleanedArtist,
                seed.cleanedTitle,
                candidatePoolLimit,
                false
            )
            guard primary.isEmpty, let fallbackTitle = usableFallbackTitle(for: seed) else {
                return primary
            }

#if DEBUG
            print("[LastFM] primary seed failed reason=zero usable candidates")
            print("[LastFM] retry artist=\(seed.cleanedArtist) track=\(fallbackTitle)")
#endif
            return try await similarTracksOperation(
                seed.cleanedArtist,
                fallbackTitle,
                candidatePoolLimit,
                false
            )
        } catch let error as LastFMRecommendationService.ServiceError {
            guard
                error.permitsAlternateSeedRetry,
                let fallbackTitle = usableFallbackTitle(for: seed)
            else {
                if error.permitsAlternateSeedRetry {
                    return []
                }
                throw error
            }

#if DEBUG
            print("[LastFM] primary seed failed reason=\(error.localizedDescription)")
            print("[LastFM] retry artist=\(seed.cleanedArtist) track=\(fallbackTitle)")
#endif
            do {
                return try await similarTracksOperation(
                    seed.cleanedArtist,
                    fallbackTitle,
                    candidatePoolLimit,
                    false
                )
            } catch let fallbackError as LastFMRecommendationService.ServiceError
                where fallbackError.permitsAlternateSeedRetry {
                return []
            }
        }
    }

    private func surrogateAnchor(
        from tracks: [LastFMTopTrack],
        excluding seedIdentity: RecommendationSongIdentity
    ) -> LastFMTopTrack? {
        tracks.first { track in
            let artist = SongNormalization.humanReadable(track.artist)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = SongNormalization.humanReadable(track.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !title.isEmpty else {
                return false
            }
            return RecommendationSongIdentity(artist: artist, title: title) != seedIdentity
        }
    }

    private func usableFallbackTitle(for seed: RecommendationSeed) -> String? {
        guard let fallbackTitle = seed.fallbackTitle else {
            return nil
        }
        let trimmed = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            SongNormalization.text(trimmed) != SongNormalization.text(seed.cleanedTitle)
        else {
            return nil
        }
        return trimmed
    }

    private func filteredCandidates(
        _ candidates: [LastFMSimilarTrack],
        seed: RecommendationSeed,
        excluding excludedSongIdentities: Set<RecommendationSongIdentity>
    ) -> [RankedSong] {
        let seedIdentity = seed.songIdentity
        var seen = excludedSongIdentities
        seen.insert(seedIdentity)
        var versionSurvivorCount = 0
        var filtered: [RankedSong] = []

        for track in candidates {
            let artist = SongNormalization.humanReadable(track.artist)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = SongNormalization.humanReadable(track.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = RecommendationSongIdentity(artist: artist, title: title)
            guard !artist.isEmpty, !title.isEmpty else {
                recommendationLog("rejected missing artist/title")
                continue
            }
            guard !isAlternateVersion(title, identity: identity, existing: seen) else {
                recommendationLog("rejected existing-song version=\(artist) - \(title)")
                continue
            }
            versionSurvivorCount += 1
            guard seen.insert(identity).inserted else {
                recommendationLog("rejected session duplicate=\(artist) - \(title)")
                continue
            }

#if DEBUG
            print("[Recommendations] candidate=\(artist) - \(title) match=\(String(format: "%.2f", track.match))")
#endif
            filtered.append(RankedSong(
                track: LastFMSimilarTrack(
                    artist: artist,
                    title: title,
                    match: track.match,
                    url: track.url
                ),
                identity: identity
            ))
        }

#if DEBUG
        print("[Recommendations] candidates received=\(candidates.count)")
        print("[Recommendations] candidates after song-level dedupe=\(filtered.count)")
        print("[Recommendations] candidates after version filtering=\(versionSurvivorCount)")
        if filtered.isEmpty {
            print("[Recommendations] all candidates filtered")
        }
#endif
        return filtered
    }

    private func rankedSongOrder(_ lhs: RankedSong, _ rhs: RankedSong) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.identity.artist != rhs.identity.artist {
            return lhs.identity.artist < rhs.identity.artist
        }
        return lhs.identity.title < rhs.identity.title
    }

    private func isAlternateVersion(
        _ title: String,
        identity: RecommendationSongIdentity,
        existing: Set<RecommendationSongIdentity>
    ) -> Bool {
        let normalizedTitle = SongNormalization.text(title)
        guard SongNormalization.containsVersionMarker(normalizedTitle) else {
            return false
        }
        return existing.contains(identity)
    }

    func resolveOnYouTube(
        _ target: LastFMSimilarTrack,
        attempt: RecommendationYouTubeResolutionAttempt = .primaryOnly()
    ) async throws -> ResolvedRecommendation? {
        guard case .resolved(let recommendation) = try await resolveCandidate(
            target,
            attempt: attempt
        ) else {
            return nil
        }
        return recommendation
    }

    private func resolveCandidate(
        _ target: LastFMSimilarTrack,
        attempt: RecommendationYouTubeResolutionAttempt
    ) async throws -> RecommendationCandidateResolution {
#if DEBUG
        print("[YouTubeResolver] attempting=\(target.artist) - \(target.title)")
#endif
        let identity = SongIdentity(artist: target.artist, title: target.title)
        let cachedResult: YouTubeSearchResult?
        switch attempt {
        case .cacheOnly:
            cachedResult = await resolutionCache.peek(for: identity, now: .now)
        case .primaryOnly, .officialFallback:
            cachedResult = await resolutionCache.result(for: identity, now: .now)
        }
        if let cachedResult {
#if DEBUG
            print(
                "[IDResolver] source=cache "
                    + "target=\(target.artist) - \(target.title)"
            )
#endif
            return .resolved(resolvedRecommendation(target: target, result: cachedResult))
        }

        let query = "\(target.artist) \(target.title)"
        let results: [YouTubeSearchResult]
        switch attempt {
        case .cacheOnly:
            return .temporarilyUnavailable
        case .primaryOnly(let context):
            guard !videoResolver.isWebSearchCircuitOpen else {
                return .temporarilyUnavailable
            }
            let outcome = try await videoResolver.primaryOutcome(
                query: query,
                isActive: { context?.isActive ?? true }
            )
            switch outcome {
            case .results(let primaryResults):
                results = primaryResults
            case .temporarilyUnavailable, .blocked, .parserFailure, .circuitOpen:
                return .temporarilyUnavailable
            }
        case .officialFallback(let context):
            let outcome = try await videoResolver.dataAPIFallbackOutcome(
                query: query,
                context: context
            )
            switch outcome {
            case .results(let fallbackResults):
                results = fallbackResults
            case .unavailable:
                return .fallbackUnavailable
            }
        }
        if let best = bestYouTubeResult(in: results, target: target) {
#if DEBUG
            print("[YouTubeResolver] resolved=\(best.youtubeVideoID)")
#endif
            let source: YouTubeResolutionKnowledgeSource
            switch attempt {
            case .primaryOnly:
                source = .structured
#if DEBUG
                print(
                    "[IDResolver] source=structured resolved=\(best.youtubeVideoID) "
                        + "target=\(query)"
                )
#endif
            case .officialFallback:
                source = .officialAPI
#if DEBUG
                print("[IDResolver] source=officialAPI target=\(query)")
#endif
            case .cacheOnly:
                source = .legacy
            }
            await resolutionCache.learn(
                identity,
                videoID: best.youtubeVideoID,
                metadata: YouTubeResolutionMetadata(best),
                source: source,
                now: .now
            )
            return .resolved(resolvedRecommendation(target: target, result: best))
        }
#if DEBUG
        if case .primaryOnly = attempt {
            let reason = results.isEmpty ? "zeroExtractedCandidates" : "noConfidentMatch"
            print(
                "[RecommendationResolver] structuredMiss reason=\(reason) "
                    + "candidates=\(results.count) target=\(query)"
            )
        } else if case .officialFallback = attempt {
            print("[YouTubeResolver] no canonical match target=\(target.artist) - \(target.title)")
        }
        print("[IDResolver] unresolved target=\(query)")
#endif
        return .candidateMiss
    }

    func invalidateVideoResolution(for identity: SongIdentity) async {
        await resolutionCache.remove(identity)
    }

    private func bestYouTubeResult(
        in results: [YouTubeSearchResult],
        target: LastFMSimilarTrack
    ) -> YouTubeSearchResult? {
        results.compactMap { result -> RankedYouTubeResult? in
            guard let score = youtubeScore(result, target: target) else {
#if DEBUG
                print(
                    "[IDResolver] candidateScore=rejected target=\(target.artist) - \(target.title) "
                        + "candidate=\(result.title) videoID=\(result.youtubeVideoID)"
                )
#endif
                return nil
            }
#if DEBUG
            print(
                "[IDResolver] candidateScore=\(score) target=\(target.artist) - \(target.title) "
                    + "candidate=\(result.title) videoID=\(result.youtubeVideoID)"
            )
#endif
            return RankedYouTubeResult(result: result, score: score)
        }.sorted { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.result.youtubeVideoID < rhs.result.youtubeVideoID
                : lhs.score > rhs.score
        }.first?.result
    }

    private func resolvedRecommendation(
        target: LastFMSimilarTrack,
        result: YouTubeSearchResult
    ) -> ResolvedRecommendation {
        return ResolvedRecommendation(
            artist: target.artist,
            title: target.title,
            match: target.match,
            youtubeResult: result
        )
    }

    private func safelyResolveCandidate(
        _ target: LastFMSimilarTrack,
        attempt: RecommendationYouTubeResolutionAttempt
    ) async throws -> RecommendationCandidateResolution {
        do {
            return try await resolveCandidate(target, attempt: attempt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recommendationLog(
                "YouTube resolution failed target=\(target.artist) - \(target.title) error=\(error.localizedDescription)"
            )
            return .temporarilyUnavailable
        }
    }

    func youtubeScore(
        _ result: YouTubeSearchResult,
        target: LastFMSimilarTrack
    ) -> Int? {
        youtubeScore(result, target: target, expectedDuration: nil)
    }

    func youtubeScore(
        _ result: YouTubeSearchResult,
        target: LastFMSimilarTrack,
        expectedDuration: TimeInterval?
    ) -> Int? {
        let resultText = SongNormalization.text(result.title)
        let channel = SongNormalization.text(result.channelTitle)
        let targetArtist = SongNormalization.text(target.artist)
        let targetTitle = SongNormalization.text(target.title)
        let targetArtistTokens = Set(targetArtist.split(separator: " ").map(String.init))
        let targetTitleTokens = SongNormalization.meaningfulTokens(target.title)
        let resultTokens = SongNormalization.meaningfulTokens(result.title)

        guard !targetArtist.isEmpty, !targetTitleTokens.isEmpty else {
            return nil
        }
        guard targetTitleTokens.isSubset(of: resultTokens) else {
            return nil
        }
        guard SongNormalization.baseTitle(
            result.title,
            removingArtist: target.artist
        ) == SongNormalization.baseTitle(target.title) else {
            return nil
        }

        let resultArtistTokens = Set(resultText.split(separator: " ").map(String.init))
        let channelTokens = Set(channel.split(separator: " ").map(String.init))
        let cleanedChannel = SongNormalization.text(SongNormalization.artist(result.channelTitle))
        let cleanedChannelTokens = Set(cleanedChannel.split(separator: " ").map(String.init))
        let artistInTitle = targetArtistTokens.isSubset(of: resultArtistTokens)
        let artistInChannel = targetArtistTokens.isSubset(of: channelTokens)
            || (!cleanedChannelTokens.isEmpty
                && cleanedChannelTokens.isSubset(of: targetArtistTokens))
        guard artistInTitle || artistInChannel else {
            return nil
        }

        let targetAllowsLive = targetTitle.contains("live")
        let targetAllowsRemix = targetTitle.contains("remix")
        let hardRejects = ["reaction", "interview", "tutorial", "nightcore", "8d audio", "shorts"]
        guard !hardRejects.contains(where: resultText.contains) else {
            return nil
        }
        let versionRejects = ["karaoke", "cover", "slowed", "sped up", "speed up", "instrumental"]
        guard !versionRejects.contains(where: { marker in
            resultText.contains(marker) && !targetTitle.contains(marker)
        }) else {
            return nil
        }
        if resultText.contains(" live"), !targetAllowsLive {
            return nil
        }
        if resultText.contains("remix"), !targetAllowsRemix {
            return nil
        }

        var score = 200
        score += artistInTitle ? 55 : 45

        if channel == targetArtist || channel == "\(targetArtist) topic" {
            score += 35
        }
        if resultText.contains("official music video") {
            score += 30
        } else if resultText.contains("official audio") {
            score += 28
        } else if channel.hasSuffix(" topic") {
            score += 26
        } else if resultText.contains("official video") {
            score += 24
        }
        if resultText.contains("lyric") || resultText.contains("lyrics") {
            score -= 12
        }
        if let expectedDuration,
           expectedDuration > 0,
           let candidateDuration = result.duration,
           candidateDuration > 0 {
            let difference = abs(expectedDuration - candidateDuration)
            if difference <= 4 {
                score += 30
            } else if difference <= 12 {
                score += 15
            } else if difference >= 60 {
                score -= 35
            }
        }
        return score >= 220 ? score : nil
    }

    private func normalizedVideoID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recommendationLog(_ message: String) {
#if DEBUG
        print("[Recommendations] \(message)")
#endif
    }
}

enum SongNormalization {
    private static let displayNoise = [
        "official lyric video", "official music video", "official visualizer",
        "official lyrics", "official video", "official audio", "lyric video",
        "official 4k video", "official hd video", "visualizer", "lyrics",
        "audio", "hd", "4k"
    ]
    private static let versionMarkers = [
        "live", "remix", "acoustic", "demo", "unreleased", "leak", "leaked",
        "snippet", "slowed", "slowed reverb", "slowed + reverb", "sped up",
        "speed up", "nightcore", "cover", "karaoke", "instrumental", "remaster",
        "remastered", "alternate version", "version"
    ]

    static func artist(_ value: String) -> String {
        var result = humanReadable(value).trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(
            of: #"(?i)\s*-\s*topic\s*$"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)vevo\s*$"#,
            with: "",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func vevoArtist(_ value: String) -> String? {
        let channel = humanReadable(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            channel.range(of: #"(?i)^[\p{L}\p{N}][\p{L}\p{N}.'’_-]{2,}vevo$"#,
                          options: .regularExpression) != nil
        else {
            return nil
        }
        var base = String(channel.dropLast(4))
        base = base.replacingOccurrences(
            of: #"(?<=[\p{Ll}\p{N}])(?=\p{Lu})"#,
            with: " ",
            options: .regularExpression
        )
        base = base.replacingOccurrences(of: "_", with: " ")
        let cleaned = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.rangeOfCharacter(from: .letters) == nil ? nil : cleaned
    }

    static func displayTitle(_ value: String) -> String {
        var result = humanReadable(value).trimmingCharacters(in: .whitespacesAndNewlines)
        let alternatives = displayNoise.joined(separator: "|")
        let patterns = [
            "(?i)\\s*[\\(\\[]\\s*(?:\(alternatives))\\s*[\\)\\]]",
            "(?i)\\s*[-–—|]\\s*(?:\(alternatives))\\s*$",
            "(?i)\\s+(?:\(alternatives))\\s*$"
        ]

        var changed = true
        while changed {
            let previous = result
            for pattern in patterns {
                result = result.replacingOccurrences(
                    of: pattern,
                    with: "",
                    options: .regularExpression
                )
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            changed = result != previous
        }
        return result
    }

    static func humanReadable(_ value: String) -> String {
        MusicMetadataText.decoded(value)
    }

    static func displayTitle(_ value: String, removingArtist artist: String) -> String {
        var result = displayTitle(value)
        guard !artist.isEmpty else {
            return result
        }
        if let separator = result.range(
            of: #"\s[-–—]\s"#,
            options: .regularExpression
        ) {
            let prefix = String(result[..<separator.lowerBound])
            if text(prefix) == text(artist) {
                return result[separator.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let escapedArtist = NSRegularExpression.escapedPattern(for: artist)
        result = result.replacingOccurrences(
            of: "(?i)^\\s*\(escapedArtist)\\s*[-–—:|]\\s*",
            with: "",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingFeaturedArtistCredit(from value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"(?i)\s*[\(\[]\s*(?:ft\.?|feat\.?|featuring)\s+.+[\)\]]\s*$"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\s+(?:ft\.?|feat\.?|featuring)\s+.+$"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\s*[\(\[]\s*with\s+.+[\)\]]\s*$"#,
            with: "",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingTrailingProductionCredit(from value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"(?i)\s*[\(\[]\s*(?:prod\.?|produced\s+by)\s+[^\)\]]+[\)\]]\s*$"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\s*[-–—]\s*(?:prod\.?|produced\s+by)\s+.+$"#,
            with: "",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func text(_ value: String) -> String {
        humanReadable(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func baseTitle(_ value: String, removingArtist artist: String? = nil) -> String {
        var cleaned = removingFeaturedArtistCredit(from: displayTitle(value))
        let alternatives = versionMarkers.joined(separator: "|")
        let patterns = [
            "(?i)\\s*[\\(\\[]\\s*(?:\(alternatives))(?:\\s+version)?\\s*[\\)\\]]\\s*$",
            "(?i)\\s*[-–—|]\\s*(?:\(alternatives))(?:\\s+version)?\\s*$"
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        if let artist {
            cleaned = displayTitle(cleaned, removingArtist: artist)
        }
        return text(cleaned)
    }

    static func meaningfulTokens(_ value: String) -> Set<String> {
        Set(text(value).split(separator: " ").map(String.init)).subtracting([
            "the", "a", "an", "and", "feat", "ft", "featuring",
            "official", "music", "video", "audio", "lyrics", "lyric"
        ])
    }

    static func containsVersionMarker(_ normalizedTitle: String) -> Bool {
        versionMarkers.contains { marker in
            normalizedTitle == marker
                || normalizedTitle.hasPrefix("\(marker) ")
                || normalizedTitle.hasSuffix(" \(marker)")
                || normalizedTitle.contains(" \(marker) ")
        }
    }
}
