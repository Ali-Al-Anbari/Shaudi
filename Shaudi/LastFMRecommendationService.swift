//
//  LastFMRecommendationService.swift
//  Shaudi
//

import Foundation

struct LastFMSimilarTrack: Hashable {
    let artist: String
    let title: String
    let match: Double
    let url: URL?
}

struct LastFMTopTrack: Hashable {
    let artist: String
    let title: String
}

struct LastFMRecommendationService: GenreTagFetching {
    enum ServiceError: LocalizedError {
        case missingAPIKey
        case invalidRequest
        case invalidResponse
        case network(String)
        case api(code: Int?, message: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Last.fm recommendations are unavailable because LASTFM_API_KEY is not configured."
            case .invalidRequest:
                return "The Last.fm recommendation request could not be created."
            case .invalidResponse:
                return "Last.fm returned an invalid response."
            case .network(let message):
                return "Could not reach Last.fm: \(message)"
            case .api(_, let message):
                return "Last.fm could not provide recommendations: \(message)"
            case .malformedResponse:
                return "Last.fm returned recommendations in an unexpected format."
            }
        }

        var permitsAlternateSeedRetry: Bool {
            guard case .api(let code, let message) = self else {
                return false
            }
            return code == 7 || message.localizedCaseInsensitiveContains("not found")
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func similarTracks(
        artist: String,
        title: String,
        limit: Int = RecommendationRadioPolicy.candidatePoolSize,
        isFallback: Bool = false
    ) async throws -> [LastFMSimilarTrack] {
#if DEBUG
        print(
            "[LastFM] request artist=\(artist) track=\(title) "
                + "fallback=\(isFallback) autocorrect=true"
        )
#endif
        let data = try await request(method: "track.getSimilar", queryItems: [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "track", value: title),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "limit", value: String(limit))
        ])

        let response: SimilarTracksResponse
        do {
            response = try JSONDecoder().decode(SimilarTracksResponse.self, from: data)
        } catch {
#if DEBUG
            print("[LastFM] request failed=track.getSimilar response decoding: \(error.localizedDescription)")
#endif
            throw ServiceError.malformedResponse
        }

#if DEBUG
        if let attributes = response.similartracks.attributes {
            print(
                "[LastFM] response artist=\(attributes.artist) "
                    + "track=\(attributes.track)"
            )
        }
#endif

        let tracks = response.similartracks.track.compactMap { item -> LastFMSimilarTrack? in
            let artist = item.artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !title.isEmpty else {
                return nil
            }

            return LastFMSimilarTrack(
                artist: artist,
                title: title,
                match: item.match,
                url: item.url.flatMap(URL.init(string:))
            )
        }

#if DEBUG
        print("[LastFM] candidates received=\(tracks.count)")
#endif
        return tracks
    }

    func topTracks(
        artist: String,
        limit: Int
    ) async throws -> [LastFMTopTrack] {
        let data = try await request(method: "artist.getTopTracks", queryItems: [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "limit", value: String(limit))
        ])

        let response: TopTracksResponse
        do {
            response = try JSONDecoder().decode(TopTracksResponse.self, from: data)
        } catch {
#if DEBUG
            print("[LastFM] request failed=artist.getTopTracks response decoding")
#endif
            throw ServiceError.malformedResponse
        }

        let tracks = response.toptracks.track.compactMap { item -> LastFMTopTrack? in
            let artist = item.artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !title.isEmpty else {
                return nil
            }
            return LastFMTopTrack(artist: artist, title: title)
        }
#if DEBUG
        print("[LastFM] topTracks received=\(tracks.count)")
#endif
        return tracks
    }

    func topTags(artist: String, title: String) async throws -> [GenreTag] {
#if DEBUG
        print("[GenreStats] lookup artist=\(artist) track=\(title)")
#endif
        let data = try await request(method: "track.getTopTags", queryItems: [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "track", value: title),
            URLQueryItem(name: "autocorrect", value: "1")
        ])

        let response: TopTagsResponse
        do {
            response = try JSONDecoder().decode(TopTagsResponse.self, from: data)
        } catch {
#if DEBUG
            print("[GenreStats] lookup failed=track.getTopTags response decoding")
#endif
            throw ServiceError.malformedResponse
        }

        return response.toptags.tag.compactMap { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return nil
            }
            return GenreTag(name: name, weight: item.count)
        }
    }

    private func request(
        method: String,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        let apiKey = try apiKey()
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")
        components?.queryItems = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json")
        ] + queryItems

        guard let url = components?.url else {
            throw ServiceError.invalidRequest
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
#if DEBUG
            print("[LastFM] request failed=\(error.localizedDescription)")
#endif
            throw ServiceError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

#if DEBUG
        print("[LastFM] HTTP status=\(httpResponse.statusCode)")
#endif

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
#if DEBUG
            if let apiError {
                print("[LastFM] API error=\(apiError.error)/\(apiError.message)")
            }
#endif
            throw ServiceError.api(
                code: apiError?.error,
                message: apiError?.message ?? "HTTP \(httpResponse.statusCode)"
            )
        }

        if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
#if DEBUG
            print("[LastFM] API error=\(apiError.error)/\(apiError.message)")
#endif
            throw ServiceError.api(code: apiError.error, message: apiError.message)
        }
        return data
    }

    private func apiKey() throws -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "LASTFM_API_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let isAvailable = value?.isEmpty == false
            && value?.contains("$(LASTFM_API_KEY)") == false
#if DEBUG
        print("[LastFM] API key available=\(isAvailable)")
#endif

        guard
            let value,
            isAvailable
        else {
            throw ServiceError.missingAPIKey
        }
        return value
    }
}

private struct SimilarTracksResponse: Decodable {
    let similartracks: SimilarTracks

    struct SimilarTracks: Decodable {
        let track: [Item]
        let attributes: Attributes?

        private enum CodingKeys: String, CodingKey {
            case track
            case attributes = "@attr"
        }
    }

    struct Attributes: Decodable {
        let artist: String
        let track: String
    }

    struct Item: Decodable {
        let name: String
        let match: Double
        let url: String?
        let artist: Artist

        private enum CodingKeys: String, CodingKey {
            case name
            case match
            case url
            case artist
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            artist = try container.decode(Artist.self, forKey: .artist)

            if let numericMatch = try? container.decode(Double.self, forKey: .match) {
                match = numericMatch
            } else {
                let stringMatch = try container.decode(String.self, forKey: .match)
                guard let numericMatch = Double(stringMatch) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .match,
                        in: container,
                        debugDescription: "Expected a numeric Last.fm match score."
                    )
                }
                match = numericMatch
            }
        }
    }

    struct Artist: Decodable {
        let name: String
    }
}

private struct TopTagsResponse: Decodable {
    let toptags: TopTags

    struct TopTags: Decodable {
        let tag: [Tag]
    }

    struct Tag: Decodable {
        let name: String
        let count: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            if let value = try? container.decode(Int.self, forKey: .count) {
                count = value
            } else {
                let value = try container.decode(String.self, forKey: .count)
                count = Int(value) ?? 0
            }
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case count
        }
    }
}

private struct TopTracksResponse: Decodable {
    let toptracks: TopTracks

    struct TopTracks: Decodable {
        let track: [Item]
    }

    struct Item: Decodable {
        let name: String
        let artist: Artist
    }

    struct Artist: Decodable {
        let name: String
    }
}

private struct APIErrorResponse: Decodable {
    let error: Int
    let message: String
}
