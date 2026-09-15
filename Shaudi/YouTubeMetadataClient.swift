//
//  YouTubeMetadataClient.swift
//  Shaudi
//

import Foundation

struct YouTubeMetadata {
    let title: String
    let channelTitle: String?
    let thumbnailURL: URL?
    let duration: TimeInterval?
}

struct YouTubeSearchResult: Identifiable, Hashable {
    let youtubeVideoID: String
    let title: String
    let channelTitle: String
    let thumbnailURL: URL?

    var id: String {
        youtubeVideoID
    }
}

struct YouTubeSearchPage {
    let results: [YouTubeSearchResult]
    let nextPageToken: String?
}

struct YouTubeMetadataClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case missingBundleIdentifier
        case invalidResponse
        case network(String)
        case api(String)
        case quotaExceeded
        case malformedResponse
        case videoUnavailable

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "YouTube metadata is unavailable because YOUTUBE_API_KEY is not configured. Add it to the local Secrets.xcconfig file."
            case .missingBundleIdentifier:
                return "YouTube metadata is unavailable because the app bundle identifier could not be determined."
            case .invalidResponse:
                return "YouTube returned an invalid response. Please try again."
            case .network(let message):
                return "Could not reach YouTube: \(message)"
            case .api(let message):
                return "YouTube could not provide metadata: \(message)"
            case .quotaExceeded:
                return "YouTube Data API search quota is unavailable."
            case .malformedResponse:
                return "YouTube returned metadata in an unexpected format."
            case .videoUnavailable:
                return "This video is unavailable or was not returned by YouTube."
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, pageToken: String? = nil) async throws -> YouTubeSearchPage {
        var queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "maxResults", value: "15"),
            URLQueryItem(
                name: "fields",
                value: "nextPageToken,items(id/videoId,snippet(title,channelTitle,thumbnails(default(url),medium(url),high(url))))"
            )
        ]

        if let pageToken, !pageToken.isEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        let data = try await request(endpoint: "search", queryItems: queryItems)
        let decodedResponse: SearchResponse

        do {
            decodedResponse = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw ClientError.malformedResponse
        }

        var seenVideoIDs = Set<String>()
        let results = decodedResponse.items.compactMap { item -> YouTubeSearchResult? in
            let videoID = item.id?.videoId?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
            let title = item.snippet?.title?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
            let channelTitle = item.snippet?.channelTitle?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""

            guard
                videoID.range(
                    of: #"^[A-Za-z0-9_-]{11}$"#,
                    options: .regularExpression
                ) != nil,
                !title.isEmpty,
                !channelTitle.isEmpty,
                seenVideoIDs.insert(videoID).inserted
            else {
                return nil
            }

            return YouTubeSearchResult(
                youtubeVideoID: videoID,
                title: title,
                channelTitle: channelTitle,
                thumbnailURL: item.snippet?.thumbnails?.preferredURL
            )
        }

        return YouTubeSearchPage(
            results: results,
            nextPageToken: decodedResponse.nextPageToken
        )
    }

    func metadata(for videoID: String) async throws -> YouTubeMetadata {
        let data = try await request(endpoint: "videos", queryItems: [
            URLQueryItem(name: "part", value: "snippet,contentDetails"),
            URLQueryItem(name: "id", value: videoID),
            URLQueryItem(
                name: "fields",
                value: "items(id,snippet(title,channelTitle,thumbnails(default(url),medium(url),high(url),standard(url),maxres(url))),contentDetails(duration))"
            )
        ])

        let decodedResponse: VideosResponse

        do {
            decodedResponse = try JSONDecoder().decode(VideosResponse.self, from: data)
        } catch {
            throw ClientError.malformedResponse
        }

        guard let item = decodedResponse.items.first else {
            throw ClientError.videoUnavailable
        }

        guard item.id == videoID else {
            throw ClientError.malformedResponse
        }

        let title = item.snippet?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            throw ClientError.malformedResponse
        }

        let channelTitle = item.snippet?.channelTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        return YouTubeMetadata(
            title: title,
            channelTitle: channelTitle?.isEmpty == false ? channelTitle : nil,
            thumbnailURL: item.snippet?.thumbnails?.preferredURL,
            duration: item.contentDetails?.duration.flatMap(YouTubeDuration.seconds(from:))
        )
    }

    private func request(endpoint: String, queryItems: [URLQueryItem]) async throws -> Data {
        let apiKey = try apiKey()

        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw ClientError.missingBundleIdentifier
        }

        var components = URLComponents(
            string: "https://www.googleapis.com/youtube/v3/\(endpoint)"
        )
        components?.queryItems = queryItems + [URLQueryItem(name: "key", value: apiKey)]

        guard let url = components?.url else {
            throw ClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue(bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClientError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error
            if apiError?.isQuotaExceeded == true {
                throw ClientError.quotaExceeded
            }
            throw ClientError.api(apiError?.message ?? "HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    private func apiKey() throws -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "YOUTUBE_API_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let value,
            !value.isEmpty,
            !value.contains("$(YOUTUBE_API_KEY)")
        else {
            throw ClientError.missingAPIKey
        }

        return value
    }
}

enum YouTubeDuration {
    static func seconds(from value: String) -> TimeInterval? {
        let pattern = #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: fullRange) else {
            return nil
        }

        var foundComponent = false

        func component(at index: Int) -> Double {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else {
                return 0
            }

            foundComponent = true
            return Double(value[swiftRange]) ?? 0
        }

        let days = component(at: 1)
        let hours = component(at: 2)
        let minutes = component(at: 3)
        let seconds = component(at: 4)

        guard foundComponent else {
            return nil
        }

        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }

    static func formatted(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct VideosResponse: Decodable {
    let items: [VideoItem]
}

private struct SearchResponse: Decodable {
    let nextPageToken: String?
    let items: [SearchItem]
}

private struct SearchItem: Decodable {
    let id: SearchItemID?
    let snippet: SearchSnippet?
}

private struct SearchItemID: Decodable {
    let videoId: String?
}

private struct SearchSnippet: Decodable {
    let title: String?
    let channelTitle: String?
    let thumbnails: Thumbnails?
}

private struct VideoItem: Decodable {
    let id: String
    let snippet: Snippet?
    let contentDetails: ContentDetails?
}

private struct Snippet: Decodable {
    let title: String?
    let channelTitle: String?
    let thumbnails: Thumbnails?
}

private struct Thumbnails: Decodable {
    let `default`: Thumbnail?
    let medium: Thumbnail?
    let high: Thumbnail?
    let standard: Thumbnail?
    let maxres: Thumbnail?

    var preferredURL: URL? {
        [maxres, standard, high, medium, `default`]
            .compactMap(\.self)
            .compactMap { URL(string: $0.url) }
            .first
    }
}

private struct Thumbnail: Decodable {
    let url: String
}

private struct ContentDetails: Decodable {
    let duration: String?
}

private struct APIErrorEnvelope: Decodable {
    let error: APIError
}

private struct APIError: Decodable {
    let message: String
    let errors: [APIErrorDetail]?

    var isQuotaExceeded: Bool {
        message.localizedCaseInsensitiveContains("quota")
            || errors?.contains(where: {
                $0.reason == "quotaExceeded" || $0.reason == "dailyLimitExceeded"
            }) == true
    }
}

private struct APIErrorDetail: Decodable {
    let reason: String
}
