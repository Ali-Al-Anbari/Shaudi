//
//  PlaylistRecommendationService.swift
//  Shaudi
//

import Foundation
import SwiftData

struct PlaylistVibeProfile {
    let representativeAnchors: [RecommendationSeed]
    let existingIdentities: Set<SongIdentity>
    let existingVideoIDs: Set<String>
    let artistFrequencies: [String: Int]
    let cachedGenres: [String]
    let totalTracks: Int
    let uniqueArtistCount: Int

    static func build(from tracks: [Track], rotation: Int = 0) -> PlaylistVibeProfile {
        var existingIdentities = Set<SongIdentity>()
        var existingVideoIDs = Set<String>()
        var validSeeds: [RecommendationSeed] = []
        var artistFrequencies: [String: Int] = [:]
        var allGenres: [String] = []

        for track in tracks {
            let videoID = track.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !videoID.isEmpty {
                existingVideoIDs.insert(videoID)
            }

            let seed = RecommendationSeed(persistedTrack: track)

            guard !seed.cleanedArtist.isEmpty, !seed.cleanedTitle.isEmpty else {
                continue
            }

            existingIdentities.insert(seed.songIdentity)
            validSeeds.append(seed)

            let normArtist = SongNormalization.text(seed.cleanedArtist)
            artistFrequencies[normArtist, default: 0] += 1
            allGenres.append(contentsOf: track.cachedGenreTags)
        }

        var seenIdentities = Set<SongIdentity>()
        var uniqueSeeds: [RecommendationSeed] = []
        for seed in validSeeds {
            if seenIdentities.insert(seed.songIdentity).inserted {
                uniqueSeeds.append(seed)
            }
        }

        let anchors = selectRepresentativeAnchors(from: uniqueSeeds, rotation: rotation)

        return PlaylistVibeProfile(
            representativeAnchors: anchors,
            existingIdentities: existingIdentities,
            existingVideoIDs: existingVideoIDs,
            artistFrequencies: artistFrequencies,
            cachedGenres: Array(Set(allGenres)),
            totalTracks: tracks.count,
            uniqueArtistCount: artistFrequencies.count
        )
    }

    static func selectRepresentativeAnchors(
        from seeds: [RecommendationSeed],
        rotation: Int = 0
    ) -> [RecommendationSeed] {
        guard !seeds.isEmpty else { return [] }
        if seeds.count == 1 { return seeds }
        if seeds.count <= 3 { return seeds }

        var artistMap: [String: [RecommendationSeed]] = [:]
        var artistOrder: [String] = []
        for seed in seeds {
            let normArtist = SongNormalization.text(seed.cleanedArtist)
            if artistMap[normArtist] == nil {
                artistOrder.append(normArtist)
            }
            artistMap[normArtist, default: []].append(seed)
        }

        var sortedArtists = artistOrder.sorted { a1, a2 in
            let count1 = artistMap[a1]?.count ?? 0
            let count2 = artistMap[a2]?.count ?? 0
            if count1 != count2 {
                return count1 > count2
            }
            return a1 < a2
        }

        if rotation > 0 && sortedArtists.count > 1 {
            let offset = rotation % sortedArtists.count
            sortedArtists = Array(sortedArtists[offset...] + sortedArtists[..<offset])
        }

        let targetAnchorCount = min(5, seeds.count)
        var selected: [RecommendationSeed] = []
        var artistPointers: [String: Int] = [:]

        while selected.count < targetAnchorCount {
            var addedInRound = false
            for artist in sortedArtists {
                guard selected.count < targetAnchorCount else { break }
                guard let tracksForArtist = artistMap[artist] else { continue }
                let pointer = artistPointers[artist, default: 0]
                if pointer < tracksForArtist.count {
                    selected.append(tracksForArtist[pointer])
                    artistPointers[artist] = pointer + 1
                    addedInRound = true
                }
            }
            if !addedInRound {
                break
            }
        }

        return selected
    }
}

struct ScoredPlaylistCandidate: Hashable {
    let track: LastFMSimilarTrack
    let identity: SongIdentity
    let score: Double
    let supportingAnchorCount: Int
}

struct PlaylistRecommendationResult {
    var visibleRecommendations: [ResolvedRecommendation]
    var spareResolved: [ResolvedRecommendation]
    var deferredCandidates: [ScoredPlaylistCandidate]

    var canFindMore: Bool {
        visibleRecommendations.count < 5 && !deferredCandidates.isEmpty
    }
}

@MainActor
final class PlaylistRejectionStore {
    static let shared = PlaylistRejectionStore()

    private let defaults: UserDefaults
    private let maxRejections = 100

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for playlistID: String) -> String {
        "shaudi.playlist.rejections.\(playlistID)"
    }

    func isRejected(_ identity: SongIdentity, videoID: String? = nil, for playlistID: String) -> Bool {
        let keys = defaults.stringArray(forKey: key(for: playlistID)) ?? []
        let keySet = Set(keys)
        if keySet.contains(identity.cacheKey) {
            return true
        }
        if let videoID, !videoID.isEmpty, keySet.contains("video:\(videoID)") {
            return true
        }
        return false
    }

    func reject(_ identity: SongIdentity, videoID: String? = nil, for playlistID: String) {
        let storageKey = key(for: playlistID)
        var keys = defaults.stringArray(forKey: storageKey) ?? []
        keys.removeAll { $0 == identity.cacheKey || (videoID != nil && $0 == "video:\(videoID!)") }
        keys.insert(identity.cacheKey, at: 0)
        if let videoID, !videoID.isEmpty {
            keys.insert("video:\(videoID)", at: 1)
        }
        if keys.count > maxRejections {
            keys = Array(keys.prefix(maxRejections))
        }
        defaults.set(keys, forKey: storageKey)
    }

    func clearRejections(for playlistID: String) {
        defaults.removeObject(forKey: key(for: playlistID))
    }
}

@MainActor
final class PlaylistRecommendationCache {
    struct Entry {
        let result: PlaylistRecommendationResult
        let trackSignature: [String]
        let timestamp: Date
    }

    private var storage: [String: Entry] = [:]

    func get(playlistID: String, trackSignature: [String]) -> PlaylistRecommendationResult? {
        guard let entry = storage[playlistID] else { return nil }
        guard entry.trackSignature == trackSignature else {
            storage.removeValue(forKey: playlistID)
            return nil
        }
        return entry.result
    }

    func set(playlistID: String, trackSignature: [String], result: PlaylistRecommendationResult) {
        storage[playlistID] = Entry(
            result: result,
            trackSignature: trackSignature,
            timestamp: Date()
        )
    }

    func updateResult(for playlistID: String, result: PlaylistRecommendationResult) {
        if let existing = storage[playlistID] {
            storage[playlistID] = Entry(
                result: result,
                trackSignature: existing.trackSignature,
                timestamp: existing.timestamp
            )
        }
    }

    func remove(playlistID: String) {
        storage.removeValue(forKey: playlistID)
    }

    func clear() {
        storage.removeAll()
    }
}

@MainActor
final class PlaylistRecommendationService {
    static let shared = PlaylistRecommendationService()

    typealias SimilarTracksOperation = (
        _ artist: String,
        _ title: String,
        _ limit: Int,
        _ isFallback: Bool
    ) async throws -> [LastFMSimilarTrack]

    typealias SafeResolverOperation = (
        _ candidate: LastFMSimilarTrack
    ) async throws -> ResolvedRecommendation?

    typealias OfficialResolverOperation = (
        _ candidate: LastFMSimilarTrack
    ) async throws -> ResolvedRecommendation?

    private let similarTracksOperation: SimilarTracksOperation
    private let safeResolverOperation: SafeResolverOperation
    private let officialResolverOperation: OfficialResolverOperation
    private let feedbackStore: RecommendationFeedbackStore
    private let personalizationStore: RecommendationPersonalizationStore
    let rejectionStore: PlaylistRejectionStore
    let cache: PlaylistRecommendationCache

    convenience init() {
        self.init(
            feedbackStore: .shared,
            personalizationStore: .shared,
            rejectionStore: .shared,
            cache: PlaylistRecommendationCache()
        )
    }

    convenience init(
        similarTracks: @escaping SimilarTracksOperation,
        safeResolve: @escaping SafeResolverOperation,
        officialResolve: @escaping OfficialResolverOperation = { _ in nil }
    ) {
        self.init(
            similarTracks: similarTracks,
            safeResolve: safeResolve,
            officialResolve: officialResolve,
            feedbackStore: .shared,
            personalizationStore: .shared,
            rejectionStore: PlaylistRejectionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            cache: PlaylistRecommendationCache()
        )
    }

    convenience init(
        feedbackStore: RecommendationFeedbackStore,
        personalizationStore: RecommendationPersonalizationStore
    ) {
        self.init(
            feedbackStore: feedbackStore,
            personalizationStore: personalizationStore,
            rejectionStore: .shared,
            cache: PlaylistRecommendationCache()
        )
    }

    convenience init(
        feedbackStore: RecommendationFeedbackStore,
        personalizationStore: RecommendationPersonalizationStore,
        rejectionStore: PlaylistRejectionStore
    ) {
        self.init(
            feedbackStore: feedbackStore,
            personalizationStore: personalizationStore,
            rejectionStore: rejectionStore,
            cache: PlaylistRecommendationCache()
        )
    }

    init(
        feedbackStore: RecommendationFeedbackStore,
        personalizationStore: RecommendationPersonalizationStore,
        rejectionStore: PlaylistRejectionStore,
        cache: PlaylistRecommendationCache
    ) {
        let lastFMService = LastFMRecommendationService()
        let recService = RecommendationService(
            feedbackStore: feedbackStore,
            personalizationStore: personalizationStore
        )
        self.similarTracksOperation = { artist, title, limit, isFallback in
            try await lastFMService.similarTracks(
                artist: artist,
                title: title,
                limit: limit,
                isFallback: isFallback
            )
        }
        self.safeResolverOperation = { candidate in
            try await recService.resolveOnYouTube(candidate, attempt: .primaryOnly())
        }
        self.officialResolverOperation = { candidate in
            let context = RecommendationResolutionContext(
                sessionID: UUID(),
                epochID: UUID(),
                upcomingCount: 0
            )
            return try await recService.resolveOnYouTube(candidate, attempt: .officialFallback(context))
        }
        self.feedbackStore = feedbackStore
        self.personalizationStore = personalizationStore
        self.rejectionStore = rejectionStore
        self.cache = cache
    }

    init(
        similarTracks: @escaping SimilarTracksOperation,
        safeResolve: @escaping SafeResolverOperation,
        officialResolve: @escaping OfficialResolverOperation,
        feedbackStore: RecommendationFeedbackStore,
        personalizationStore: RecommendationPersonalizationStore,
        rejectionStore: PlaylistRejectionStore,
        cache: PlaylistRecommendationCache
    ) {
        self.similarTracksOperation = similarTracks
        self.safeResolverOperation = safeResolve
        self.officialResolverOperation = officialResolve
        self.feedbackStore = feedbackStore
        self.personalizationStore = personalizationStore
        self.rejectionStore = rejectionStore
        self.cache = cache
    }

    func recommendations(
        for tracks: [Track],
        playlistID: String? = nil,
        rotation: Int = 0,
        forceRefresh: Bool = false,
        currentTracks: (() -> [Track])? = nil,
        isCurrent: () -> Bool = { true }
    ) async throws -> PlaylistRecommendationResult {
        let signature = trackSignature(for: tracks)

        if !forceRefresh, let playlistID {
            if let cached = cache.get(playlistID: playlistID, trackSignature: signature) {
                try validateRequest(signature: signature, currentTracks: currentTracks?() ?? tracks, isCurrent: isCurrent)
                let valid = revalidate(cached, for: currentTracks?() ?? tracks, playlistID: playlistID)
                if !cached.visibleRecommendations.isEmpty
                    && valid.visibleRecommendations.isEmpty
                    && valid.deferredCandidates.isEmpty {
                    cache.remove(playlistID: playlistID)
                } else {
                    cache.updateResult(for: playlistID, result: valid)
#if DEBUG
                    print("[PlaylistRecommendations] cache hit playlistID=\(playlistID)")
                    print("[PlaylistRecommendations] visible result count=\(valid.visibleRecommendations.count)")
#endif
                    return valid
                }
            }
        }

        let profile = PlaylistVibeProfile.build(from: tracks, rotation: rotation)
        guard !profile.representativeAnchors.isEmpty else {
            return PlaylistRecommendationResult(
                visibleRecommendations: [],
                spareResolved: [],
                deferredCandidates: []
            )
        }

        let candidates = try await fetchAndRankCandidates(profile: profile, playlistID: playlistID)
        guard !candidates.isEmpty else {
            return PlaylistRecommendationResult(
                visibleRecommendations: [],
                spareResolved: [],
                deferredCandidates: []
            )
        }

        let diverseCandidates = applyArtistDiversity(to: candidates)
        let (resolved, deferred) = try await resolveCandidatesSafely(
            diverseCandidates,
            existingVideoIDs: profile.existingVideoIDs,
            existingIdentities: profile.existingIdentities,
            playlistID: playlistID
        )

        let visible = Array(resolved.prefix(5))
        let spare = Array(resolved.dropFirst(5))
        let result = PlaylistRecommendationResult(
            visibleRecommendations: visible,
            spareResolved: spare,
            deferredCandidates: deferred
        )
        try validateRequest(signature: signature, currentTracks: currentTracks?() ?? tracks, isCurrent: isCurrent)
        let valid = revalidate(result, for: currentTracks?() ?? tracks, playlistID: playlistID)

#if DEBUG
        print("[PlaylistRecommendations] visible result count=\(result.visibleRecommendations.count)")
        if result.canFindMore {
            print("[PlaylistRecommendations] findMore available deferredCount=\(result.deferredCandidates.count)")
        }
#endif

        if let playlistID {
            cache.set(playlistID: playlistID, trackSignature: signature, result: valid)
        }

        return valid
    }

    func findMore(
        for tracks: [Track],
        playlistID: String?,
        currentResult: PlaylistRecommendationResult,
        currentTracks: (() -> [Track])? = nil,
        isCurrent: () -> Bool = { true }
    ) async throws -> PlaylistRecommendationResult {
        let signature = trackSignature(for: tracks)
        try validateRequest(signature: signature, currentTracks: currentTracks?() ?? tracks, isCurrent: isCurrent)
        let startingResult = revalidate(currentResult, for: tracks, playlistID: playlistID)
        let neededCount = max(0, 5 - startingResult.visibleRecommendations.count)
        guard neededCount > 0, !startingResult.deferredCandidates.isEmpty else {
            return startingResult
        }

#if DEBUG
        print("[PlaylistRecommendations] officialSearch requestedByUser=true needed=\(neededCount)")
#endif

        var visible = startingResult.visibleRecommendations
        var remainingDeferred = startingResult.deferredCandidates
        let profile = PlaylistVibeProfile.build(from: tracks)
        var seenVideoIDs = profile.existingVideoIDs.union(
            visible.map { $0.youtubeResult.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        var seenIdentities = profile.existingIdentities.union(visible.map(\.songIdentity))

        while !remainingDeferred.isEmpty && visible.count < 5 {
            try validateRequest(signature: signature, currentTracks: currentTracks?() ?? tracks, isCurrent: isCurrent)
            let candidate = remainingDeferred.removeFirst()

            if !allows(candidate, profile: profile, playlistID: playlistID)
                || seenIdentities.contains(candidate.identity) {
                continue
            }

#if DEBUG
            print("[PlaylistRecommendations] official fallback used target=\(candidate.identity.artist) - \(candidate.identity.title)")
#endif
            guard let recommendation = try await officialResolverOperation(candidate.track) else {
                continue
            }
            try validateRequest(signature: signature, currentTracks: currentTracks?() ?? tracks, isCurrent: isCurrent)

            let videoID = recommendation.youtubeResult.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !videoID.isEmpty,
                  !seenVideoIDs.contains(videoID),
                  !seenIdentities.contains(recommendation.songIdentity),
                  allows(recommendation, profile: profile, playlistID: playlistID) else {
                continue
            }
            seenVideoIDs.insert(videoID)
            seenIdentities.insert(recommendation.songIdentity)
            visible.append(recommendation)
        }

        let updated = PlaylistRecommendationResult(
            visibleRecommendations: visible,
            spareResolved: startingResult.spareResolved,
            deferredCandidates: remainingDeferred
        )
        try validateRequest(signature: signature, currentTracks: currentTracks?() ?? tracks, isCurrent: isCurrent)
        let valid = revalidate(updated, for: currentTracks?() ?? tracks, playlistID: playlistID)

#if DEBUG
        print("[PlaylistRecommendations] visible result count=\(updated.visibleRecommendations.count)")
#endif

        if let playlistID {
            cache.set(playlistID: playlistID, trackSignature: signature, result: valid)
        }

        return valid
    }

    func rejectRecommendation(
        _ item: ResolvedRecommendation,
        from currentResult: PlaylistRecommendationResult,
        playlistID: String,
        currentTracks: [Track]? = nil
    ) -> PlaylistRecommendationResult {
        rejectionStore.reject(
            item.songIdentity,
            videoID: item.youtubeResult.youtubeVideoID,
            for: playlistID
        )

        let videoID = item.youtubeResult.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = revalidate(PlaylistRecommendationResult(
            visibleRecommendations: currentResult.visibleRecommendations.filter {
                $0.youtubeResult.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines) != videoID
            },
            spareResolved: currentResult.spareResolved,
            deferredCandidates: currentResult.deferredCandidates
        ), for: currentTracks ?? [], playlistID: playlistID)

        if let currentTracks {
            cache.set(playlistID: playlistID, trackSignature: trackSignature(for: currentTracks), result: updated)
        } else {
            cache.updateResult(for: playlistID, result: updated)
        }
        return updated
    }

    func consumeVisibleRecommendation(
        _ item: ResolvedRecommendation,
        from currentResult: PlaylistRecommendationResult,
        playlistID: String?,
        currentTracks: [Track]? = nil
    ) -> PlaylistRecommendationResult {
        let videoID = item.youtubeResult.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = revalidate(PlaylistRecommendationResult(
            visibleRecommendations: currentResult.visibleRecommendations.filter {
                $0.youtubeResult.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines) != videoID
            },
            spareResolved: currentResult.spareResolved,
            deferredCandidates: currentResult.deferredCandidates
        ), for: currentTracks ?? [], playlistID: playlistID)

        if let playlistID {
            if let currentTracks {
                cache.set(playlistID: playlistID, trackSignature: trackSignature(for: currentTracks), result: updated)
            } else {
                cache.updateResult(for: playlistID, result: updated)
            }
        }
        return updated
    }

    func trackSignature(for tracks: [Track]) -> [String] {
        tracks.map { track in
            let id = track.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = RecommendationSeed(persistedTrack: track).songIdentity.cacheKey
            return "\(id)\u{1F}\(track.persistentModelID)\u{1F}\(identity)"
        }
    }

    private func validateRequest(
        signature: [String], currentTracks: [Track], isCurrent: () -> Bool
    ) throws {
        try Task.checkCancellation()
        guard isCurrent(), trackSignature(for: currentTracks) == signature else {
            throw CancellationError()
        }
    }

    private func allows(
        _ item: ResolvedRecommendation,
        profile: PlaylistVibeProfile,
        playlistID: String?
    ) -> Bool {
        let videoID = item.youtubeResult.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !videoID.isEmpty,
              !profile.existingVideoIDs.contains(videoID),
              !profile.existingIdentities.contains(item.songIdentity),
              !isAlternateVersion(item.title, identity: item.songIdentity, existing: profile.existingIdentities),
              feedbackStore.snapshot.allowsAutomaticRecommendation(item.songIdentity)
        else { return false }
        if let playlistID,
           rejectionStore.isRejected(item.songIdentity, videoID: videoID, for: playlistID) {
            return false
        }
        return true
    }

    private func allows(
        _ candidate: ScoredPlaylistCandidate,
        profile: PlaylistVibeProfile,
        playlistID: String?
    ) -> Bool {
        guard !profile.existingIdentities.contains(candidate.identity),
              !isAlternateVersion(candidate.identity.title, identity: candidate.identity, existing: profile.existingIdentities),
              feedbackStore.snapshot.allowsAutomaticRecommendation(candidate.identity)
        else { return false }
        if let playlistID, rejectionStore.isRejected(candidate.identity, for: playlistID) {
            return false
        }
        return true
    }

    /// Keep the existing order while applying current membership, feedback and dedupe rules.
    func revalidate(
        _ result: PlaylistRecommendationResult,
        for tracks: [Track],
        playlistID: String?
    ) -> PlaylistRecommendationResult {
        let profile = PlaylistVibeProfile.build(from: tracks)
        var seenVideoIDs = profile.existingVideoIDs
        var seenIdentities = profile.existingIdentities
        var visible: [ResolvedRecommendation] = []
        var spare: [ResolvedRecommendation] = []

        for item in result.visibleRecommendations + result.spareResolved {
            let videoID = item.youtubeResult.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard allows(item, profile: profile, playlistID: playlistID),
                  !seenVideoIDs.contains(videoID),
                  !seenIdentities.contains(item.songIdentity) else { continue }
            seenVideoIDs.insert(videoID)
            seenIdentities.insert(item.songIdentity)
            if visible.count < 5 { visible.append(item) }
            else { spare.append(item) }
        }

        var deferred: [ScoredPlaylistCandidate] = []
        for candidate in result.deferredCandidates {
            guard allows(candidate, profile: profile, playlistID: playlistID),
                  seenIdentities.insert(candidate.identity).inserted else { continue }
            deferred.append(candidate)
        }
        return PlaylistRecommendationResult(
            visibleRecommendations: visible, spareResolved: spare, deferredCandidates: deferred
        )
    }

    func fetchAndRankCandidates(
        profile: PlaylistVibeProfile,
        playlistID: String? = nil
    ) async throws -> [ScoredPlaylistCandidate] {
        let anchors = profile.representativeAnchors
        guard !anchors.isEmpty else { return [] }

        var candidateAnchors: [SongIdentity: Set<SongIdentity>] = [:]
        var candidateMaxMatch: [SongIdentity: Double] = [:]
        var candidateTracks: [SongIdentity: LastFMSimilarTrack] = [:]

        for anchor in anchors {
            try Task.checkCancellation()
            let anchorIdentity = anchor.songIdentity
            let similar: [LastFMSimilarTrack]
            do {
                similar = try await similarTracksOperation(
                    anchor.cleanedArtist,
                    anchor.cleanedTitle,
                    20,
                    false
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }

            for track in similar {
                let artist = SongNormalization.humanReadable(track.artist)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let title = SongNormalization.humanReadable(track.title)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !artist.isEmpty, !title.isEmpty else {
                    continue
                }

                let identity = SongIdentity(artist: artist, title: title)

                // Filter songs already in playlist
                guard !profile.existingIdentities.contains(identity) else {
                    continue
                }

                // Filter alternate versions of songs in playlist
                guard !isAlternateVersion(title, identity: identity, existing: profile.existingIdentities) else {
                    continue
                }

                // Filter playlist-specific rejections if playlistID provided
                if let playlistID, rejectionStore.isRejected(identity, for: playlistID) {
                    continue
                }

                // Hard filter on blocked artists
                guard feedbackStore.snapshot.allowsAutomaticRecommendation(identity) else {
                    continue
                }

                candidateAnchors[identity, default: []].insert(anchorIdentity)
                candidateMaxMatch[identity] = max(candidateMaxMatch[identity, default: 0], track.match)
                if candidateTracks[identity] == nil {
                    candidateTracks[identity] = track
                }
            }
        }

        guard !candidateTracks.isEmpty else { return [] }

        var scoredList: [ScoredPlaylistCandidate] = []
        let feedback = feedbackStore.snapshot
        let personalization = personalizationStore.profile

        for (identity, track) in candidateTracks {
            let baseMatch = candidateMaxMatch[identity] ?? track.match
            let supportCount = candidateAnchors[identity]?.count ?? 1
            // Bonus for candidates supported by multiple playlist anchors
            let multiAnchorBonus = Double(max(0, supportCount - 1)) * 0.25

            let adjustment = RecommendationAdjustment(
                identity: identity,
                feedback: feedback,
                personalization: personalization
            )
            let score = baseMatch + multiAnchorBonus + adjustment.combined

            scoredList.append(ScoredPlaylistCandidate(
                track: track,
                identity: identity,
                score: score,
                supportingAnchorCount: supportCount
            ))
        }

        return scoredList.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.identity.artist != rhs.identity.artist {
                return lhs.identity.artist < rhs.identity.artist
            }
            return lhs.identity.title < rhs.identity.title
        }
    }

    func applyArtistDiversity(
        to candidates: [ScoredPlaylistCandidate],
        maxPerArtist: Int = 2
    ) -> [ScoredPlaylistCandidate] {
        var artistCounts: [String: Int] = [:]
        var primary: [ScoredPlaylistCandidate] = []
        var deferred: [ScoredPlaylistCandidate] = []

        for candidate in candidates {
            let normArtist = SongNormalization.text(candidate.identity.artist)
            let count = artistCounts[normArtist, default: 0]
            if count < maxPerArtist {
                artistCounts[normArtist] = count + 1
                primary.append(candidate)
            } else {
                deferred.append(candidate)
            }
        }

        return primary + deferred
    }

    func resolveCandidatesSafely(
        _ candidates: [ScoredPlaylistCandidate],
        existingVideoIDs: Set<String>,
        existingIdentities: Set<SongIdentity>,
        playlistID: String? = nil,
        targetCount: Int = 5,
        spareLimit: Int = 2,
        maxAttempts: Int = 15
    ) async throws -> (resolved: [ResolvedRecommendation], deferred: [ScoredPlaylistCandidate]) {
        var resolved: [ResolvedRecommendation] = []
        var deferred: [ScoredPlaylistCandidate] = []
        var seenVideoIDs = Set(existingVideoIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var seenIdentities = existingIdentities
        var attempts = 0

        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            if resolved.count >= targetCount + spareLimit {
                deferred.append(contentsOf: candidates[index...])
                break
            }
            if attempts >= maxAttempts {
                deferred.append(contentsOf: candidates[index...])
                break
            }
            attempts += 1

            let outcome = try await safeResolverOperation(candidate.track)
            guard let recommendation = outcome else {
#if DEBUG
                print("[PlaylistRecommendations] candidate deferred because official search would be required target=\(candidate.identity.artist) - \(candidate.identity.title)")
#endif
                deferred.append(candidate)
                continue
            }

            let videoID = recommendation.youtubeResult.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !videoID.isEmpty,
                  seenVideoIDs.insert(videoID).inserted,
                  seenIdentities.insert(recommendation.songIdentity).inserted else {
                continue
            }

            if let playlistID, rejectionStore.isRejected(recommendation.songIdentity, videoID: videoID, for: playlistID) {
                continue
            }

#if DEBUG
            print("[PlaylistRecommendations] structured resolver success candidate=\(candidate.identity.artist) - \(candidate.identity.title)")
#endif
            resolved.append(recommendation)
        }

        return (resolved, deferred)
    }

    @discardableResult
    func addRecommendation(
        _ recommendation: ResolvedRecommendation,
        to playlist: Playlist,
        in modelContext: ModelContext,
        existingLibraryTracks: [Track]
    ) -> Track? {
        do {
            return try TrackPersistence.promoteOrReuse(
                recommendation: recommendation,
                in: modelContext,
                targetPlaylist: playlist,
                existingLibraryTracks: existingLibraryTracks
            )
        } catch {
            #if DEBUG
            print("[PlaylistRecommendations] addRecommendation failed: \(error)")
            #endif
            return nil
        }
    }

    private func isAlternateVersion(
        _ title: String,
        identity: SongIdentity,
        existing: Set<SongIdentity>
    ) -> Bool {
        if existing.contains(identity) {
            return true
        }
        let normalizedTitle = SongNormalization.text(title)
        guard SongNormalization.containsVersionMarker(normalizedTitle) else {
            return false
        }
        return existing.contains(identity)
    }
}
