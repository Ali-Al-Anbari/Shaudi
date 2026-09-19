import Combine
import Foundation

enum RecommendationFeedbackAction {
    case moreLikeThis
    case lessLikeThis
    case dontRecommendArtist
}

struct RecommendationFeedbackSnapshot: Codable, Equatable {
    struct SongPreference: Codable, Equatable {
        let identityKey: String
        let artistKey: String
        let artist: String
        let title: String

        init(identity: SongIdentity) {
            identityKey = identity.cacheKey
            artistKey = Self.normalizedArtist(identity.artist)
            artist = identity.artist
            title = identity.title
        }

        private static func normalizedArtist(_ artist: String) -> String {
            SongNormalization.text(SongNormalization.humanReadable(artist))
        }
    }

    struct ArtistPreference: Codable, Equatable {
        let artistKey: String
        let artist: String

        init(artist: String) {
            self.artist = SongNormalization.humanReadable(artist)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            artistKey = Self.normalizedArtist(artist)
        }

        private static func normalizedArtist(_ artist: String) -> String {
            SongNormalization.text(SongNormalization.humanReadable(artist))
        }
    }

    private(set) var moreLikeSongs: [String: SongPreference] = [:]
    private(set) var lessLikeSongs: [String: SongPreference] = [:]
    private(set) var excludedArtists: [String: ArtistPreference] = [:]

    var excludedArtistNames: [String] {
        excludedArtists.values.map(\.artist).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var isEmpty: Bool {
        moreLikeSongs.isEmpty && lessLikeSongs.isEmpty && excludedArtists.isEmpty
    }

    func isArtistExcluded(_ artist: String) -> Bool {
        excludedArtists[artistKey(artist)] != nil
    }

    func allowsAutomaticRecommendation(_ identity: SongIdentity) -> Bool {
        !isArtistExcluded(identity.artist)
    }

    func scoreAdjustment(for identity: SongIdentity) -> Double {
        let key = identity.cacheKey
        let candidateArtistKey = artistKey(identity.artist)
        var adjustment = 0.0

        if moreLikeSongs[key] != nil {
            adjustment += 0.06
        }
        if moreLikeSongs.values.contains(where: { $0.artistKey == candidateArtistKey }) {
            adjustment += 0.025
        }
        if lessLikeSongs[key] != nil {
            adjustment -= 0.35
        }
        if lessLikeSongs.values.contains(where: { $0.artistKey == candidateArtistKey }) {
            adjustment -= 0.08
        }
        return adjustment
    }

    mutating func record(_ action: RecommendationFeedbackAction, identity: SongIdentity) {
        let preference = SongPreference(identity: identity)
        switch action {
        case .moreLikeThis:
            lessLikeSongs.removeValue(forKey: preference.identityKey)
            moreLikeSongs[preference.identityKey] = preference
        case .lessLikeThis:
            moreLikeSongs.removeValue(forKey: preference.identityKey)
            lessLikeSongs[preference.identityKey] = preference
        case .dontRecommendArtist:
            let preference = ArtistPreference(artist: identity.artist)
            guard !preference.artistKey.isEmpty else { return }
            excludedArtists[preference.artistKey] = preference
        }
    }

    mutating func removeExcludedArtist(_ artist: String) {
        excludedArtists.removeValue(forKey: artistKey(artist))
    }

    mutating func clearExcludedArtists() {
        excludedArtists = [:]
    }

    mutating func clearAll() {
        moreLikeSongs = [:]
        lessLikeSongs = [:]
        excludedArtists = [:]
    }

    func normalized() -> RecommendationFeedbackSnapshot {
        var result = RecommendationFeedbackSnapshot()
        for preference in moreLikeSongs.values {
            result.record(
                .moreLikeThis,
                identity: SongIdentity(artist: preference.artist, title: preference.title)
            )
        }
        for preference in lessLikeSongs.values {
            result.record(
                .lessLikeThis,
                identity: SongIdentity(artist: preference.artist, title: preference.title)
            )
        }
        for preference in excludedArtists.values {
            result.record(
                .dontRecommendArtist,
                identity: SongIdentity(artist: preference.artist, title: "")
            )
        }
        return result
    }

    private func artistKey(_ artist: String) -> String {
        SongNormalization.text(SongNormalization.humanReadable(artist))
    }
}

@MainActor
final class RecommendationFeedbackStore: ObservableObject {
    static let shared = RecommendationFeedbackStore()

    @Published private(set) var snapshot: RecommendationFeedbackSnapshot

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "shaudi.recommendations.feedback.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if
            let data = defaults.data(forKey: storageKey),
            let stored = try? JSONDecoder().decode(
                RecommendationFeedbackSnapshot.self,
                from: data
            )
        {
            snapshot = stored.normalized()
        } else {
            snapshot = RecommendationFeedbackSnapshot()
        }
    }

    func record(_ action: RecommendationFeedbackAction, identity: SongIdentity) {
        snapshot.record(action, identity: identity)
        persist()
    }

    func removeExcludedArtist(_ artist: String) {
        snapshot.removeExcludedArtist(artist)
        persist()
    }

    func clearExcludedArtists() {
        snapshot.clearExcludedArtists()
        persist()
    }

    func clearAll() {
        snapshot.clearAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}
