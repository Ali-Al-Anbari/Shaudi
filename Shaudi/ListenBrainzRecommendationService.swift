import Foundation

struct ListenBrainzSimilarRecording: Decodable, Equatable {
    let recordingMBID: UUID?
    let title: String?
    let artist: String?
    let artistMBIDs: [UUID]?
    let score: Int?

    enum CodingKeys: String, CodingKey {
        case recordingMBID = "recording_mbid"
        case title = "recording_name"
        case artist = "artist_credit_name"
        case artistMBIDs = "artist_credit_mbids"
        case score
    }
}

struct ListenBrainzRecommendationService {
    enum SimilarError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case malformedResponse
        case transport(URLError.Code)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "invalid HTTP response"
            case .httpStatus(let status): "HTTP \(status)"
            case .malformedResponse: "malformed ListenBrainz response"
            case .transport(.timedOut): "ListenBrainz timeout"
            case .transport(let code): "ListenBrainz transport error \(code.rawValue)"
            }
        }
    }

    // This is a currently published Labs dataset identifier, not a permanent API version.
    // A missing dataset simply leaves the existing Last.fm candidates in place.
    static let algorithm = "session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30"
    private let session: URLSession
    private let rateLimiter: ListenBrainzRequestRateLimiter?
    private let retryDelayNanoseconds: UInt64

    init(
        session: URLSession = .shared,
        rateLimiter: ListenBrainzRequestRateLimiter? = .shared,
        retryDelayNanoseconds: UInt64 = 500_000_000
    ) {
        self.session = session
        self.rateLimiter = rateLimiter
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }

    func similarRecordings(to recordingMBID: UUID) async throws -> [ListenBrainzSimilarRecording] {
        try Task.checkCancellation()
        var components = URLComponents(string: "https://labs.api.listenbrainz.org/similar-recordings/json")!
        components.queryItems = [
            URLQueryItem(name: "recording_mbids", value: recordingMBID.uuidString.lowercased()),
            URLQueryItem(name: "algorithm", value: Self.algorithm)
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        request.setValue(RecommendationProviderUserAgent.value, forHTTPHeaderField: "User-Agent")
#if DEBUG
        print("[ListenBrainz] similar request mbid=\(recordingMBID)")
#endif
        for attempt in 1...2 {
            do {
                let decoded = try await fetch(request)
#if DEBUG
                print("[ListenBrainz] raw candidates=\(decoded.count)")
#endif
                return decoded
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
        return []
    }

    private func fetch(_ request: URLRequest) async throws -> [ListenBrainzSimilarRecording] {
        do {
            try await rateLimiter?.waitForPermit()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw SimilarError.invalidResponse }
            guard http.statusCode == 200 else { throw SimilarError.httpStatus(http.statusCode) }
            do {
                return try JSONDecoder().decode([ListenBrainzSimilarRecording].self, from: data)
            } catch {
#if DEBUG
                print("[ListenBrainz] decode failed reason=\(error)")
#endif
                throw SimilarError.malformedResponse
            }
        } catch let error as URLError {
            try Task.checkCancellation()
            if error.code == .cancelled { throw CancellationError() }
            throw SimilarError.transport(error.code)
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? SimilarError else { return false }
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
        case SimilarError.httpStatus(let status): detail = "status=\(status)"
        case SimilarError.transport(.timedOut): detail = "timeout"
        case SimilarError.transport(let code): detail = "transport=\(code.rawValue)"
        default: detail = "reason=\(error.localizedDescription)"
        }
        print("[ListenBrainz] similar request failed \(detail) attempt=\(attempt) retrying=\(retrying)")
    }
#endif

    static func candidates(
        from recordings: [ListenBrainzSimilarRecording],
        limit: Int,
        baseMatch: Double
    ) -> [LastFMSimilarTrack] {
        var seenMBIDs = Set<UUID>()
        var seenSongs = Set<SongIdentity>()
        var result: [LastFMSimilarTrack] = []
        for recording in recordings {
            guard result.count < limit else { break }
            let artist = SongNormalization.humanReadable(recording.artist ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = SongNormalization.humanReadable(recording.title ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !title.isEmpty else { continue }
            if let mbid = recording.recordingMBID, !seenMBIDs.insert(mbid).inserted { continue }
            guard seenSongs.insert(SongIdentity(artist: artist, title: title)).inserted else { continue }
            // The Labs score has a different scale from Last.fm match. Preserve its rank
            // only as a tiny tie breaker; Shaudi's feedback and personalization still rank.
            let rankAdjustment = Double(result.count) * 0.0001
            result.append(LastFMSimilarTrack(
                artist: artist,
                title: title,
                match: max(0, baseMatch - rankAdjustment),
                url: nil
            ))
        }
#if DEBUG
        print("[ListenBrainz] mapped candidates=\(result.count)")
#endif
        return result
    }
}

actor ListenBrainzRequestRateLimiter {
    static let shared = ListenBrainzRequestRateLimiter()
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

@MainActor
struct RadioListenBrainzFallback {
    typealias RecordingLookup = (String, String) async throws -> MusicBrainzRecordingIdentity?
    typealias SimilarLookup = (UUID) async throws -> [ListenBrainzSimilarRecording]

    private let recordingLookup: RecordingLookup
    private let similarLookup: SimilarLookup

    init() {
        let musicBrainz = MusicBrainzRecommendationService()
        let listenBrainz = ListenBrainzRecommendationService()
        recordingLookup = { artist, title in
            try await musicBrainz.recording(artist: artist, title: title)
        }
        similarLookup = { mbid in
            try await listenBrainz.similarRecordings(to: mbid)
        }
    }

    init(recordingLookup: @escaping RecordingLookup, similarLookup: @escaping SimilarLookup) {
        self.recordingLookup = recordingLookup
        self.similarLookup = similarLookup
    }

    func candidates(
        for seed: RecommendationSeed,
        baseMatch: Double,
        limit: Int
    ) async throws -> [LastFMSimilarTrack] {
        guard seed.identityConfidence >= .high else {
#if DEBUG
            print("[MusicBrainz] rejected seed reason=identity confidence below high")
#endif
            return []
        }
        guard let identity = try await recordingLookup(seed.cleanedArtist, seed.cleanedTitle) else {
            return []
        }
        try Task.checkCancellation()
        let recordings = try await similarLookup(identity.recordingMBID)
        try Task.checkCancellation()
        return ListenBrainzRecommendationService.candidates(
            from: recordings, limit: limit, baseMatch: baseMatch
        )
    }
}
