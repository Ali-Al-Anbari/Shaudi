//
//  YouTubeResolutionCache.swift
//  Shaudi
//

import Foundation

@MainActor
protocol YouTubeResolutionCaching {
    func result(for identity: SongIdentity, now: Date) async -> YouTubeSearchResult?
    func store(
        _ result: YouTubeSearchResult,
        for identity: SongIdentity,
        now: Date
    ) async
    func remove(_ identity: SongIdentity) async
}

@MainActor
final class PersistentYouTubeResolutionCache: YouTubeResolutionCaching {
    static let shared = PersistentYouTubeResolutionCache()

    struct Policy {
        let timeToLive: TimeInterval
        let maximumEntryCount: Int

        nonisolated static let standard = Policy(
            timeToLive: 30 * 24 * 60 * 60,
            maximumEntryCount: 500
        )
    }

    private struct StoredResult: Codable {
        let videoID: String
        let canonicalArtist: String
        let canonicalTitle: String
        let youtubeTitle: String
        let channel: String
        let thumbnailURL: URL?
        let resolvedAt: Date
        var lastAccessedAt: Date

        var searchResult: YouTubeSearchResult {
            YouTubeSearchResult(
                youtubeVideoID: videoID,
                title: youtubeTitle,
                channelTitle: channel,
                thumbnailURL: thumbnailURL
            )
        }
    }

    private let fileURL: URL
    private let policy: Policy
    private var entries: [String: StoredResult] = [:]
    private var hasLoaded = false

    init(fileURL: URL? = nil, policy: Policy = .standard) {
        self.policy = policy
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let cachesDirectory = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = cachesDirectory
                .appendingPathComponent("Shaudi", isDirectory: true)
                .appendingPathComponent("youtube-resolution-cache.json")
        }
    }

    func result(for identity: SongIdentity, now: Date = .now) async -> YouTubeSearchResult? {
        loadIfNeeded(now: now)
        let key = identity.cacheKey
        guard var entry = entries[key] else {
            return nil
        }
        guard now.timeIntervalSince(entry.resolvedAt) <= policy.timeToLive else {
            entries[key] = nil
            persist()
            return nil
        }
        entry.lastAccessedAt = now
        entries[key] = entry
        persist()
        return entry.searchResult
    }

    func store(
        _ result: YouTubeSearchResult,
        for identity: SongIdentity,
        now: Date = .now
    ) async {
        loadIfNeeded(now: now)
        entries[identity.cacheKey] = StoredResult(
            videoID: result.youtubeVideoID,
            canonicalArtist: identity.artist,
            canonicalTitle: identity.title,
            youtubeTitle: result.title,
            channel: result.channelTitle,
            thumbnailURL: result.thumbnailURL,
            resolvedAt: now,
            lastAccessedAt: now
        )
        evictOverflowIfNeeded()
        persist()
    }

    func remove(_ identity: SongIdentity) async {
        loadIfNeeded(now: .now)
        guard entries.removeValue(forKey: identity.cacheKey) != nil else {
            return
        }
        persist()
    }

    private func loadIfNeeded(now: Date) {
        guard !hasLoaded else {
            return
        }
        hasLoaded = true
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: StoredResult].self, from: data)
        else {
            return
        }
        entries = decoded.filter {
            now.timeIntervalSince($0.value.resolvedAt) <= policy.timeToLive
        }
        evictOverflowIfNeeded()
    }

    private func evictOverflowIfNeeded() {
        let overflow = entries.count - policy.maximumEntryCount
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
}
