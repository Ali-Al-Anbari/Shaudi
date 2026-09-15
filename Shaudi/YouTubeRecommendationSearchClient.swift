//
//  YouTubeRecommendationSearchClient.swift
//  Shaudi
//

import Foundation

struct YouTubeWebSearchClient {
    enum SearchError: LocalizedError {
        case invalidRequest
        case invalidResponse
        case httpStatus(Int)
        case tooManyHTTPRedirects
        case abuseChallenge
        case network(String)
        case noResultsPayload

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return "The YouTube web search request could not be created."
            case .invalidResponse:
                return "YouTube web search returned an invalid response."
            case .httpStatus(let statusCode):
                return "YouTube web search returned HTTP \(statusCode)."
            case .tooManyHTTPRedirects:
                return "YouTube web search was stopped after too many HTTP redirects."
            case .abuseChallenge:
                return "YouTube web search was redirected to an abuse challenge."
            case .network(let message):
                return "Could not reach YouTube web search: \(message)"
            case .noResultsPayload:
                return "YouTube web search did not contain a results payload."
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, limit: Int = 15) async throws -> [YouTubeSearchResult] {
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [URLQueryItem(name: "search_query", value: query)]
        guard let url = components?.url else {
            throw SearchError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 12

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .httpTooManyRedirects {
            throw SearchError.tooManyHTTPRedirects
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == URLError.Code.httpTooManyRedirects.rawValue {
                throw SearchError.tooManyHTTPRedirects
            }
            throw SearchError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchError.invalidResponse
        }
        if Self.isAbuseChallengeURL(httpResponse.url) {
            throw SearchError.abuseChallenge
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SearchError.httpStatus(httpResponse.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.invalidResponse
        }

        let results = Self.results(fromHTML: html, limit: limit)
        guard !results.isEmpty else {
            throw SearchError.noResultsPayload
        }
        return results
    }

    static func isAbuseChallengeURL(_ url: URL?) -> Bool {
        guard let url else {
            return false
        }
        let host = url.host?.lowercased() ?? ""
        let text = url.absoluteString.lowercased()
        return (host.hasSuffix("google.com") || host.hasSuffix("youtube.com"))
            && (text.contains("/sorry/")
                || text.contains("recaptcha")
                || text.contains("challenge"))
    }

    static func results(fromHTML html: String, limit: Int = 15) -> [YouTubeSearchResult] {
        let marker = #""videoRenderer":"#
        var searchStart = html.startIndex
        var results: [YouTubeSearchResult] = []
        var seenVideoIDs = Set<String>()

        while
            results.count < limit,
            let markerRange = html.range(of: marker, range: searchStart..<html.endIndex),
            let objectStart = html[markerRange.upperBound...].firstIndex(of: "{")
        {
            guard let objectRange = jsonObjectRange(in: html, startingAt: objectStart) else {
                break
            }
            searchStart = objectRange.upperBound
            let objectData = Data(html[objectRange].utf8)
            if
                let renderer = try? JSONSerialization.jsonObject(with: objectData) as? [String: Any],
                let result = result(fromRenderer: renderer),
                seenVideoIDs.insert(result.youtubeVideoID).inserted
            {
                results.append(result)
            }
        }
        return results
    }

    private static func jsonObjectRange(
        in value: String,
        startingAt start: String.Index
    ) -> Range<String.Index>? {
        var index = start
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        while index < value.endIndex {
            let character = value[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return start..<value.index(after: index)
                }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func result(fromRenderer renderer: [String: Any]) -> YouTubeSearchResult? {
        guard
            let videoID = renderer["videoId"] as? String,
            videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
            let title = text(from: renderer["title"]),
            let channel = text(from: renderer["ownerText"])
                ?? text(from: renderer["longBylineText"])
                ?? text(from: renderer["shortBylineText"])
        else {
            return nil
        }

        let thumbnails = (renderer["thumbnail"] as? [String: Any])?["thumbnails"]
            as? [[String: Any]]
        let thumbnailURL = thumbnails?.reversed().compactMap { thumbnail in
            (thumbnail["url"] as? String).flatMap(URL.init(string:))
        }.first

        return YouTubeSearchResult(
            youtubeVideoID: videoID,
            title: SongNormalization.humanReadable(title),
            channelTitle: SongNormalization.humanReadable(channel),
            thumbnailURL: thumbnailURL
        )
    }

    private static func text(from value: Any?) -> String? {
        guard let object = value as? [String: Any] else {
            return nil
        }
        if let simpleText = object["simpleText"] as? String, !simpleText.isEmpty {
            return simpleText
        }
        guard let runs = object["runs"] as? [[String: Any]] else {
            return nil
        }
        let result = runs.compactMap { $0["text"] as? String }.joined()
        return result.isEmpty ? nil : result
    }
}

@MainActor
final class YouTubeRecommendationResolver {
    typealias SearchOperation = (String) async throws -> [YouTubeSearchResult]

    private let primarySearch: SearchOperation
    private let dataAPISearch: SearchOperation
    private(set) var isWebSearchCircuitOpen = false
    private(set) var isDataAPIQuotaCircuitOpen = false

    init(
        webSearchClient: YouTubeWebSearchClient? = nil,
        dataAPIClient: YouTubeMetadataClient? = nil
    ) {
        let webSearchClient = webSearchClient ?? YouTubeWebSearchClient()
        let dataAPIClient = dataAPIClient ?? YouTubeMetadataClient()
        primarySearch = { query in
            try await webSearchClient.search(query: query)
        }
        dataAPISearch = { query in
            try await dataAPIClient.search(query: query).results
        }
    }

    init(
        primarySearch: @escaping SearchOperation,
        dataAPISearch: @escaping SearchOperation
    ) {
        self.primarySearch = primarySearch
        self.dataAPISearch = dataAPISearch
    }

    func primaryResults(query: String) async throws -> [YouTubeSearchResult] {
        guard !isWebSearchCircuitOpen else {
#if DEBUG
            print("[RecommendationResolver] source=YouTubeWeb circuitOpen=true")
#endif
            return []
        }
#if DEBUG
        print("[RecommendationResolver] source=YouTubeWeb target=\(query)")
#endif
        do {
            return try await primarySearch(query)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.shouldOpenWebSearchCircuit(for: error) {
                isWebSearchCircuitOpen = true
            }
#if DEBUG
            print("[RecommendationResolver] YouTubeWeb failed=\(error.localizedDescription)")
            if isWebSearchCircuitOpen {
                print("[RecommendationResolver] source=YouTubeWeb circuitOpen=true")
            }
#endif
            return []
        }
    }

    private static func shouldOpenWebSearchCircuit(for error: Error) -> Bool {
        if let searchError = error as? YouTubeWebSearchClient.SearchError {
            switch searchError {
            case .tooManyHTTPRedirects, .abuseChallenge:
                return true
            case .httpStatus(let statusCode):
                return statusCode == 403 || statusCode == 429
            default:
                return false
            }
        }
        let urlError = error as? URLError
        if urlError?.code == .httpTooManyRedirects {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == URLError.Code.httpTooManyRedirects.rawValue
    }

    func dataAPIFallbackResults(query: String) async throws -> [YouTubeSearchResult] {
        guard !isDataAPIQuotaCircuitOpen else {
#if DEBUG
            print("[RecommendationResolver] source=DataAPI quotaCircuitOpen=true")
#endif
            return []
        }

#if DEBUG
        print("[RecommendationResolver] source=DataAPI target=\(query)")
#endif
        do {
            return try await dataAPISearch(query)
        } catch YouTubeMetadataClient.ClientError.quotaExceeded {
            isDataAPIQuotaCircuitOpen = true
#if DEBUG
            print("[YouTubeResolver] Data API quota unavailable; disabling Data API search for current runtime")
            print("[RecommendationResolver] source=DataAPI quotaCircuitOpen=true")
#endif
            return []
        } catch is CancellationError {
            throw CancellationError()
        } catch {
#if DEBUG
            print("[RecommendationResolver] DataAPI failed=\(error.localizedDescription)")
#endif
            return []
        }
    }
}
