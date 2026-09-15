import Foundation
import SwiftData

enum ListeningHistoryPlaybackSource: String, CaseIterable {
    case library
    case playlist
    case search
    case recommendations

    init(_ origin: PlaybackOrigin) {
        switch origin {
        case .library:
            self = .library
        case .playlist:
            self = .playlist
        case .search:
            self = .search
        case .recommendations:
            self = .recommendations
        }
    }
}

@Model
final class ListeningHistoryEntry {
    @Attribute(.unique) var id: UUID
    var youtubeVideoID: String
    var canonicalArtist: String
    var canonicalTitle: String
    var canonicalIdentityKey: String
    var artworkURL: URL?
    var playbackSourceRawValue: String
    var startedAt: Date
    var endedAt: Date?
    var lastUpdatedAt: Date
    var listenedDuration: TimeInterval
    var confirmedPlay: Bool
    var genreTagsStorage: String

    init(
        id: UUID = UUID(),
        youtubeVideoID: String,
        canonicalArtist: String,
        canonicalTitle: String,
        canonicalIdentityKey: String,
        artworkURL: URL? = nil,
        playbackSourceRawValue: String,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        lastUpdatedAt: Date? = nil,
        listenedDuration: TimeInterval = 0,
        confirmedPlay: Bool = true,
        genreTagsStorage: String = ""
    ) {
        self.id = id
        self.youtubeVideoID = youtubeVideoID
        self.canonicalArtist = canonicalArtist
        self.canonicalTitle = canonicalTitle
        self.canonicalIdentityKey = canonicalIdentityKey
        self.artworkURL = artworkURL
        self.playbackSourceRawValue = playbackSourceRawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastUpdatedAt = lastUpdatedAt ?? startedAt
        self.listenedDuration = listenedDuration
        self.confirmedPlay = confirmedPlay
        self.genreTagsStorage = genreTagsStorage
    }

    var playbackSource: ListeningHistoryPlaybackSource? {
        ListeningHistoryPlaybackSource(rawValue: playbackSourceRawValue)
    }

    var cachedGenreTags: [String] {
        genreTagsStorage.split(separator: "|").map(String.init)
    }
}

struct ListeningHistorySnapshot: Equatable {
    let youtubeVideoID: String
    let canonicalArtist: String
    let canonicalTitle: String
    let canonicalIdentityKey: String
    let artworkURL: URL?
    let playbackSourceRawValue: String
    let genreTagsStorage: String

    init(
        youtubeVideoID: String,
        identity: SongIdentity,
        artworkURL: URL?,
        source: ListeningHistoryPlaybackSource,
        genres: [String] = []
    ) {
        self.youtubeVideoID = youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        canonicalArtist = identity.artist
        canonicalTitle = identity.title
        canonicalIdentityKey = identity.cacheKey
        self.artworkURL = artworkURL
        playbackSourceRawValue = source.rawValue
        genreTagsStorage = genres.joined(separator: "|")
    }
}

enum ListeningHistoryPolicy {
    static let checkpointInterval: TimeInterval = 30
    static let fullHistoryBatchSize = 100
}

@MainActor
final class ListeningHistoryRecorder {
    private struct ActiveEvent {
        let requestID: UUID
        let entry: ListeningHistoryEntry
        var segmentStartedAtMediaTime: TimeInterval?
    }

    private let modelContext: ModelContext
    private var activeEvent: ActiveEvent?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    func confirmPlayback(
        requestID: UUID,
        snapshot: ListeningHistorySnapshot,
        mediaTime: TimeInterval,
        now: Date = .now
    ) -> ListeningHistoryEntry? {
        guard mediaTime.isFinite, mediaTime >= 0 else {
            return nil
        }
        if activeEvent?.requestID == requestID {
            beginSegment(requestID: requestID, mediaTime: mediaTime)
            return activeEvent?.entry
        }

        finalize(now: now)
        let entry = ListeningHistoryEntry(
            youtubeVideoID: snapshot.youtubeVideoID,
            canonicalArtist: snapshot.canonicalArtist,
            canonicalTitle: snapshot.canonicalTitle,
            canonicalIdentityKey: snapshot.canonicalIdentityKey,
            artworkURL: snapshot.artworkURL,
            playbackSourceRawValue: snapshot.playbackSourceRawValue,
            startedAt: now,
            genreTagsStorage: snapshot.genreTagsStorage
        )
        modelContext.insert(entry)
        activeEvent = ActiveEvent(
            requestID: requestID,
            entry: entry,
            segmentStartedAtMediaTime: mediaTime
        )
        save()
        return entry
    }

    func beginSegment(requestID: UUID, mediaTime: TimeInterval) {
        guard
            mediaTime.isFinite,
            mediaTime >= 0,
            var event = activeEvent,
            event.requestID == requestID,
            event.segmentStartedAtMediaTime == nil
        else {
            return
        }
        event.segmentStartedAtMediaTime = mediaTime
        activeEvent = event
    }

    func closeSegment(requestID: UUID, mediaTime: TimeInterval, now: Date = .now) {
        guard
            var event = activeEvent,
            event.requestID == requestID,
            let segmentStart = event.segmentStartedAtMediaTime
        else {
            return
        }
        event.segmentStartedAtMediaTime = nil
        activeEvent = event
        guard mediaTime.isFinite, mediaTime >= segmentStart else {
            return
        }
        event.entry.listenedDuration += mediaTime - segmentStart
        event.entry.lastUpdatedAt = now
        save()
    }

    func checkpoint(requestID: UUID, mediaTime: TimeInterval, now: Date = .now) {
        guard
            let event = activeEvent,
            event.requestID == requestID,
            event.segmentStartedAtMediaTime != nil
        else {
            return
        }
        closeSegment(requestID: requestID, mediaTime: mediaTime, now: now)
        beginSegment(requestID: requestID, mediaTime: mediaTime)
    }

    func finalize(requestID: UUID? = nil, mediaTime: TimeInterval? = nil, now: Date = .now) {
        guard let event = activeEvent else {
            return
        }
        if let requestID, event.requestID != requestID {
            return
        }
        if let mediaTime {
            closeSegment(requestID: event.requestID, mediaTime: mediaTime, now: now)
        }
        event.entry.endedAt = now
        event.entry.lastUpdatedAt = now
        activeEvent = nil
        save()
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
#if DEBUG
            print("[ListeningHistory] save failed: \(error.localizedDescription)")
#endif
        }
    }
}

enum ListeningHistoryStats {
    static func recentDescriptor(limit: Int) -> FetchDescriptor<ListeningHistoryEntry> {
        var descriptor = FetchDescriptor<ListeningHistoryEntry>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return descriptor
    }

    static func identity(for entry: ListeningHistoryEntry) -> SongIdentity {
        SongIdentity(artist: entry.canonicalArtist, title: entry.canonicalTitle)
    }
}
