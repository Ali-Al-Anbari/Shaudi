//
//  YouTubePlaylistExtractionClient.swift
//  Shaudi
//

import Foundation

enum YouTubePlaylistExtractionError: LocalizedError, Equatable {
    case invalidURL
    case missingPlaylistID
    case malformedPlaylistID
    case playlistNotFound
    case unsupportedOrPrivate
    case emptyOrUnusablePlaylist(unavailableCount: Int)
    case malformedPayload
    case continuationFailed(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Please enter a valid YouTube playlist URL."
        case .missingPlaylistID:
            return "No playlist ID was found in this URL."
        case .malformedPlaylistID:
            return "The playlist ID in this URL is invalid."
        case .playlistNotFound:
            return "This YouTube playlist could not be found. Please check the URL."
        case .unsupportedOrPrivate:
            return "This playlist is private or unsupported. Only public and unlisted playlists can be imported."
        case .emptyOrUnusablePlaylist(let unavailableCount):
            if unavailableCount > 0 {
                return "All \(unavailableCount) videos in this playlist are deleted, private, or unavailable."
            }
            return "No usable songs were found in this playlist."
        case .malformedPayload:
            return "YouTube returned playlist data in an unexpected format."
        case .continuationFailed(let reason):
            return "Could not load the complete playlist: \(reason)"
        case .network(let message):
            return "Could not reach YouTube: \(message)"
        }
    }
}

struct YouTubePlaylistExtractionClient {
    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    private enum Configuration {
        // Public client identifier shipped in YouTube web clients.
        // Consumes ZERO YouTube Data API quota.
        static let apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
        static let webClientName = "WEB"
        static let webClientVersion = "2.20231204.01.00"
        static let remixClientName = "WEB_REMIX"
        static let remixClientVersion = "1.20231204.01.00"
    }

    struct RawParsedItem: Equatable {
        let videoID: String?
        let title: String?
        let artist: String?
        let thumbnailURL: URL?
        let isPlayable: Bool?
    }

    struct PageParseResult: Equatable {
        let items: [RawParsedItem]
        let continuationToken: String?
        let playlistTitle: String?
    }

    private let loadData: DataLoader

    init(session: URLSession = .shared) {
        self.loadData = { request in
            try await session.data(for: request)
        }
    }

    init(loadData: @escaping DataLoader) {
        self.loadData = loadData
    }

    func fetchPlaylist(
        from urlString: String,
        onProgress: ((Int) -> Void)? = nil
    ) async throws -> ExtractedYouTubePlaylist {
        guard let parsed = YouTubeURLParser.parsePlaylist(urlString) else {
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw YouTubePlaylistExtractionError.invalidURL
            }
            if !trimmed.contains("list=") && !YouTubeURLParser.isUsablePlaylistID(trimmed) {
                throw YouTubePlaylistExtractionError.missingPlaylistID
            }
            throw YouTubePlaylistExtractionError.malformedPlaylistID
        }

        return try await fetchPlaylist(playlistID: parsed.id, onProgress: onProgress)
    }

    func fetchPlaylist(
        playlistID: String,
        onProgress: ((Int) -> Void)? = nil
    ) async throws -> ExtractedYouTubePlaylist {
        guard YouTubeURLParser.isUsablePlaylistID(playlistID) else {
            throw YouTubePlaylistExtractionError.malformedPlaylistID
        }

        var allRawItems: [RawParsedItem] = []
        var discoveredTitle: String? = nil
        var currentContinuationToken: String? = nil
        var seenTokens = Set<String>()

        // 1. First page request
        let initialData = try await requestInitialPage(playlistID: playlistID)
        let initialPage = try Self.parsePage(initialData)

        discoveredTitle = initialPage.playlistTitle
        allRawItems.append(contentsOf: initialPage.items)
        currentContinuationToken = initialPage.continuationToken
        onProgress?(allRawItems.count)

        // 2. Follow continuation tokens until exhausted
        while let token = currentContinuationToken, !token.isEmpty {
            guard seenTokens.insert(token).inserted else {
                break
            }

            let continuationData: Data
            do {
                continuationData = try await requestContinuationPage(token: token)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw YouTubePlaylistExtractionError.continuationFailed(error.localizedDescription)
            }

            let continuationPage: PageParseResult
            do {
                continuationPage = try Self.parsePage(continuationData)
            } catch {
                throw YouTubePlaylistExtractionError.continuationFailed(error.localizedDescription)
            }

            if discoveredTitle == nil {
                discoveredTitle = continuationPage.playlistTitle
            }

            allRawItems.append(contentsOf: continuationPage.items)
            currentContinuationToken = continuationPage.continuationToken
            onProgress?(allRawItems.count)
        }

        // 3. Process raw items with filtering and deduplication
        var validItems: [PendingYouTubePlaylistItem] = []
        var seenVideoIDs = Set<String>()
        var unavailableSkippedCount = 0
        var duplicateSkippedCount = 0

        for raw in allRawItems {
            guard
                let videoID = raw.videoID?.trimmingCharacters(in: .whitespacesAndNewlines),
                YouTubeURLParser.isUsableVideoID(videoID),
                raw.isPlayable != false,
                let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty,
                !Self.isUnavailableTitle(title)
            else {
                unavailableSkippedCount += 1
                continue
            }

            guard seenVideoIDs.insert(videoID).inserted else {
                duplicateSkippedCount += 1
                continue
            }

            let pendingItem = PendingYouTubePlaylistItem(
                videoID: videoID,
                title: title,
                artist: raw.artist,
                thumbnailURL: raw.thumbnailURL,
                sourceOrder: validItems.count
            )
            validItems.append(pendingItem)
        }

        guard !validItems.isEmpty else {
            throw YouTubePlaylistExtractionError.emptyOrUnusablePlaylist(
                unavailableCount: unavailableSkippedCount
            )
        }

        return ExtractedYouTubePlaylist(
            playlistID: playlistID,
            title: discoveredTitle,
            items: validItems,
            unavailableSkippedCount: unavailableSkippedCount,
            duplicateSkippedCount: duplicateSkippedCount
        )
    }

    private func requestInitialPage(playlistID: String) async throws -> Data {
        let browseID = playlistID.hasPrefix("VL") ? playlistID : "VL\(playlistID)"
        let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?key=\(Configuration.apiKey)&prettyPrint=false")!

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": Configuration.webClientName,
                    "clientVersion": Configuration.webClientVersion,
                    "hl": "en",
                    "gl": "US"
                ],
                "user": [
                    "lockedSafetyMode": false
                ]
            ],
            "browseId": browseID
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loadData(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw YouTubePlaylistExtractionError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubePlaylistExtractionError.malformedPayload
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404 {
                throw YouTubePlaylistExtractionError.playlistNotFound
            }
            throw YouTubePlaylistExtractionError.network("HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    private func requestContinuationPage(token: String) async throws -> Data {
        let escapedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        let urlString = "https://www.youtube.com/youtubei/v1/browse?key=\(Configuration.apiKey)&continuation=\(escapedToken)&prettyPrint=false"
        guard let url = URL(string: urlString) else {
            throw YouTubePlaylistExtractionError.malformedPayload
        }

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": Configuration.webClientName,
                    "clientVersion": Configuration.webClientVersion,
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "continuation": token
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loadData(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw YouTubePlaylistExtractionError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubePlaylistExtractionError.malformedPayload
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw YouTubePlaylistExtractionError.network("HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    static func parsePage(_ data: Data) throws -> PageParseResult {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw YouTubePlaylistExtractionError.malformedPayload
        }

        guard let root = json as? [String: Any] else {
            throw YouTubePlaylistExtractionError.malformedPayload
        }

        // Check alerts for playlist-level errors
        if let alerts = root["alerts"] as? [[String: Any]] {
            for alert in alerts {
                if let alertRenderer = alert["alertRenderer"] as? [String: Any],
                   let type = alertRenderer["type"] as? String,
                   type == "ERROR" {
                    let text = renderedText(from: alertRenderer["text"])?.lowercased() ?? ""
                    if text.contains("private") {
                        throw YouTubePlaylistExtractionError.unsupportedOrPrivate
                    }
                    if text.contains("does not exist") || text.contains("not found") {
                        throw YouTubePlaylistExtractionError.playlistNotFound
                    }
                    throw YouTubePlaylistExtractionError.unsupportedOrPrivate
                }
            }
        }

        // Check playlist title
        let playlistTitle = extractPlaylistTitle(from: root)

        // Traverse to find items and continuation
        var items: [RawParsedItem] = []
        var continuationToken: String? = nil
        var nodes: [(value: Any, depth: Int)] = [(root, 0)]
        var visitedNodes = 0
        let maxNodes = 30_000
        let maxDepth = 40

        while let node = nodes.popLast() {
            visitedNodes += 1
            if visitedNodes > maxNodes || node.depth > maxDepth {
                continue
            }

            if let dict = node.value as? [String: Any] {
                // 1. lockupViewModel (Desktop YouTube Web)
                if let lockup = dict["lockupViewModel"] as? [String: Any] {
                    if let item = parseLockupViewModel(lockup) {
                        items.append(item)
                    }
                }

                // 2. playlistVideoRenderer (Classic YouTube Web)
                if let pvr = dict["playlistVideoRenderer"] as? [String: Any] {
                    if let item = parsePlaylistVideoRenderer(pvr) {
                        items.append(item)
                    }
                }

                // 3. musicResponsiveListItemRenderer (YouTube Music)
                if let mrli = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                    if let item = parseMusicResponsiveListItemRenderer(mrli) {
                        items.append(item)
                    }
                }

                // 4. continuationItemRenderer
                if let cont = dict["continuationItemRenderer"] as? [String: Any],
                   continuationToken == nil {
                    continuationToken = extractContinuationToken(from: cont)
                }

                for value in dict.values {
                    nodes.append((value, node.depth + 1))
                }
            } else if let array = node.value as? [Any] {
                for value in array.reversed() {
                    nodes.append((value, node.depth + 1))
                }
            }
        }

        return PageParseResult(
            items: items,
            continuationToken: continuationToken,
            playlistTitle: playlistTitle
        )
    }

    private static func extractPlaylistTitle(from root: [String: Any]) -> String? {
        if let meta = root["metadata"] as? [String: Any],
           let playlistMeta = meta["playlistMetadataRenderer"] as? [String: Any],
           let title = playlistMeta["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MusicMetadataText.decoded(title.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let header = root["header"] as? [String: Any],
           let pageHeader = header["pageHeaderRenderer"] as? [String: Any],
           let pageTitle = pageHeader["pageTitle"] as? String,
           !pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MusicMetadataText.decoded(pageTitle.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let microformat = root["microformat"] as? [String: Any],
           let microData = microformat["microformatDataRenderer"] as? [String: Any],
           let title = microData["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MusicMetadataText.decoded(title.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    private static func parseLockupViewModel(_ lockup: [String: Any]) -> RawParsedItem? {
        // Video ID
        var videoID = lockup["contentId"] as? String
        if videoID == nil || !YouTubeURLParser.isUsableVideoID(videoID!) {
            videoID = endpointVideoID(lockup["commandContext"])
                ?? endpointVideoID(lockup["rendererContext"])
        }

        // Title & metadata
        let metadata = lockup["metadata"] as? [String: Any]
        let lockupMeta = metadata?["lockupMetadataViewModel"] as? [String: Any]
        let titleDict = lockupMeta?["title"] as? [String: Any]
        let title = (titleDict?["content"] as? String) ?? renderedText(from: titleDict)

        // Artist / Channel
        var artist: String? = nil
        let contentMeta = lockupMeta?["metadata"] as? [String: Any]
        let contentMetaVM = contentMeta?["contentMetadataViewModel"] as? [String: Any]
        if let rows = contentMetaVM?["metadataRows"] as? [[String: Any]],
           let firstRow = rows.first,
           let parts = firstRow["metadataParts"] as? [[String: Any]],
           let firstPart = parts.first,
           let text = firstPart["text"] as? [String: Any] {
            artist = text["content"] as? String
        }

        // Thumbnail
        var thumbnailURL: URL? = nil
        if let contentImage = lockup["contentImage"] as? [String: Any],
           let thumbVM = contentImage["thumbnailViewModel"] as? [String: Any],
           let image = thumbVM["image"] as? [String: Any],
           let sources = image["sources"] as? [[String: Any]] {
            thumbnailURL = preferredThumbnailURL(from: sources)
        }

        return RawParsedItem(
            videoID: videoID,
            title: title,
            artist: artist,
            thumbnailURL: thumbnailURL,
            isPlayable: true
        )
    }

    private static func parsePlaylistVideoRenderer(_ renderer: [String: Any]) -> RawParsedItem? {
        let videoID = renderer["videoId"] as? String
        let title = renderedText(from: renderer["title"])
        let artist = renderedText(from: renderer["shortBylineText"])
            ?? renderedText(from: renderer["longBylineText"])
        let isPlayable = renderer["isPlayable"] as? Bool

        var thumbnailURL: URL? = nil
        if let thumb = renderer["thumbnail"] as? [String: Any],
           let thumbnails = thumb["thumbnails"] as? [[String: Any]] {
            thumbnailURL = preferredThumbnailURL(from: thumbnails)
        }

        return RawParsedItem(
            videoID: videoID,
            title: title,
            artist: artist,
            thumbnailURL: thumbnailURL,
            isPlayable: isPlayable
        )
    }

    private static func parseMusicResponsiveListItemRenderer(_ renderer: [String: Any]) -> RawParsedItem? {
        var videoID: String? = nil
        if let playlistItemData = renderer["playlistItemData"] as? [String: Any] {
            videoID = playlistItemData["videoId"] as? String
        }
        if videoID == nil {
            videoID = endpointVideoID(renderer["navigationEndpoint"])
                ?? endpointVideoID(renderer["onTap"])
        }

        let columns = flexColumnTexts(from: renderer)
        let title = columns.first
        let artist = columns.count > 1 ? columns[1] : nil

        var thumbnailURL: URL? = nil
        if let thumb = renderer["thumbnail"] as? [String: Any],
           let musicThumb = thumb["musicThumbnailRenderer"] as? [String: Any],
           let innerThumb = musicThumb["thumbnail"] as? [String: Any],
           let thumbnails = innerThumb["thumbnails"] as? [[String: Any]] {
            thumbnailURL = preferredThumbnailURL(from: thumbnails)
        }

        return RawParsedItem(
            videoID: videoID,
            title: title,
            artist: artist,
            thumbnailURL: thumbnailURL,
            isPlayable: true
        )
    }

    private static func extractContinuationToken(from renderer: [String: Any]) -> String? {
        if let endpoint = renderer["continuationEndpoint"] as? [String: Any],
           let command = endpoint["continuationCommand"] as? [String: Any],
           let token = command["token"] as? String,
           !token.isEmpty {
            return token
        }
        return nil
    }

    private static func endpointVideoID(_ value: Any?) -> String? {
        guard var dict = value as? [String: Any] else { return nil }
        if let command = dict["innertubeCommand"] as? [String: Any] {
            dict = command
        }
        if let watch = dict["watchEndpoint"] as? [String: Any],
           let id = watch["videoId"] as? String {
            return id
        }
        if let onTap = dict["onTap"] as? [String: Any] {
            return endpointVideoID(onTap)
        }
        if let commandContext = dict["commandContext"] as? [String: Any] {
            return endpointVideoID(commandContext)
        }
        return nil
    }

    private static func flexColumnTexts(from renderer: [String: Any]) -> [String] {
        guard let columns = renderer["flexColumns"] as? [[String: Any]] else {
            return []
        }
        return columns.compactMap {
            guard let column = $0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any] else {
                return nil
            }
            return renderedText(from: column["text"])
        }
    }

    private static func renderedText(from value: Any?) -> String? {
        guard let value else { return nil }
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let dict = value as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String {
            let trimmed = simple.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let content = dict["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func preferredThumbnailURL(from sources: [[String: Any]]) -> URL? {
        // Prefer medium/higher quality (last or largest width in list)
        for source in sources.reversed() {
            if let urlString = source["url"] as? String,
               let url = URL(string: urlString) {
                return url
            }
        }
        return nil
    }

    private static func isUnavailableTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower == "[deleted video]"
            || lower == "[private video]"
            || lower == "deleted video"
            || lower == "private video"
            || lower == "[unavailable video]"
            || lower == "unavailable video"
    }
}
