//
//  YouTubeStructuredSearchClient.swift
//  Shaudi
//

import Foundation

enum YouTubeStructuredResultType: String, Codable {
    case song
    case video
    case unknown
}

struct YouTubeStructuredSearchCandidate: Equatable {
    let videoID: String
    let title: String
    let artistOrChannel: String
    let duration: TimeInterval?
    let thumbnailURL: URL?
    let resultType: YouTubeStructuredResultType

    var searchResult: YouTubeSearchResult {
        YouTubeSearchResult(
            youtubeVideoID: videoID,
            title: title,
            channelTitle: artistOrChannel,
            thumbnailURL: thumbnailURL,
            duration: duration
        )
    }
}

struct YouTubeStructuredSearchClient {
    enum ClientError: LocalizedError {
        case invalidRequest
        case invalidResponse
        case httpStatus(Int)
        case network(URLError.Code, String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return "The structured YouTube search request could not be created."
            case .invalidResponse:
                return "Structured YouTube search returned an invalid response."
            case .httpStatus(let status):
                return "Structured YouTube search returned HTTP \(status)."
            case .network(_, let message):
                return "Could not reach structured YouTube search: \(message)"
            case .malformedResponse:
                return "Structured YouTube search returned an unexpected payload."
            }
        }
    }

    struct ParseDiagnostics: Equatable {
        var cardShelves = 0
        var itemSections = 0
        var musicShelves = 0
        var responsiveRows = 0
    }

    struct ParsedCandidates {
        let candidates: [YouTubeStructuredSearchCandidate]
        let diagnostics: ParseDiagnostics
    }

    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    private enum Configuration {
        // This is the public client identifier shipped in YouTube's web clients,
        // not Shaudi's official YouTube Data API credential.
        static let apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
        static let clientName = "WEB_REMIX"
        // Kaset's current WEB_REMIX request context, revalidated in 2026.
        static let clientVersion = "1.20231204.01.00"
        static let songsFilter = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    }

    private struct SearchRequest: Encodable {
        let context: Context
        let query: String
        let params: String

        struct Context: Encodable {
            let client: Client
            let user: User

            struct Client: Encodable {
                let clientName: String
                let clientVersion: String
                let hl: String
                let gl: String
                let platform: String
            }

            struct User: Encodable {
                let lockedSafetyMode: Bool
            }
        }
    }

    private static let maximumTraversalDepth = 32
    private static let maximumTraversalNodes = 20_000
    private let loadData: DataLoader

    init(session: URLSession = .shared) {
        loadData = { request in
            try await session.data(for: request)
        }
    }

    init(loadData: @escaping DataLoader) {
        self.loadData = loadData
    }

    func search(query: String, limit: Int = 15) async throws -> [YouTubeStructuredSearchCandidate] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw ClientError.invalidRequest
        }
        var components = URLComponents(
            string: "https://music.youtube.com/youtubei/v1/search"
        )
        components?.queryItems = [
            URLQueryItem(name: "key", value: Configuration.apiKey),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]
        guard let url = components?.url else {
            throw ClientError.invalidRequest
        }

        let body = SearchRequest(
            context: .init(
                client: .init(
                    clientName: Configuration.clientName,
                    clientVersion: Configuration.clientVersion,
                    hl: "en",
                    gl: "US",
                    platform: "DESKTOP"
                ),
                user: .init(lockedSafetyMode: false)
            ),
            query: trimmedQuery,
            params: Configuration.songsFilter
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loadData(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw ClientError.network(error.code, error.localizedDescription)
        } catch {
            throw ClientError.network(.unknown, error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
#if DEBUG
        print("[StructuredSearch] HTTP status=\(httpResponse.statusCode)")
        print("[StructuredSearch] responseBytes=\(data.count)")
#endif
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.httpStatus(httpResponse.statusCode)
        }

        let parsed: ParsedCandidates
        do {
            parsed = try Self.parse(data, limit: limit)
        } catch {
#if DEBUG
            print("[StructuredSearch] parseSuccess=false")
            print("[StructuredSearch] emptyReason=schemaOrParserFailure")
#endif
            throw error
        }
#if DEBUG
        print("[StructuredSearch] parseSuccess=true")
        print("[StructuredSearch] cardShelves=\(parsed.diagnostics.cardShelves)")
        print("[StructuredSearch] itemSections=\(parsed.diagnostics.itemSections)")
        print("[StructuredSearch] musicShelves=\(parsed.diagnostics.musicShelves)")
        print("[StructuredSearch] responsiveRows=\(parsed.diagnostics.responsiveRows)")
        print("[StructuredSearch] candidatesExtracted=\(parsed.candidates.count)")
        if parsed.candidates.isEmpty {
            let reason = parsed.diagnostics.responsiveRows == 0
                && parsed.diagnostics.cardShelves == 0
                ? "noSupportedRenderers"
                : "noPlayableCandidates"
            print("[StructuredSearch] emptyReason=\(reason)")
        }
        for candidate in parsed.candidates {
            print(
                "[StructuredSearch] candidate videoID=\(candidate.videoID) "
                    + "title=\(candidate.title) artist=\(candidate.artistOrChannel)"
            )
        }
#endif
        return parsed.candidates
    }

    static func candidates(
        from data: Data,
        limit: Int = 15
    ) throws -> [YouTubeStructuredSearchCandidate] {
        try parse(data, limit: limit).candidates
    }

    static func parse(
        _ data: Data,
        limit: Int = 15
    ) throws -> ParsedCandidates {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ClientError.malformedResponse
        }
        guard let root = json as? [String: Any], hasRecognizedEnvelope(root) else {
            throw ClientError.malformedResponse
        }

        var diagnostics = ParseDiagnostics()
        var extracted: [YouTubeStructuredSearchCandidate] = []
        var nodes: [(value: Any, depth: Int)] = [(root, 0)]
        var visitedNodeCount = 0
        var exceededBounds = false

        while let node = nodes.popLast() {
            visitedNodeCount += 1
            guard visitedNodeCount <= maximumTraversalNodes else {
                exceededBounds = true
                break
            }
            guard node.depth <= maximumTraversalDepth else {
                exceededBounds = true
                continue
            }

            if let dictionary = node.value as? [String: Any] {
                if let card = dictionary["musicCardShelfRenderer"] as? [String: Any] {
                    diagnostics.cardShelves += 1
                    if let candidate = candidate(from: card, isCard: true) {
                        extracted.append(candidate)
                    }
                }
                if dictionary["itemSectionRenderer"] is [String: Any] {
                    diagnostics.itemSections += 1
                }
                if dictionary["musicShelfRenderer"] is [String: Any] {
                    diagnostics.musicShelves += 1
                }
                if let row = dictionary["musicResponsiveListItemRenderer"] as? [String: Any] {
                    diagnostics.responsiveRows += 1
                    if let candidate = candidate(from: row, isCard: false) {
                        extracted.append(candidate)
                    }
                }
                for value in dictionary.values {
                    nodes.append((value, node.depth + 1))
                }
            } else if let array = node.value as? [Any] {
                for value in array.reversed() {
                    nodes.append((value, node.depth + 1))
                }
            }
        }

        // A valid candidate found before the bound remains usable. If the
        // response only contained an unexpectedly deep/large unknown shape,
        // fail it as a schema/parser error instead of reporting a clean miss.
        guard !exceededBounds || !extracted.isEmpty else {
            throw ClientError.malformedResponse
        }
        var seenVideoIDs = Set<String>()
        let candidates = extracted.filter {
            seenVideoIDs.insert($0.videoID).inserted
        }.prefix(max(0, limit)).map { $0 }
        return ParsedCandidates(candidates: candidates, diagnostics: diagnostics)
    }

    private static func hasRecognizedEnvelope(_ root: [String: Any]) -> Bool {
        if let contents = root["contents"] as? [String: Any] {
            let keys = Set(contents.keys)
            if !keys.isDisjoint(with: [
                "tabbedSearchResultsRenderer",
                "sectionListRenderer",
                "musicCardShelfRenderer",
                "musicShelfRenderer",
                "itemSectionRenderer",
                "musicResponsiveListItemRenderer"
            ]) {
                return true
            }
        }
        if root["continuationContents"] is [String: Any] {
            return true
        }
        return [
            "onResponseReceivedActions",
            "onResponseReceivedCommands",
            "onResponseReceivedEndpoints"
        ].contains { root[$0] is [Any] }
    }

    private static func candidate(
        from renderer: [String: Any],
        isCard: Bool
    ) -> YouTubeStructuredSearchCandidate? {
        guard let videoID = videoID(from: renderer), isValidVideoID(videoID) else {
            return nil
        }

        let columns = flexColumnTexts(from: renderer)
        let title = isCard
            ? renderedText(from: renderer["title"])
            : columns.first
        guard let title = title?.trimmedNonempty else {
            return nil
        }

        var metadataValues = columns.dropFirst().flatMap { splitMetadata($0) }
        metadataValues.append(contentsOf: splitMetadata(renderedText(from: renderer["subtitle"])))
        metadataValues = metadataValues.compactMap(\.trimmedNonempty)

        let type = resultType(from: metadataValues)
        let artist = metadataValues.first(where: {
            !isMetadataLabel($0) && duration(from: $0) == nil
        }) ?? "YouTube Music"
        let durationText = fixedColumnTexts(from: renderer).first(where: {
            duration(from: $0) != nil
        }) ?? metadataValues.first(where: { duration(from: $0) != nil })

        return YouTubeStructuredSearchCandidate(
            videoID: videoID,
            title: MusicMetadataText.decoded(title),
            artistOrChannel: MusicMetadataText.decoded(artist),
            duration: durationText.flatMap { duration(from: $0) },
            thumbnailURL: thumbnailURL(from: renderer),
            resultType: type
        )
    }

    private static func videoID(from renderer: [String: Any]) -> String? {
        if let playlistItemData = renderer["playlistItemData"] as? [String: Any],
           let videoID = playlistItemData["videoId"] as? String {
            return videoID
        }
        if let videoID = endpointVideoID(renderer["navigationEndpoint"])
            ?? endpointVideoID(renderer["onTap"]) {
            return videoID
        }
        for run in flexColumnRuns(from: renderer) {
            if let videoID = endpointVideoID(run["navigationEndpoint"]) {
                return videoID
            }
        }
        for key in ["overlay", "thumbnailOverlay"] {
            if let videoID = playButtonVideoID(from: renderer[key]) {
                return videoID
            }
        }
        if let title = renderer["title"] as? [String: Any],
           let runs = title["runs"] as? [[String: Any]] {
            for run in runs {
                if let videoID = endpointVideoID(run["navigationEndpoint"]) {
                    return videoID
                }
            }
        }
        return nil
    }

    private static func endpointVideoID(_ value: Any?) -> String? {
        guard var endpoint = value as? [String: Any] else {
            return nil
        }
        if let command = endpoint["innertubeCommand"] as? [String: Any] {
            endpoint = command
        }
        return (endpoint["watchEndpoint"] as? [String: Any])?["videoId"] as? String
    }

    private static func playButtonVideoID(from value: Any?) -> String? {
        guard let overlay = value as? [String: Any] else {
            return nil
        }
        let thumbnailOverlay = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any]
            ?? overlay
        let content = thumbnailOverlay["content"] as? [String: Any]
        let playButton = content?["musicPlayButtonRenderer"] as? [String: Any]
            ?? thumbnailOverlay["musicPlayButtonRenderer"] as? [String: Any]
        return endpointVideoID(playButton?["playNavigationEndpoint"])
    }

    private static func flexColumnTexts(from renderer: [String: Any]) -> [String] {
        guard let columns = renderer["flexColumns"] as? [[String: Any]] else {
            return []
        }
        return columns.compactMap {
            guard let column = $0["musicResponsiveListItemFlexColumnRenderer"]
                as? [String: Any] else {
                return nil
            }
            return renderedText(from: column["text"])
        }
    }

    private static func fixedColumnTexts(from renderer: [String: Any]) -> [String] {
        guard let columns = renderer["fixedColumns"] as? [[String: Any]] else {
            return []
        }
        return columns.compactMap {
            guard let column = $0["musicResponsiveListItemFixedColumnRenderer"]
                as? [String: Any] else {
                return nil
            }
            return renderedText(from: column["text"])
        }
    }

    private static func flexColumnRuns(from renderer: [String: Any]) -> [[String: Any]] {
        guard let columns = renderer["flexColumns"] as? [[String: Any]] else {
            return []
        }
        return columns.flatMap {
            let column = $0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
            let text = column?["text"] as? [String: Any]
            return text?["runs"] as? [[String: Any]] ?? []
        }
    }

    private static func renderedText(from value: Any?) -> String? {
        guard let text = value as? [String: Any] else {
            return nil
        }
        if let simpleText = text["simpleText"] as? String {
            return simpleText
        }
        guard let runs = text["runs"] as? [[String: Any]] else {
            return nil
        }
        return runs.compactMap { $0["text"] as? String }.joined()
    }

    private static func splitMetadata(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.components(separatedBy: "•")
    }

    private static func thumbnailURL(from renderer: [String: Any]) -> URL? {
        guard let thumbnail = renderer["thumbnail"] as? [String: Any],
              let musicThumbnail = thumbnail["musicThumbnailRenderer"] as? [String: Any],
              let innerThumbnail = musicThumbnail["thumbnail"] as? [String: Any],
              let thumbnails = innerThumbnail["thumbnails"] as? [[String: Any]]
        else {
            return nil
        }
        return thumbnails.reversed().compactMap {
            ($0["url"] as? String).flatMap(URL.init(string:))
        }.first
    }

    private static func resultType(from values: [String]) -> YouTubeStructuredResultType {
        if values.contains(where: { $0.caseInsensitiveCompare("Song") == .orderedSame }) {
            return .song
        }
        if values.contains(where: { $0.caseInsensitiveCompare("Video") == .orderedSame }) {
            return .video
        }
        return .unknown
    }

    private static func isMetadataLabel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "song"
            || normalized == "video"
            || normalized == "episode"
            || normalized == "podcast"
            || normalized.isEmpty
            || Int(normalized) != nil
    }

    private static func duration(from value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ":")
        guard components.count == 2 || components.count == 3,
              components.allSatisfy({ Int($0) != nil })
        else {
            return nil
        }
        return components.compactMap { Int($0) }.reduce(0.0) {
            $0 * 60 + TimeInterval($1)
        }
    }

    private static func isValidVideoID(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9_-]{11}$"#,
            options: .regularExpression
        ) != nil
    }
}

private extension String {
    var trimmedNonempty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
