//
//  YouTubeResolutionCache.swift
//  Shaudi
//

import Foundation

enum YouTubeResolutionKnowledgeSource: String, Codable {
    case structured
    case officialAPI
    case lastFMRecommendation
    case manualSearch
    case library
    case playlist
    case pastedURL
    case legacy
}

struct YouTubeResolutionMetadata {
    let title: String?
    let channel: String?
    let thumbnailURL: URL?
    let duration: TimeInterval?

    init(
        title: String? = nil,
        channel: String? = nil,
        thumbnailURL: URL? = nil,
        duration: TimeInterval? = nil
    ) {
        self.title = title
        self.channel = channel
        self.thumbnailURL = thumbnailURL
        self.duration = duration
    }

    init(_ result: YouTubeSearchResult) {
        self.init(
            title: result.title,
            channel: result.channelTitle,
            thumbnailURL: result.thumbnailURL,
            duration: result.duration
        )
    }
}

@MainActor
protocol YouTubeResolutionCaching {
    func learnedIdentity(forVideoID videoID: String) async -> SongIdentity?
    func peek(for identity: SongIdentity, now: Date) async -> YouTubeSearchResult?
    func result(for identity: SongIdentity, now: Date) async -> YouTubeSearchResult?
    @discardableResult
    func learn(
        _ identity: SongIdentity,
        videoID: String,
        metadata: YouTubeResolutionMetadata,
        source: YouTubeResolutionKnowledgeSource,
        now: Date
    ) async -> Bool
    func store(
        _ result: YouTubeSearchResult,
        for identity: SongIdentity,
        now: Date
    ) async
    func remove(_ identity: SongIdentity) async
}

extension YouTubeResolutionCaching {
    func learnedIdentity(forVideoID videoID: String) async -> SongIdentity? {
        nil
    }

    func store(
        _ result: YouTubeSearchResult,
        for identity: SongIdentity,
        now: Date
    ) async {
        await learn(
            identity,
            videoID: result.youtubeVideoID,
            metadata: YouTubeResolutionMetadata(result),
            source: .legacy,
            now: now
        )
    }
}

@MainActor
final class PersistentYouTubeResolutionCache: YouTubeResolutionCaching {
    static let shared = PersistentYouTubeResolutionCache()

    struct Policy {
        let maximumEntryCount: Int

        nonisolated static let standard = Policy(maximumEntryCount: 10_000)

        nonisolated init(maximumEntryCount: Int) {
            self.maximumEntryCount = maximumEntryCount
        }

    }

    private struct StoredResult: Codable {
        let videoID: String
        let canonicalArtist: String
        let canonicalTitle: String
        let youtubeTitle: String
        let channel: String
        let thumbnailURL: URL?
        let duration: TimeInterval?
        let source: YouTubeResolutionKnowledgeSource?
        let resolvedAt: Date
        var lastAccessedAt: Date
        var lastValidatedAt: Date?

        var searchResult: YouTubeSearchResult {
            YouTubeSearchResult(
                youtubeVideoID: videoID,
                title: youtubeTitle,
                channelTitle: channel,
                thumbnailURL: thumbnailURL,
                duration: duration
            )
        }

        private enum CodingKeys: String, CodingKey {
            case videoID
            case canonicalArtist
            case canonicalTitle
            case youtubeTitle
            case channel
            case thumbnailURL
            case duration
            case source
            case resolvedAt
            case lastAccessedAt
            case lastValidatedAt
        }

        init(
            videoID: String,
            canonicalArtist: String,
            canonicalTitle: String,
            youtubeTitle: String,
            channel: String,
            thumbnailURL: URL?,
            duration: TimeInterval?,
            source: YouTubeResolutionKnowledgeSource,
            resolvedAt: Date,
            lastAccessedAt: Date,
            lastValidatedAt: Date?
        ) {
            self.videoID = videoID
            self.canonicalArtist = canonicalArtist
            self.canonicalTitle = canonicalTitle
            self.youtubeTitle = youtubeTitle
            self.channel = channel
            self.thumbnailURL = thumbnailURL
            self.duration = duration
            self.source = source
            self.resolvedAt = resolvedAt
            self.lastAccessedAt = lastAccessedAt
            self.lastValidatedAt = lastValidatedAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            videoID = try values.decode(String.self, forKey: .videoID)
            canonicalArtist = try values.decode(String.self, forKey: .canonicalArtist)
            canonicalTitle = try values.decode(String.self, forKey: .canonicalTitle)
            youtubeTitle = try values.decode(String.self, forKey: .youtubeTitle)
            channel = try values.decode(String.self, forKey: .channel)
            thumbnailURL = try values.decodeIfPresent(URL.self, forKey: .thumbnailURL)
            duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration)
            source = try values.decodeIfPresent(
                YouTubeResolutionKnowledgeSource.self,
                forKey: .source
            )
            resolvedAt = try values.decode(Date.self, forKey: .resolvedAt)
            lastAccessedAt = try values.decode(Date.self, forKey: .lastAccessedAt)
            lastValidatedAt = try values.decodeIfPresent(Date.self, forKey: .lastValidatedAt)
        }
    }

    private let fileURL: URL
    private let legacyFileURL: URL?
    private let policy: Policy
    private var entries: [String: StoredResult] = [:]
    private var hasLoaded = false

    init(fileURL: URL? = nil, policy: Policy = .standard) {
        self.policy = policy
        if let fileURL {
            self.fileURL = fileURL
            legacyFileURL = nil
        } else {
            let fileManager = FileManager.default
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.fileURL = applicationSupport
                .appendingPathComponent("Shaudi", isDirectory: true)
                .appendingPathComponent("youtube-resolution-cache.json")
            let cachesDirectory = fileManager.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            legacyFileURL = cachesDirectory
                .appendingPathComponent("Shaudi", isDirectory: true)
                .appendingPathComponent("youtube-resolution-cache.json")
        }
    }

    func result(for identity: SongIdentity, now: Date = .now) async -> YouTubeSearchResult? {
        loadIfNeeded()
        let key = identity.cacheKey
        guard var entry = entries[key] else {
            return nil
        }
        entry.lastAccessedAt = now
        entries[key] = entry
        return entry.searchResult
    }

    func learnedIdentity(forVideoID videoID: String) async -> SongIdentity? {
        loadIfNeeded()
        let normalizedVideoID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedVideoID.isEmpty else { return nil }
        let matches = entries.values
            .filter { $0.videoID == normalizedVideoID }
            .sorted { lhs, rhs in
                let lhsPriority = Self.knowledgePriority(lhs.source)
                let rhsPriority = Self.knowledgePriority(rhs.source)
                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }
                let lhsIdentity = SongIdentity(
                    artist: lhs.canonicalArtist,
                    title: lhs.canonicalTitle
                )
                let rhsIdentity = SongIdentity(
                    artist: rhs.canonicalArtist,
                    title: rhs.canonicalTitle
                )
                return lhsIdentity.cacheKey < rhsIdentity.cacheKey
            }
        guard let best = matches.first else {
            return nil
        }
        return SongIdentity(artist: best.canonicalArtist, title: best.canonicalTitle)
    }

    func peek(for identity: SongIdentity, now: Date = .now) async -> YouTubeSearchResult? {
        loadIfNeeded()
        return entries[identity.cacheKey]?.searchResult
    }

    @discardableResult
    func learn(
        _ identity: SongIdentity,
        videoID: String,
        metadata: YouTubeResolutionMetadata,
        source: YouTubeResolutionKnowledgeSource,
        now: Date = .now
    ) async -> Bool {
        loadIfNeeded()
        let normalizedVideoID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            Self.isValidVideoID(normalizedVideoID),
            !identity.artist.isEmpty,
            !identity.title.isEmpty
        else {
            return false
        }

        let existing = entries[identity.cacheKey]
        entries[identity.cacheKey] = StoredResult(
            videoID: normalizedVideoID,
            canonicalArtist: identity.artist,
            canonicalTitle: identity.title,
            youtubeTitle: Self.nonempty(metadata.title)
                ?? existing?.youtubeTitle
                ?? identity.title,
            channel: Self.nonempty(metadata.channel)
                ?? existing?.channel
                ?? identity.artist,
            thumbnailURL: metadata.thumbnailURL ?? existing?.thumbnailURL,
            duration: metadata.duration ?? existing?.duration,
            source: source,
            resolvedAt: existing?.resolvedAt ?? now,
            lastAccessedAt: now,
            lastValidatedAt: now
        )
        evictOverflowIfNeeded()
        persist()
#if DEBUG
        print("[IDResolver] cached=true source=\(source.rawValue)")
#endif
        return true
    }

    func store(
        _ result: YouTubeSearchResult,
        for identity: SongIdentity,
        now: Date = .now
    ) async {
        await learn(
            identity,
            videoID: result.youtubeVideoID,
            metadata: YouTubeResolutionMetadata(result),
            source: .legacy,
            now: now
        )
    }

    func remove(_ identity: SongIdentity) async {
        loadIfNeeded()
        guard entries.removeValue(forKey: identity.cacheKey) != nil else {
            return
        }
        persist()
    }

    func entryCount() async -> Int {
        loadIfNeeded()
        return entries.count
    }

    private func loadIfNeeded() {
        guard !hasLoaded else {
            return
        }
        hasLoaded = true
        let sourceURL: URL
        let migratedLegacyFile: Bool
        if FileManager.default.fileExists(atPath: fileURL.path) {
            sourceURL = fileURL
            migratedLegacyFile = false
        } else if let legacyFileURL,
                  FileManager.default.fileExists(atPath: legacyFileURL.path) {
            sourceURL = legacyFileURL
            migratedLegacyFile = true
        } else {
            return
        }
        guard
            let data = try? Data(contentsOf: sourceURL),
            let decoded = try? JSONDecoder().decode([String: StoredResult].self, from: data)
        else {
            return
        }
        entries = decoded
        evictOverflowIfNeeded()
        if migratedLegacyFile {
            persist()
        }
    }

    private func evictOverflowIfNeeded() {
        let overflow = entries.count - max(0, policy.maximumEntryCount)
        guard overflow > 0 else {
            return
        }
        for key in entries.sorted(by: {
            $0.value.lastAccessedAt < $1.value.lastAccessedAt
        }).prefix(overflow).map(\.key) {
            entries[key] = nil
        }
    }

    private func persist() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
#if DEBUG
            print("[YouTubeResolutionCache] persistence failed=\(error.localizedDescription)")
#endif
        }
    }

    private static func isValidVideoID(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9_-]{11}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func knowledgePriority(
        _ source: YouTubeResolutionKnowledgeSource?
    ) -> Int {
        switch source {
        case .lastFMRecommendation: 6
        case .structured, .officialAPI: 5
        case .library, .playlist, .pastedURL: 4
        case .manualSearch: 3
        case .legacy, .none: 1
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

@MainActor
enum YouTubeResolutionKnowledgeTeacher {
    @discardableResult
    static func learnIfConfident(
        videoID: String,
        rawTitle: String,
        displayedArtist: String?,
        sourceChannel: String?,
        userArtistOverride: String?,
        metadata: YouTubeResolutionMetadata,
        source: YouTubeResolutionKnowledgeSource,
        searchQuery: String? = nil,
        cache suppliedCache: (any YouTubeResolutionCaching)? = nil
    ) async -> Bool {
        let cache = suppliedCache ?? PersistentYouTubeResolutionCache.shared
        let seed = RecommendationSeed(
            youtubeVideoID: videoID,
            rawTitle: rawTitle,
            displayedArtist: displayedArtist,
            sourceChannel: sourceChannel,
            userArtistOverride: userArtistOverride,
            searchQuery: searchQuery
        )
        guard let identity = seed.confidentSongIdentityForCaching else {
            return false
        }
        if let learned = await cache.learnedIdentity(forVideoID: videoID), learned != identity {
#if DEBUG
            print("[IDResolver] cached=false reason=trustedIdentityConflict")
#endif
            return false
        }
        return await cache.learn(
            identity,
            videoID: videoID,
            metadata: metadata,
            source: source,
            now: .now
        )
    }

    @discardableResult
    static func learnAuthoritative(
        identity: SongIdentity,
        videoID: String,
        metadata: YouTubeResolutionMetadata,
        source: YouTubeResolutionKnowledgeSource,
        cache suppliedCache: (any YouTubeResolutionCaching)? = nil
    ) async -> Bool {
        let cache = suppliedCache ?? PersistentYouTubeResolutionCache.shared
        return await cache.learn(
            identity,
            videoID: videoID,
            metadata: metadata,
            source: source,
            now: .now
        )
    }
}
