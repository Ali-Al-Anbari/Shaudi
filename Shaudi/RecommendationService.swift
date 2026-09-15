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

    init(
        youtubeVideoID: String,
        rawTitle: String,
        displayedArtist: String?,
        sourceChannel: String?,
        userArtistOverride: String?
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
            userArtistOverride: userArtistOverride
        )
        cleanedArtist = identity.artist
        cleanedTitle = identity.title
        fallbackTitle = identity.fallbackTitle
        artistSource = identity.artistSource

#if DEBUG
        print(
            "[RecommendationIdentity] source=manualSearch rawTitle=\(rawTitle) "
                + "rawChannel=\(sourceChannel ?? "")"
        )
        print(
            "[RecommendationIdentity] canonicalArtist=\(identity.artist) "
                + "canonicalTitle=\(identity.title) artistSource=\(identity.artistSource.rawValue)"
        )
#endif
    }

    init(
        youtubeVideoID: String,
        canonicalIdentity: SongIdentity,
        youtubeTitle: String,
        youtubeChannel: String
    ) {
        self.youtubeVideoID = youtubeVideoID
        rawTitle = youtubeTitle
        displayedArtist = canonicalIdentity.artist
        sourceChannel = youtubeChannel
        userArtistOverride = nil
        cleanedArtist = canonicalIdentity.artist
        cleanedTitle = canonicalIdentity.title
        fallbackTitle = nil
        artistSource = .lastFM

#if DEBUG
        print(
            "[RecommendationIdentity] source=lastFM "
                + "canonicalArtist=\(canonicalIdentity.artist) "
                + "canonicalTitle=\(canonicalIdentity.title) reparseSkipped=true"
        )
#endif
    }

    var songIdentity: RecommendationSongIdentity {
        RecommendationSongIdentity(artist: cleanedArtist, title: cleanedTitle)
    }
}

enum RecommendationSeedArtistSource: String {
    case lastFM
    case userOverride
    case titlePrefix
    case topicChannel
    case channelFallback
}

private struct RecommendationSeedIdentity {
    let artist: String
    let title: String
    let fallbackTitle: String?
    let artistSource: RecommendationSeedArtistSource
}

private enum RecommendationSeedIdentityResolver {
    static func resolve(
        rawTitle: String,
        displayedArtist: String?,
        channel: String?,
        userArtistOverride: String?
    ) -> RecommendationSeedIdentity {
        let cleanedRawTitle = SongNormalization.displayTitle(rawTitle)
        let parsedTitle = parsedArtistAndTitle(from: cleanedRawTitle)
        let override = nonempty(userArtistOverride).map { SongNormalization.artist($0) }
        let cleanedChannel = nonempty(channel).map { SongNormalization.artist($0) }
        let cleanedDisplayArtist = nonempty(displayedArtist).map {
            SongNormalization.artist($0)
        }

        let artist: String
        let artistSource: RecommendationSeedArtistSource
        if let override, !override.isEmpty {
            artist = override
            artistSource = .userOverride
        } else if let parsedTitle {
            artist = parsedTitle.artist
            artistSource = .titlePrefix
        } else if let channel, isTopicChannel(channel), let cleanedChannel {
            artist = cleanedChannel
            artistSource = .topicChannel
        } else {
            artist = cleanedDisplayArtist ?? cleanedChannel ?? ""
            artistSource = .channelFallback
        }

        let titleWithFeatures: String
        if override != nil {
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
            artistSource: artistSource
        )
    }

    private static func parsedArtistAndTitle(
        from value: String
    ) -> (artist: String, title: String)? {
        guard let separatorRange = value.range(
            of: #"\s[-–—]\s"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let artist = value[..<separatorRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = value[separatorRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let artistWordCount = artist.split(whereSeparator: \.isWhitespace).count
        guard
            !artist.isEmpty,
            !title.isEmpty,
            artist.count <= 80,
            (1...10).contains(artistWordCount),
            artist.rangeOfCharacter(from: .alphanumerics) != nil,
            title.rangeOfCharacter(from: .alphanumerics) != nil
        else {
            return nil
        }

        return (SongNormalization.artist(artist), title)
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
    private struct RankedSong {
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
        _ limit: Int
    ) async throws -> [LastFMSimilarTrack]

    private let similarTracksOperation: SimilarTracksOperation
    private let videoResolver: YouTubeRecommendationResolver
    private let resolutionCache: any YouTubeResolutionCaching
    private let resultLimit = RecommendationRadioPolicy.targetUpcomingCount
    private let candidatePoolLimit = RecommendationRadioPolicy.candidatePoolSize
    private let youtubeResolutionLimit = 12
    private let reservoirCandidateLimit = RecommendationRadioPolicy.candidatePoolSize

    init() {
        let lastFMService = LastFMRecommendationService()
        similarTracksOperation = { artist, title, limit in
            try await lastFMService.similarTracks(
                artist: artist,
                title: title,
                limit: limit
            )
        }
        videoResolver = YouTubeRecommendationResolver()
        resolutionCache = PersistentYouTubeResolutionCache.shared
    }

    init(
        similarTracks: @escaping SimilarTracksOperation,
        videoResolver: YouTubeRecommendationResolver,
        resolutionCache: any YouTubeResolutionCaching
    ) {
        similarTracksOperation = similarTracks
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
        print("[Recommendations] seed=\(seedArtist) - \(seedTitle)")
#endif
        let candidates = try await similarTracks(for: seed)
        let ranked = filteredCandidates(
            candidates,
            seed: seed,
            excluding: excludingSongIdentities
        ).sorted(by: rankedSongOrder)
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

    private func similarTracks(
        for seed: RecommendationSeed
    ) async throws -> [LastFMSimilarTrack] {
        do {
            let primary = try await similarTracksOperation(
                seed.cleanedArtist,
                seed.cleanedTitle,
                candidatePoolLimit
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
                candidatePoolLimit
            )
        } catch let error as LastFMRecommendationService.ServiceError {
            guard
                error.permitsAlternateSeedRetry,
                let fallbackTitle = usableFallbackTitle(for: seed)
            else {
                throw error
            }

#if DEBUG
            print("[LastFM] primary seed failed reason=\(error.localizedDescription)")
            print("[LastFM] retry artist=\(seed.cleanedArtist) track=\(fallbackTitle)")
#endif
            return try await similarTracksOperation(
                seed.cleanedArtist,
                fallbackTitle,
                candidatePoolLimit
            )
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
                "[RecommendationResolver] cacheHit=true "
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
            await resolutionCache.store(best, for: identity, now: .now)
            return .resolved(resolvedRecommendation(target: target, result: best))
        }
#if DEBUG
        if case .primaryOnly = attempt {
            print("[RecommendationResolver] webMiss reason=candidateSpecificMiss target=\(query)")
        } else if case .officialFallback = attempt {
            print("[YouTubeResolver] no canonical match target=\(target.artist) - \(target.title)")
        }
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
                return nil
            }
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
        return score
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
        "live", "remix", "acoustic", "sped up", "speed up", "slowed",
        "cover", "karaoke", "instrumental"
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
        value.replacingOccurrences(
            of: #"(?i)\s*[\(\[]\s*(?:prod\.?|produced\s+by)\s+[^\)\]]+[\)\]]\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
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
