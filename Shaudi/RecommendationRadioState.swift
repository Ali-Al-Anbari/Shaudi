//
//  RecommendationRadioState.swift
//  Shaudi
//

import Foundation

enum RecommendationRadioPolicy {
    nonisolated static let epochLength = 24
    nonisolated static let candidatePoolSize = 50
    nonisolated static let targetUpcomingCount = 3
    nonisolated static let upcomingQueueLimit = 6
    nonisolated static let historyQueueLimit = 6
    nonisolated static let sessionIdentityLimit = 512
}

struct RecommendationRadioEpoch {
    let id: UUID
    let anchor: RecommendationSeed
    var candidateReservoir: RecommendationCandidateReservoir
    private(set) var consumedRecommendationCount: Int
    private(set) var hasRequestedCandidates: Bool

    init(
        id: UUID = UUID(),
        anchor: RecommendationSeed,
        candidateReservoir: RecommendationCandidateReservoir = .init(),
        consumedRecommendationCount: Int = 0,
        hasRequestedCandidates: Bool = false
    ) {
        self.id = id
        self.anchor = anchor
        self.candidateReservoir = candidateReservoir
        self.consumedRecommendationCount = consumedRecommendationCount
        self.hasRequestedCandidates = hasRequestedCandidates
    }

    mutating func consumeRecommendation() {
        consumedRecommendationCount += 1
    }

    mutating func markCandidateRequestStarted() -> Bool {
        guard !hasRequestedCandidates else {
            return false
        }
        hasRequestedCandidates = true
        return true
    }
}

struct RecommendationRadioSession {
    enum PlaybackAction {
        case replenish(epochID: UUID)
        case startNewEpoch(epochID: UUID, anchor: RecommendationSeed)
        case ignore
    }

    let id: UUID
    private(set) var epoch: RecommendationRadioEpoch
    private(set) var globalPlayedSongIdentities: Set<SongIdentity>
    private var playedIdentityOrder: [SongIdentity]
    private var consumedVideoIDs: Set<String>
    private var consumedVideoIDOrder: [String]

    init(id: UUID = UUID(), anchor: RecommendationSeed) {
        self.id = id
        epoch = RecommendationRadioEpoch(anchor: anchor)
        globalPlayedSongIdentities = [anchor.songIdentity]
        playedIdentityOrder = [anchor.songIdentity]
        let videoID = Self.normalizedVideoID(anchor.youtubeVideoID)
        consumedVideoIDs = videoID.isEmpty ? [] : [videoID]
        consumedVideoIDOrder = videoID.isEmpty ? [] : [videoID]
    }

    mutating func confirmedRecommendationPlayback(
        seed: RecommendationSeed
    ) -> PlaybackAction {
        let videoID = Self.normalizedVideoID(seed.youtubeVideoID)
        guard !videoID.isEmpty, consumedVideoIDs.insert(videoID).inserted else {
            return .ignore
        }
        consumedVideoIDOrder.append(videoID)
        trimConsumedVideoIDsIfNeeded()
        recordPlayed(seed.songIdentity)

        epoch.consumeRecommendation()
        guard epoch.consumedRecommendationCount >= RecommendationRadioPolicy.epochLength else {
            return .replenish(epochID: epoch.id)
        }

        epoch = RecommendationRadioEpoch(anchor: seed)
        return .startNewEpoch(epochID: epoch.id, anchor: seed)
    }

    mutating func recordSeen(_ identity: SongIdentity) {
        recordPlayed(identity)
    }

    mutating func replaceReservoir(
        _ candidates: [LastFMSimilarTrack],
        epochID: UUID
    ) -> Bool {
        guard epoch.id == epochID else {
            return false
        }
        epoch.candidateReservoir.reset()
        epoch.candidateReservoir.store(
            candidates,
            excluding: globalPlayedSongIdentities,
            limit: RecommendationRadioPolicy.candidatePoolSize
        )
        return true
    }

    mutating func markEpochCandidateRequestStarted(epochID: UUID) -> Bool {
        guard epoch.id == epochID else {
            return false
        }
        return epoch.markCandidateRequestStarted()
    }

    mutating func takeReservoirCandidates(
        upTo limit: Int,
        epochID: UUID
    ) -> [LastFMSimilarTrack] {
        guard epoch.id == epochID else {
            return []
        }
        return epoch.candidateReservoir.take(upTo: limit)
    }

    mutating func returnUnusedReservoirCandidates(
        _ candidates: [LastFMSimilarTrack],
        epochID: UUID
    ) -> Bool {
        guard epoch.id == epochID else {
            return false
        }
        epoch.candidateReservoir.store(
            candidates,
            excluding: globalPlayedSongIdentities,
            limit: RecommendationRadioPolicy.candidatePoolSize
        )
        return true
    }

    var reservoirCount: Int {
        epoch.candidateReservoir.count
    }

    private mutating func recordPlayed(_ identity: SongIdentity) {
        guard globalPlayedSongIdentities.insert(identity).inserted else {
            return
        }
        playedIdentityOrder.append(identity)
        while playedIdentityOrder.count > RecommendationRadioPolicy.sessionIdentityLimit {
            globalPlayedSongIdentities.remove(playedIdentityOrder.removeFirst())
        }
    }

    private mutating func trimConsumedVideoIDsIfNeeded() {
        while consumedVideoIDOrder.count > RecommendationRadioPolicy.sessionIdentityLimit {
            consumedVideoIDs.remove(consumedVideoIDOrder.removeFirst())
        }
    }

    private static func normalizedVideoID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
