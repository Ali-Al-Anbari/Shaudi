import Foundation

enum RecommendationEngagementBucket: String, Equatable {
    case neutral
    case earlySkip
    case meaningful
    case strong
    case nearCompletion
}

struct RecommendationListeningEvent {
    let identity: SongIdentity
    let listenedDuration: TimeInterval
    let authoritativeDuration: TimeInterval?
    let startedAt: Date
    let completionOutcome: ListeningHistoryCompletionOutcome?
    let confirmedPlay: Bool
}

struct RecommendationPersonalizationAdjustment: Equatable {
    let artist: Double
    let song: Double
    let total: Double
    let reasons: [String]

    static let neutral = RecommendationPersonalizationAdjustment(
        artist: 0,
        song: 0,
        total: 0,
        reasons: ["neutral discovery candidate"]
    )
}

struct RecommendationPersonalizationProfile: Equatable {
    private struct Signal: Equatable {
        var value = 0.0
        var meaningfulPlayCount = 0
        var earlySkipCount = 0
        var hasRecentEngagement = false
    }

    static let empty = RecommendationPersonalizationProfile()

    private var artists: [String: Signal] = [:]
    private var songs: [String: Signal] = [:]

    var isEmpty: Bool {
        artists.isEmpty && songs.isEmpty
    }

    init() {}

    init(events: [RecommendationListeningEvent], now: Date = .now) {
        var meaningfulCountsBySong: [String: Int] = [:]

        for event in events where event.confirmedPlay {
            let artistKey = Self.artistKey(event.identity.artist)
            let songKey = event.identity.cacheKey
            guard !artistKey.isEmpty, !songKey.isEmpty else {
                continue
            }
            guard event.listenedDuration.isFinite, event.listenedDuration >= 0 else {
                continue
            }

            let bucket = Self.engagementBucket(for: event)
            let recency = Self.recencyWeight(startedAt: event.startedAt, now: now)
            let signalValue: Double
            switch bucket {
            case .neutral:
                signalValue = 0
            case .earlySkip:
                signalValue = -0.8 * recency
            case .meaningful:
                signalValue = 0.35 * recency
            case .strong:
                signalValue = 0.7 * recency
            case .nearCompletion:
                signalValue = 1.0 * recency
            }

            guard signalValue != 0 else {
                continue
            }
            let isPositive = signalValue > 0
            let isRecent = isPositive && now.timeIntervalSince(event.startedAt) <= 7 * 86_400

            var artist = artists[artistKey, default: Signal()]
            artist.value += signalValue
            artist.meaningfulPlayCount += isPositive ? 1 : 0
            artist.earlySkipCount += bucket == .earlySkip ? 1 : 0
            artist.hasRecentEngagement = artist.hasRecentEngagement || isRecent
            artists[artistKey] = artist

            var song = songs[songKey, default: Signal()]
            song.value += signalValue
            song.meaningfulPlayCount += isPositive ? 1 : 0
            song.earlySkipCount += bucket == .earlySkip ? 1 : 0
            song.hasRecentEngagement = song.hasRecentEngagement || isRecent
            songs[songKey] = song

            if isPositive {
                meaningfulCountsBySong[songKey, default: 0] += 1
            }
        }

        // Replays add a small, bounded signal beyond the engagement value of
        // each individual play. Most of that benefit belongs to the artist's
        // neighborhood, not to repeatedly serving the exact same recording.
        for (songKey, count) in meaningfulCountsBySong where count > 1 {
            let repeatCount = min(count - 1, 4)
            let songBonus = Double(repeatCount) * 0.15
            songs[songKey]?.value += songBonus

            if let separator = songKey.firstIndex(of: "\u{1F}") {
                let artistKey = String(songKey[..<separator])
                artists[artistKey]?.value += Double(repeatCount) * 0.1
            }
        }
    }

    func adjustment(for identity: SongIdentity) -> RecommendationPersonalizationAdjustment {
        let artistSignal = artists[Self.artistKey(identity.artist)]
        let songSignal = songs[identity.cacheKey]
        guard artistSignal != nil || songSignal != nil else {
            return .neutral
        }

        let artistAdjustment = Self.clamp(
            (artistSignal?.value ?? 0) * 0.012,
            minimum: -0.075,
            maximum: 0.075
        )
        let songValue = songSignal?.value ?? 0
        let songScale = songValue < 0 ? 0.02 : 0.008
        var songAdjustment = Self.clamp(
            songValue * songScale,
            minimum: -0.06,
            maximum: 0.025
        )
        if let playCount = songSignal?.meaningfulPlayCount, playCount >= 3, songValue > 0 {
            let familiarityPenalty = min(Double(playCount - 2) * 0.01, 0.04)
            songAdjustment = max(-0.025, songAdjustment - familiarityPenalty)
        }
        let total = Self.clamp(
            artistAdjustment + songAdjustment,
            minimum: -0.12,
            maximum: 0.10
        )

        var reasons: [String] = []
        if let artistSignal {
            if artistSignal.earlySkipCount >= 2, artistSignal.value < 0 {
                reasons.append("repeated early-skip penalty")
            } else if artistSignal.meaningfulPlayCount >= 2, artistSignal.value > 0 {
                reasons.append("strong artist affinity")
            }
            if artistSignal.hasRecentEngagement, artistSignal.value > 0 {
                reasons.append("recent engagement")
            }
        }
        if let songSignal {
            if songSignal.earlySkipCount >= 2, songSignal.value < 0 {
                reasons.append("song early-skip penalty")
            } else if songSignal.meaningfulPlayCount >= 2, songSignal.value > 0 {
                reasons.append("recent repeated listening")
            }
            if songSignal.meaningfulPlayCount >= 3, songSignal.value > 0 {
                reasons.append("familiar song diversity")
            }
        }
        if reasons.isEmpty {
            reasons.append(total == 0 ? "neutral discovery candidate" : "listening behavior")
        }

        return RecommendationPersonalizationAdjustment(
            artist: artistAdjustment,
            song: songAdjustment,
            total: total,
            reasons: reasons
        )
    }

    static func engagementBucket(
        listenedDuration: TimeInterval,
        authoritativeDuration: TimeInterval?,
        completionOutcome: ListeningHistoryCompletionOutcome?
    ) -> RecommendationEngagementBucket {
        engagementBucket(for: RecommendationListeningEvent(
            identity: SongIdentity(artist: "Artist", title: "Song"),
            listenedDuration: listenedDuration,
            authoritativeDuration: authoritativeDuration,
            startedAt: .now,
            completionOutcome: completionOutcome,
            confirmedPlay: true
        ))
    }

    private static func engagementBucket(
        for event: RecommendationListeningEvent
    ) -> RecommendationEngagementBucket {
        let duration = event.authoritativeDuration.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        let ratio = duration.map { min(max(event.listenedDuration / $0, 0), 1) }

        if
            event.completionOutcome == .manualNext,
            let duration,
            duration >= 60,
            event.listenedDuration < 15,
            event.listenedDuration / duration < 0.10
        {
            return .earlySkip
        }
        if (ratio ?? 0) >= 0.85 {
            return .nearCompletion
        }
        if (ratio ?? 0) >= 0.60 || event.listenedDuration >= 120 {
            return .strong
        }
        if (ratio ?? 0) >= 0.25 || event.listenedDuration >= 30 {
            return .meaningful
        }
        return .neutral
    }

    private static func recencyWeight(startedAt: Date, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(startedAt))
        if age <= 7 * 86_400 {
            return 1.2
        }
        if age <= 30 * 86_400 {
            return 1.1
        }
        return 1.0
    }

    private static func artistKey(_ artist: String) -> String {
        SongNormalization.text(SongNormalization.humanReadable(artist))
    }

    private static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }
}

@MainActor
final class RecommendationPersonalizationStore {
    static let shared = RecommendationPersonalizationStore()

    private(set) var profile: RecommendationPersonalizationProfile = .empty

    func update(_ profile: RecommendationPersonalizationProfile) {
        self.profile = profile
    }
}
