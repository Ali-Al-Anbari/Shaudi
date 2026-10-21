import Foundation

struct MusicBrainzRecordingIdentity: Codable, Equatable {
    let recordingMBID: UUID
    let artistMBID: UUID
    let searchScore: Int
    let confidence: String
    let source: String
    let resolvedAt: Date
}

actor MusicBrainzRecordingCache {
    static let shared = MusicBrainzRecordingCache()

    private let fileURL: URL
    private var entries: [String: MusicBrainzRecordingIdentity]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            self.fileURL = base.appendingPathComponent("Shaudi", isDirectory: true)
                .appendingPathComponent("musicbrainz-recording-cache.json")
        }
    }

    func identity(for key: String) -> MusicBrainzRecordingIdentity? {
        loadIfNeeded()
        guard let identity = entries?[key], identity.confidence == "high" else { return nil }
        return identity
    }

    func store(_ identity: MusicBrainzRecordingIdentity, for key: String) throws {
        guard identity.confidence == "high" else { return }
        loadIfNeeded()
        var updated = entries ?? [:]
        updated[key] = identity
        if updated.count > 500,
           let oldest = updated.min(by: { $0.value.resolvedAt < $1.value.resolvedAt })?.key {
            updated.removeValue(forKey: oldest)
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            entries = updated
        } catch {
#if DEBUG
            print("[MusicBrainz] cache write failed reason=\(error.localizedDescription)")
#endif
            throw error
        }
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        entries = (try? Data(contentsOf: fileURL)).flatMap {
            try? JSONDecoder().decode([String: MusicBrainzRecordingIdentity].self, from: $0)
        } ?? [:]
    }
}

@MainActor
struct MusicBrainzRecommendationService {
    private struct SearchResponse: Decodable {
        let recordings: [Recording]
    }

    private struct Recording: Decodable {
        let id: UUID
        let score: Int
        let title: String
        let video: Bool?
        let artistCredit: [ArtistCredit]

        enum CodingKeys: String, CodingKey {
            case id, score, title, video
            case artistCredit = "artist-credit"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            title = try values.decode(String.self, forKey: .title)
            video = try values.decodeIfPresent(Bool.self, forKey: .video)
            artistCredit = try values.decode([ArtistCredit].self, forKey: .artistCredit)
            if let numeric = try? values.decode(Int.self, forKey: .score) {
                score = numeric
            } else {
                let text = try values.decode(String.self, forKey: .score)
                guard let numeric = Int(text) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .score, in: values, debugDescription: "Invalid MusicBrainz score"
                    )
                }
                score = numeric
            }
        }
    }

    private struct ArtistCredit: Decodable {
        let name: String?
        let artist: Artist?

        init(from decoder: Decoder) throws {
            // MusicBrainz inserts join phrases such as " feat. " as strings here.
            if let single = try? decoder.singleValueContainer(),
               (try? single.decode(String.self)) != nil {
                name = nil
                artist = nil
                return
            }
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            name = try keyed.decodeIfPresent(String.self, forKey: .name)
            artist = try keyed.decodeIfPresent(Artist.self, forKey: .artist)
        }

        private enum CodingKeys: String, CodingKey { case name, artist }
    }

    private struct Artist: Decodable {
        let id: UUID
        let name: String
        let aliases: [Alias]?
    }

    private struct Alias: Decodable {
        let name: String
        let type: String?
    }

    enum LookupError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case malformedResponse
        case transport(URLError.Code)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "invalid HTTP response"
            case .httpStatus(let status): "HTTP \(status)"
            case .malformedResponse: "malformed MusicBrainz response"
            case .transport(.timedOut): "MusicBrainz timeout"
            case .transport(let code): "MusicBrainz transport error \(code.rawValue)"
            }
        }
    }

    private let session: URLSession
    private let cache: MusicBrainzRecordingCache
    private let rateLimiter: MusicBrainzRequestRateLimiter?
    private let retryDelayNanoseconds: UInt64

    init(
        session: URLSession = .shared,
        cache: MusicBrainzRecordingCache = .shared,
        rateLimiter: MusicBrainzRequestRateLimiter? = .shared,
        retryDelayNanoseconds: UInt64 = 500_000_000
    ) {
        self.session = session
        self.cache = cache
        self.rateLimiter = rateLimiter
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }

    func recording(artist: String, title: String) async throws -> MusicBrainzRecordingIdentity? {
        try Task.checkCancellation()
        // SongIdentity.cacheKey removes version markers, so it cannot identify a recording version.
        let cacheKey = SongNormalization.text(SongNormalization.artist(artist)) + "\u{1F}"
            + SongNormalization.text(SongNormalization.displayTitle(title))
        if let cached = await cache.identity(for: cacheKey) {
#if DEBUG
            print("[MusicBrainz] cache hit mbid=\(cached.recordingMBID)")
#endif
            return cached
        }

        let cleanedArtist = SongNormalization.artist(artist)
        let cleanedTitle = SongNormalization.displayTitle(title)
        guard !cleanedArtist.isEmpty, !cleanedTitle.isEmpty else { return nil }
#if DEBUG
        print("[MusicBrainz] lookup artist=\(cleanedArtist) title=\(cleanedTitle)")
#endif
        // Quoting the escaped Lucene terms keeps punctuation from becoming query syntax.
        let query = "recording:\"\(Self.luceneQuoted(cleanedTitle))\" AND artist:\"\(Self.luceneQuoted(cleanedArtist))\""
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "10")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        request.setValue(RecommendationProviderUserAgent.value, forHTTPHeaderField: "User-Agent")
        for attempt in 1...2 {
            do {
                let result = try await fetch(request)
                guard let match = Self.highConfidenceMatch(
                    result.recordings,
                    artist: cleanedArtist,
                    title: cleanedTitle
                ) else {
#if DEBUG
                    print("[MusicBrainz] rejected match reason=no unique high-confidence recording")
#endif
                    return nil
                }
                try Task.checkCancellation()
                try await cache.store(match, for: cacheKey)
                try Task.checkCancellation()
#if DEBUG
                print("[MusicBrainz] match mbid=\(match.recordingMBID) score=\(match.searchScore) confidence=high")
#endif
                return match
            } catch {
                try Task.checkCancellation()
                let retry = attempt == 1 && Self.isTransient(error)
#if DEBUG
                Self.logFailure(error, attempt: attempt, retrying: retry)
#endif
                guard retry else { throw error }
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
        return nil
    }

    private func fetch(_ request: URLRequest) async throws -> SearchResponse {
        do {
            try await rateLimiter?.waitForPermit()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw LookupError.invalidResponse }
            guard http.statusCode == 200 else { throw LookupError.httpStatus(http.statusCode) }
            do {
                return try JSONDecoder().decode(SearchResponse.self, from: data)
            } catch {
#if DEBUG
                print("[MusicBrainz] decode failed reason=\(error)")
#endif
                throw LookupError.malformedResponse
            }
        } catch let error as URLError {
            try Task.checkCancellation()
            if error.code == .cancelled { throw CancellationError() }
            throw LookupError.transport(error.code)
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? LookupError else { return false }
        switch error {
        case .httpStatus(let status): return (500...599).contains(status)
        case .transport(let code):
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed].contains(code)
        case .invalidResponse, .malformedResponse: return false
        }
    }

#if DEBUG
    private static func logFailure(_ error: Error, attempt: Int, retrying: Bool) {
        let detail: String
        switch error {
        case LookupError.httpStatus(let status): detail = "status=\(status)"
        case LookupError.transport(.timedOut): detail = "timeout"
        case LookupError.transport(let code): detail = "transport=\(code.rawValue)"
        default: detail = "reason=\(error.localizedDescription)"
        }
        print("[MusicBrainz] lookup failed \(detail) attempt=\(attempt) retrying=\(retrying)")
    }
#endif

    private static func highConfidenceMatch(
        _ recordings: [Recording], artist: String, title: String
    ) -> MusicBrainzRecordingIdentity? {
        let artistKey = SongNormalization.text(artist)
        let titleKey = SongNormalization.text(title)
        let matches: [(Recording, Artist)] = recordings.compactMap { recording in
            guard
                recording.score >= 95,
                recording.video != true,
                SongNormalization.text(SongNormalization.displayTitle(recording.title)) == titleKey
            else { return nil }
            // A featured guest alone is not strong evidence for the seed's artist.
            guard let matchedArtist = recording.artistCredit.compactMap(\.artist).first else {
                return nil
            }
            let creditedNameMatches = SongNormalization.text(matchedArtist.name) == artistKey
                || recording.artistCredit.contains(where: {
                    SongNormalization.text($0.name ?? "") == artistKey
                        && $0.artist?.id == matchedArtist.id
                })
                || (matchedArtist.aliases ?? []).contains(where: {
                    ($0.type == nil || $0.type == "Artist name")
                        && SongNormalization.text($0.name) == artistKey
                })
            guard creditedNameMatches else { return nil }
            return (recording, matchedArtist)
        }
        // Separate MBIDs with equally strong exact metadata are ambiguous.
        guard matches.count == 1, let (recording, artist) = matches.first else { return nil }
        return MusicBrainzRecordingIdentity(
            recordingMBID: recording.id,
            artistMBID: artist.id,
            searchScore: recording.score,
            confidence: "high",
            source: "musicbrainz-search",
            resolvedAt: .now
        )
    }

    private static func luceneQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

actor MusicBrainzRequestRateLimiter {
    static let shared = MusicBrainzRequestRateLimiter()
    private var nextAllowed = Date.distantPast

    func waitForPermit() async throws {
        let now = Date()
        let reserved = max(now, nextAllowed)
        nextAllowed = reserved.addingTimeInterval(1)
        let delay = reserved.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try Task.checkCancellation()
    }
}

enum RecommendationProviderUserAgent {
    static let value: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Shaudi/\(version) (https://github.com/Ali-Al-Anbari/Shaudi/issues)"
    }()
}
