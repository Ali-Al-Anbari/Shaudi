//
//  PlaybackManager.swift
//  Shaudi
//

import AVFoundation
import Combine
import Foundation
import SwiftData
#if os(iOS)
import MediaPlayer
import UIKit
#endif
import YouTubeKit

enum PlaybackOrigin: Equatable {
    case playlist(PersistentIdentifier)
    case library
    case search
    case recommendations
}

enum RecommendationSessionValidity {
    static func accepts(
        expectedToken: UUID,
        activeToken: UUID?,
        origin: PlaybackOrigin?
    ) -> Bool {
        guard expectedToken == activeToken else {
            return false
        }
        return origin == .search || origin == .recommendations
    }
}

private final class WeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

struct PlayableTrack: Identifiable, Hashable {
    let youtubeVideoID: String
    let title: String
    let channelTitle: String?
    let thumbnailURL: URL?
    let duration: TimeInterval?
    let playbackStartTime: TimeInterval?
    let playbackEndTime: TimeInterval?

    var id: String {
        youtubeVideoID
    }

    init(
        youtubeVideoID: String,
        title: String,
        channelTitle: String?,
        thumbnailURL: URL?,
        duration: TimeInterval?,
        playbackStartTime: TimeInterval? = nil,
        playbackEndTime: TimeInterval? = nil
    ) {
        self.youtubeVideoID = youtubeVideoID
        self.title = MusicMetadataText.decoded(title)
        self.channelTitle = channelTitle.map(MusicMetadataText.decoded)
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.playbackStartTime = playbackStartTime
        self.playbackEndTime = playbackEndTime
    }

    init(track: Track) {
        self.init(
            youtubeVideoID: track.youtubeVideoID,
            title: track.displayTitle,
            channelTitle: track.displayArtist,
            thumbnailURL: track.thumbnailURL,
            duration: track.duration,
            playbackStartTime: track.playbackStartTime,
            playbackEndTime: track.playbackEndTime
        )
    }
}

@MainActor
final class PlaybackManager: ObservableObject {
    private let streamLookaheadCount = 10
    private let recommendationUpcomingLimit = RecommendationRadioPolicy.upcomingQueueLimit
    private let recommendationHistoryLimit = RecommendationRadioPolicy.historyQueueLimit
    private let recommendationUpcomingWatermark = RecommendationRadioPolicy.targetUpcomingCount
    private let recommendationService = RecommendationService()
    private let metadataClient = YouTubeMetadataClient()
    private let genreTagService = LastFMRecommendationService()
    private let genreLookupCoordinator = GenreLookupCoordinator()

    enum PlaybackState {
        case idle
        case resolving
        case loading
        case playing
        case paused
        case failed(String)
    }

    enum RepeatMode: String {
        case off
        case playlist
        case one
    }

    private enum QueueTrackIdentity: Hashable {
        case videoID(String)
        case object(ObjectIdentifier)
    }

    struct StartupMetrics {
        let videoID: String
        var streamSource: String
        var streamResolutionTime: TimeInterval? = nil
        var playerStartTime: TimeInterval? = nil
        var totalStartTime: TimeInterval? = nil
    }

    struct PlaybackStartEvent: Equatable {
        let id: UUID
        let origin: PlaybackOrigin
        let trackID: String
    }

    struct DashboardWarmupCandidate: Equatable {
        let playlistID: PersistentIdentifier
        let videoID: String
    }

    private enum StreamResolutionError: Error {
        case noPlayableStream
    }

    private enum StreamResolutionSource: String {
        case foreground = "normal foreground extraction"
        case preResolution = "pre-resolution"
        case lookahead = "lookahead"
        case dashboardWarmup = "dashboard warmup"
        case playlistWarmup = "playlist warmup"
        case searchPreResolve = "Search pre-resolution"
        case memoryCache = "in-memory cache"
    }

    private struct StreamDiagnostics {
        let fileExtension: String
        let audioBitrate: Int?
    }

    private struct InFlightResolution {
        let id: UUID
        let task: Task<URL, Error>
    }

    private struct EffectivePlaybackRange {
        let startTime: TimeInterval
        let endTime: TimeInterval?
    }

    // The auxiliary player drives loading/preroll and becomes the current player on handoff.
    private struct PreparedNextPlayback {
        let preparationID: UUID
        let queueIndex: Int
        let track: Track
        let videoID: String
        let streamURL: URL
        let item: AVPlayerItem
        let player: AVPlayer
        let playbackRange: EffectivePlaybackRange
        let preparationStartedAt: TimeInterval
        var readyAt: TimeInterval?
    }

    private struct ActiveListeningPeriod {
        let requestID: UUID
        let track: Track?
        let player: AVPlayer
        let startedAt: TimeInterval
    }

    private struct SuspendedPlaybackContext {
        let currentTrack: Track?
        let currentPlayableTrack: PlayableTrack?
    }

    @Published private(set) var currentTrack: Track?
    @Published private(set) var currentPlayableTrack: PlayableTrack?
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var startupMetrics: StartupMetrics?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var playbackStartEvent: PlaybackStartEvent?
    @Published private(set) var isShuffleEnabled = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var isTrimPreviewActive = false
    @Published private(set) var trimPreviewTime: TimeInterval?

    /// Number of upcoming tracks (starting at currentIndex + 1) that were
    /// added via "Play Next" or "Add to Queue".  When this count is > 0 those
    /// items sit at the front of the upcoming section; automatic playlist /
    /// radio items follow them.
    private(set) var manualQueueCount: Int = 0

    private var player: AVPlayer?
    private var playbackTask: Task<Void, Never>?
    private var preResolutionTask: Task<Void, Never>?
    private var lookaheadTask: Task<Void, Never>?
    private var dashboardWarmupTask: Task<Void, Never>?
    private var playlistWarmupTask: Task<Void, Never>?
    private var nextItemPrerollTask: Task<Void, Never>?
    private var recommendationTasks: [String: Task<Void, Never>] = [:]
    private var recommendationRefillTask: Task<Void, Never>?
    private var recommendationRefillID: UUID?
    private var recommendationMetadataTasks: [String: Task<Void, Never>] = [:]
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var nextItemStatusObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackBoundaryObserver: Any?
    private var trimPreviewTimeObserver: (player: AVPlayer, token: Any)?
    private var listeningCheckpointObserver: (player: AVPlayer, token: Any)?
    private var activeRequestID: UUID?
    private var lastReportedPlaybackRequestID: UUID?
    private var playbackOrigin: PlaybackOrigin?
    private var playlistQueueInNormalOrder: [Track] = []
    private var shuffledPlaylistID: PersistentIdentifier?
    private var shuffledPlaylistOrder: [Track] = []
    private var activePreResolutionID: UUID?
    private var activeLookaheadID: UUID?
    private var lastRecordedTrackPlaybackRequestID: UUID?
    private var activeListeningPeriod: ActiveListeningPeriod?
    private var listeningHistoryRecorder: ListeningHistoryRecorder?
    private var preparedNextVideoID: String?
    private var preparedNextPlayback: PreparedNextPlayback?
    private var trimPreviewRange: (track: Track, range: EffectivePlaybackRange)?
    private var pendingTrimPreviewStartTime: (track: Track, time: TimeInterval)?
    private var suspendedPlaybackContext: SuspendedPlaybackContext?
    private var recommendationSessionID: UUID?
    private var recommendationSeenVideoIDs: Set<String> = []
    private var recommendationSeenVideoIDOrder: [String] = []
    private var recommendationSeenSongIdentities: Set<RecommendationSongIdentity> = []
    private var recommendationTransportMetadata: [String: RecommendationTransportMetadata] = [:]
    private var recommendationManualSeeds: [String: RecommendationSeed] = [:]
    private var recommendationRadioSession: RecommendationRadioSession?
    private var recommendationMetadataRequestedIDs: Set<String> = []
    private var resolvedStreamCache: [String: URL] = [:]
    private var resolvedStreamDiagnostics: [String: StreamDiagnostics] = [:]
    private var inFlightResolutions: [String: InFlightResolution] = [:]
    private var nonSpeculativeStreamIDs: Set<String> = []
    private var dashboardSpeculativeStreamIDs: Set<String> = []
    private var playlistSpeculativeStreamIDs: Set<String> = []
    private var searchSpeculativeStreamIDs: Set<String> = []
    private var activeDashboardWarmupID: UUID?
    private var activeDashboardResolutionVideoID: String?
    private var activePlaylistWarmupID: UUID?
    private var activePlaylistResolutionVideoID: String?
    private var searchPreResolutionTask: Task<Void, Never>?
    private var activeSearchPreResolutionID: UUID?
    private var activeSearchResolutionVideoID: String?
#if os(iOS)
    private var remoteCommandTargets: [Any] = []
    private var artworkTask: Task<Void, Never>?
    private var cachedArtworkURL: URL?
    private var cachedArtwork: MPMediaItemArtwork?
#endif

    init() {
#if os(iOS)
        configureRemoteCommands()
#endif
    }

    func configureListeningHistory(modelContext: ModelContext) {
        guard listeningHistoryRecorder == nil else {
            return
        }
        listeningHistoryRecorder = ListeningHistoryRecorder(modelContext: modelContext)
    }

    var hasPreviousTrack: Bool {
        guard let currentIndex else {
            return false
        }

        return previousQueueIndex(before: currentIndex) != nil
    }

    var hasNextTrack: Bool {
        guard let currentIndex else {
            return false
        }

        return nextQueueIndex(after: currentIndex) != nil
    }

    // Read-only queue neighbors for transient Now Playing previews. These use the
    // same repeat-aware indexing as the actual transport actions and never mutate
    // playback state.
    var previousQueueTrack: Track? {
        guard
            let currentIndex,
            let previousIndex = previousQueueIndex(before: currentIndex)
        else {
            return nil
        }

        return queue[previousIndex]
    }

    var nextQueueTrack: Track? {
        guard
            let currentIndex,
            let nextIndex = nextQueueIndex(after: currentIndex)
        else {
            return nil
        }

        return queue[nextIndex]
    }

    func play(
        _ track: Track,
        in orderedQueue: [Track],
        origin: PlaybackOrigin
    ) {
        endActiveTrimPreviewIfNeeded()

        if origin != .recommendations {
            endRecommendationSession(
                reason: playlistID(from: origin) == nil
                    ? "manual playback"
                    : "playlist playback"
            )
        }

        let previousPlaylistID = playlistID(from: playbackOrigin)
        pauseSpeculativeWarmupsForPlayback(
            requestedVideoID: normalizedVideoID(track.youtubeVideoID)
        )
        cancelUpcomingPreResolutionObservation()
        playbackOrigin = origin

        if case .playlist = origin {
            playlistQueueInNormalOrder = uniquePlaylistQueue(
                orderedQueue,
                prioritizing: track
            )

            if isShuffleEnabled {
                let playlistID: PersistentIdentifier?
                if case let .playlist(originPlaylistID) = origin {
                    playlistID = originPlaylistID
                } else {
                    playlistID = nil
                }
                let stableOrder = playlistID.map {
                    effectivePlaylistOrder(
                        playlistQueueInNormalOrder,
                        playlistID: $0
                    )
                } ?? playlistQueueInNormalOrder
                queue = queueStartingWithSelectedTrack(track, in: stableOrder)
                shuffledPlaylistOrder = queue
                currentIndex = queue.startIndex
                queueLog("shuffled order rebuilt count=\(queue.count)")
            } else if let selectedIndex = playlistQueueInNormalOrder.firstIndex(
                where: { $0 === track }
            ) {
                queue = playlistQueueInNormalOrder
                currentIndex = selectedIndex
            } else {
                queue = [track]
                currentIndex = queue.startIndex
            }

            let newPlaylistVideoIDs = Set(queue.compactMap { track in
                let videoID = normalizedVideoID(track.youtubeVideoID)
                return videoID.isEmpty ? nil : videoID
            })

            if
                let previousPlaylistID,
                case let .playlist(newPlaylistID) = origin,
                previousPlaylistID != newPlaylistID
            {
                evictObsoleteSpeculativeEntries(
                    from: previousPlaylistID,
                    for: newPlaylistID,
                    retaining: newPlaylistVideoIDs
                )
            }
        } else {
            playlistQueueInNormalOrder = []
            if let selectedIndex = orderedQueue.firstIndex(where: { $0 === track }) {
                queue = orderedQueue
                currentIndex = selectedIndex
            } else {
                queue = [track]
                currentIndex = queue.startIndex
            }
        }

#if os(iOS)
        updateRemoteQueueCommands()
#endif
        manualQueueCount = 0
        startCurrentQueueTrack()
    }

    func play(_ track: Track) {
        play(track, in: [track], origin: .library)
    }

    func restartPlaylist(
        _ orderedQueue: [Track],
        playlistID: PersistentIdentifier
    ) {
        guard let firstPlayableTrack = orderedQueue.first(where: {
            !normalizedVideoID($0.youtubeVideoID).isEmpty
        }) else {
            return
        }

        let normalOrder = uniquePlaylistQueue(
            orderedQueue,
            prioritizing: firstPlayableTrack
        )

        if isShuffleEnabled {
            let freshShuffledOrder = normalOrder.shuffled()
            guard let firstShuffledPlayableTrack = freshShuffledOrder.first(where: {
                !normalizedVideoID($0.youtubeVideoID).isEmpty
            }) else {
                return
            }

            shuffledPlaylistID = playlistID
            shuffledPlaylistOrder = freshShuffledOrder
            play(
                firstShuffledPlayableTrack,
                in: normalOrder,
                origin: .playlist(playlistID)
            )
            return
        }

        play(firstPlayableTrack, in: normalOrder, origin: .playlist(playlistID))
    }

    func play(
        _ track: PlayableTrack,
        canonicalIdentity: SongIdentity? = nil,
        searchQuery: String? = nil
    ) {
        endActiveTrimPreviewIfNeeded()

        let manualSeed: RecommendationSeed
        if let canonicalIdentity {
            manualSeed = RecommendationSeed(
                youtubeVideoID: normalizedVideoID(track.youtubeVideoID),
                canonicalIdentity: canonicalIdentity,
                youtubeTitle: track.title,
                youtubeChannel: track.channelTitle ?? "",
                authoritativeSource: .learnedCache
            )
        } else {
            manualSeed = RecommendationSeed(
                youtubeVideoID: normalizedVideoID(track.youtubeVideoID),
                rawTitle: track.title,
                displayedArtist: track.channelTitle,
                sourceChannel: track.channelTitle,
                userArtistOverride: nil,
                searchQuery: searchQuery
            )
        }
        startRecommendationSession(anchor: manualSeed)
        recommendationManualSeeds[normalizedVideoID(track.youtubeVideoID)] = manualSeed

        pauseSpeculativeWarmupsForPlayback(
            requestedVideoID: normalizedVideoID(track.youtubeVideoID)
        )
        cancelUpcomingPreResolutionObservation()
        playbackOrigin = .search
        playlistQueueInNormalOrder = []
        queue = []
        currentIndex = nil
#if os(iOS)
        updateRemoteQueueCommands()
#endif
        let displayTrack = PlayableTrack(
            youtubeVideoID: track.youtubeVideoID,
            title: manualSeed.cleanedTitle,
            channelTitle: manualSeed.cleanedArtist,
            thumbnailURL: track.thumbnailURL,
            duration: track.duration,
            playbackStartTime: track.playbackStartTime,
            playbackEndTime: track.playbackEndTime
        )
        manualQueueCount = 0
        startPlaybackContext(displayTrack, persistentTrack: nil)
    }

    func prepareForManualSearchPlayback() {
        endRecommendationSession(reason: "new Search selection")
    }

    func preResolveSearchResults(_ results: [YouTubeSearchResult]) {
        let candidates = SearchPreResolutionPlan.candidates(from: results)
        let candidateVideoIDs = Set(candidates.map(\.videoID))

        guard !candidates.isEmpty else {
            replaceSearchPreResolution(with: [])
            return
        }

        if
            activeSearchPreResolutionID != nil,
            searchSpeculativeStreamIDs == candidateVideoIDs
        {
            return
        }

        replaceSearchPreResolution(with: candidateVideoIDs)

        let preResolutionID = UUID()
        activeSearchPreResolutionID = preResolutionID
        searchPreResolutionTask = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            defer {
                if activeSearchPreResolutionID == preResolutionID {
                    activeSearchPreResolutionID = nil
                    activeSearchResolutionVideoID = nil
                    searchPreResolutionTask = nil
                }
            }

            for candidate in candidates {
                guard
                    !Task.isCancelled,
                    activeSearchPreResolutionID == preResolutionID
                else {
                    return
                }

                let videoID = candidate.videoID
                if resolvedStreamCache[videoID] != nil {
                    searchPreResolveLog("cacheHit videoID=\(videoID)")
                    continue
                }

                activeSearchResolutionVideoID = videoID
                searchPreResolveLog("started videoID=\(videoID) rank=\(candidate.rank)")
                let task = resolutionTask(for: videoID, source: .searchPreResolve)

                do {
                    _ = try await task.value
                    try Task.checkCancellation()

                    guard activeSearchPreResolutionID == preResolutionID else {
                        return
                    }

                    let duration = candidate.duration.map {
                        String(format: "%.0f", $0)
                    } ?? "unknown"
                    searchPreResolveLog("completed videoID=\(videoID) duration=\(duration)")
                } catch is CancellationError {
                    guard activeSearchPreResolutionID == preResolutionID else {
                        return
                    }
                    searchPreResolveLog("cancelled videoID=\(videoID)")
                    return
                } catch {
                    guard activeSearchPreResolutionID == preResolutionID else {
                        return
                    }

                    searchPreResolveLog("failed videoID=\(videoID)")
                }

                if activeSearchPreResolutionID == preResolutionID {
                    activeSearchResolutionVideoID = nil
                }
            }
        }
    }

    func cancelSearchPreResolution() {
        replaceSearchPreResolution(with: [])
    }

    func promoteSearchPreResolution(for videoID: String) {
        let normalizedID = normalizedVideoID(videoID)
        guard !normalizedID.isEmpty else {
            return
        }

        markStreamAsNonSpeculative(normalizedID)
    }

    func warmDashboardPage(
        _ candidates: [DashboardWarmupCandidate],
        page: Int
    ) {
        let uniqueCandidates = deduplicatedDashboardCandidates(candidates)
        let candidateVideoIDs = Set(uniqueCandidates.map(\.videoID))

        releasePlaylistWarmup(forDashboardCandidates: candidateVideoIDs)
        replaceDashboardWarmup(with: candidateVideoIDs)

        dashboardLog("page=\(page) candidates=\(uniqueCandidates.count)")
        guard !uniqueCandidates.isEmpty else {
            return
        }

        let warmupID = UUID()
        activeDashboardWarmupID = warmupID
        dashboardWarmupTask = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            defer {
                if activeDashboardWarmupID == warmupID {
                    activeDashboardWarmupID = nil
                    activeDashboardResolutionVideoID = nil
                    dashboardWarmupTask = nil
                }
            }

            for candidate in uniqueCandidates {
                guard
                    !Task.isCancelled,
                    activeDashboardWarmupID == warmupID
                else {
                    return
                }

                let videoID = candidate.videoID
                if resolvedStreamCache[videoID] != nil {
                    dashboardLog("cache hit track=\(videoID)")
                    continue
                }

                activeDashboardResolutionVideoID = videoID
                dashboardLog(
                    "resolving track=\(videoID) playlist=\(candidate.playlistID)"
                )
                let task = resolutionTask(for: videoID, source: .dashboardWarmup)

                do {
                    _ = try await task.value
                    try Task.checkCancellation()

                    guard activeDashboardWarmupID == warmupID else {
                        return
                    }

                    dashboardLog("resolved track=\(videoID)")
                } catch is CancellationError {
                    return
                } catch {
                    guard activeDashboardWarmupID == warmupID else {
                        return
                    }

                    dashboardLog("failed track=\(videoID)")
                }

                if activeDashboardWarmupID == warmupID {
                    activeDashboardResolutionVideoID = nil
                }
            }
        }
    }

    func cancelDashboardWarmup() {
        cancelDashboardWarmupWork()
    }

    func warmPlaylist(
        _ orderedVideoIDs: [String],
        playlistID: PersistentIdentifier
    ) {
        let videoIDs = deduplicatedVideoIDs(orderedVideoIDs)
        let candidateVideoIDs = Set(videoIDs)

        replacePlaylistWarmup(with: candidateVideoIDs)
        releaseDashboardWarmup(forPlaylistCandidates: candidateVideoIDs)

        playlistLog("playlist=\(playlistID) candidates=\(videoIDs.count)")
        guard !videoIDs.isEmpty else {
            return
        }

        let warmupID = UUID()
        activePlaylistWarmupID = warmupID
        playlistWarmupTask = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            defer {
                if activePlaylistWarmupID == warmupID {
                    activePlaylistWarmupID = nil
                    activePlaylistResolutionVideoID = nil
                    playlistWarmupTask = nil
                }
            }

            for videoID in videoIDs {
                guard
                    !Task.isCancelled,
                    activePlaylistWarmupID == warmupID
                else {
                    return
                }

                if resolvedStreamCache[videoID] != nil {
                    playlistLog("cache hit track=\(videoID)")
                    continue
                }

                activePlaylistResolutionVideoID = videoID
                let joinedExistingResolution = inFlightResolutions[videoID] != nil
                if joinedExistingResolution {
                    playlistLog("joined in-flight track=\(videoID)")
                } else {
                    playlistLog("resolving track=\(videoID)")
                }

                let task = resolutionTask(for: videoID, source: .playlistWarmup)

                do {
                    _ = try await task.value
                    try Task.checkCancellation()

                    guard activePlaylistWarmupID == warmupID else {
                        return
                    }

                    playlistLog("resolved track=\(videoID)")
                } catch is CancellationError {
                    return
                } catch {
                    guard activePlaylistWarmupID == warmupID else {
                        return
                    }

                    playlistLog("failed track=\(videoID)")
                }

                if activePlaylistWarmupID == warmupID {
                    activePlaylistResolutionVideoID = nil
                }
            }
        }
    }

    func cancelPlaylistWarmup() {
        cancelPlaylistWarmupWork()
    }

    func effectivePlaylistOrder(
        _ normalOrder: [Track],
        playlistID: PersistentIdentifier
    ) -> [Track] {
        let uniqueNormalOrder = uniqueQueue(normalOrder)
        guard isShuffleEnabled else {
            return uniqueNormalOrder
        }

        let normalIdentities = Set(uniqueNormalOrder.map { queueIdentity(for: $0) })
        if shuffledPlaylistID == playlistID {
            let retainedOrder = shuffledPlaylistOrder.filter {
                normalIdentities.contains(queueIdentity(for: $0))
            }
            let retainedIdentities = Set(retainedOrder.map { queueIdentity(for: $0) })
            let additions = uniqueNormalOrder.filter {
                !retainedIdentities.contains(queueIdentity(for: $0))
            }
            shuffledPlaylistOrder = retainedOrder + additions.shuffled()
        } else {
            shuffledPlaylistID = playlistID
            shuffledPlaylistOrder = uniqueNormalOrder.shuffled()
            queueLog("shuffled order rebuilt count=\(shuffledPlaylistOrder.count)")
        }

        return shuffledPlaylistOrder
    }

    func hasActivePlaylistQueue(for playlistID: PersistentIdentifier) -> Bool {
        guard
            case let .playlist(activePlaylistID) = playbackOrigin,
            activePlaylistID == playlistID,
            let currentIndex,
            queue.indices.contains(currentIndex)
        else {
            return false
        }

        return currentPlayableTrack != nil
    }

    func nextTrack() {
        guard !isTrimPreviewActive else {
            return
        }

        advanceToNextTrack(reason: "Next")
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()

        guard
            case .playlist = playbackOrigin,
            let currentIndex,
            queue.indices.contains(currentIndex)
        else {
            shuffledPlaylistID = nil
            shuffledPlaylistOrder = []
            queueLog(isShuffleEnabled ? "shuffle enabled" : "shuffle disabled")
            return
        }

        let currentTrack = queue[currentIndex]
        if isShuffleEnabled {
            let history = Array(queue[queue.startIndex...currentIndex])
            let consumedIdentities = Set(history.map { queueIdentity(for: $0) })
            let remainingTracks = playlistQueueInNormalOrder.filter {
                !consumedIdentities.contains(queueIdentity(for: $0))
            }
            queue = history + remainingTracks.shuffled()
            self.currentIndex = history.count - 1
            if case let .playlist(playlistID) = playbackOrigin {
                shuffledPlaylistID = playlistID
                shuffledPlaylistOrder = queue
            }
            queueLog("shuffle enabled count=\(queue.count)")
            queueLog("shuffled order rebuilt")
        } else {
            queue = playlistQueueInNormalOrder
            if let restoredIndex = queue.firstIndex(where: { $0 === currentTrack })
                ?? queue.firstIndex(where: {
                    queueIdentity(for: $0) == queueIdentity(for: currentTrack)
                })
            {
                self.currentIndex = restoredIndex
            } else {
                queue.append(currentTrack)
                self.currentIndex = queue.count - 1
            }
            shuffledPlaylistID = nil
            shuffledPlaylistOrder = []
            queueLog("shuffle disabled")
        }

        refreshQueuePredictionsAfterMutation()
    }

    func toggleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .playlist
        case .playlist:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
        queueLog("repeatMode=\(repeatMode.rawValue)")

        guard case .playlist = playbackOrigin else {
            return
        }

        refreshQueuePredictionsAfterMutation()
    }

    // MARK: - User-manageable queue

    /// Insert `track` as the very next item after the currently playing track.
    func playNext(_ track: Track) {
        guard currentPlayableTrack != nil else {
            return
        }

        let insertionIndex: Int
        if let currentIndex, queue.indices.contains(currentIndex) {
            insertionIndex = currentIndex + 1
        } else {
            return
        }

        queue.insert(track, at: insertionIndex)
        manualQueueCount += 1
        queueLog("playNext count=\(manualQueueCount) total=\(queue.count)")
        refreshQueuePredictionsAfterMutation()
    }

    /// Append `track` to the end of the manual-queue section (before automatic items).
    func addToQueue(_ track: Track) {
        guard currentPlayableTrack != nil else {
            return
        }

        let insertionIndex: Int
        if let currentIndex, queue.indices.contains(currentIndex) {
            insertionIndex = currentIndex + 1 + manualQueueCount
        } else {
            return
        }

        // Clamp in case manualQueueCount is somehow stale
        let safeIndex = min(insertionIndex, queue.endIndex)
        queue.insert(track, at: safeIndex)
        manualQueueCount += 1
        queueLog("addToQueue count=\(manualQueueCount) total=\(queue.count)")
        refreshQueuePredictionsAfterMutation()
    }

    /// Build a transient Track from a PlayableTrack (for Search-result queue actions).
    func makeTransientTrack(from playableTrack: PlayableTrack) -> Track {
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: playableTrack.youtubeVideoID)]
        return Track(
            title: playableTrack.title,
            youtubeURL: components.url!,
            youtubeVideoID: playableTrack.youtubeVideoID,
            channelTitle: playableTrack.channelTitle,
            thumbnailURL: playableTrack.thumbnailURL,
            duration: playableTrack.duration,
            metadataLastRefreshed: .now,
            playbackStartTime: playableTrack.playbackStartTime,
            playbackEndTime: playableTrack.playbackEndTime
        )
    }

    /// Jump to an item in the upcoming queue by its index within the upcoming slice.
    /// `upcomingIndex` is 0-based relative to the track *after* the current one.
    func jumpToQueueItem(upcomingIndex: Int) {
        guard
            let currentIndex,
            queue.indices.contains(currentIndex)
        else {
            return
        }

        let absoluteIndex = currentIndex + 1 + upcomingIndex
        guard queue.indices.contains(absoluteIndex) else {
            return
        }

        // Tracks skipped over are not "consumed" as manual items — reset count
        // based on how many manual items remain ahead of the new position.
        let skipped = upcomingIndex
        manualQueueCount = max(0, manualQueueCount - skipped)

        let requestedAt = currentTime
        let track = queue[absoluteIndex]
        let videoID = track.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        log("Queue jump requested for \(videoID)")
        cancelUpcomingPreResolutionObservation()
        self.currentIndex = absoluteIndex
#if os(iOS)
        updateRemoteQueueCommands()
#endif
        startCurrentQueueTrack(requestStartedAt: requestedAt)
    }

    /// Remove an upcoming item by its 0-based index in the upcoming slice.
    func removeFromQueue(upcomingIndex: Int) {
        guard
            let currentIndex,
            queue.indices.contains(currentIndex)
        else {
            return
        }

        let absoluteIndex = currentIndex + 1 + upcomingIndex
        guard queue.indices.contains(absoluteIndex) else {
            return
        }

        queue.remove(at: absoluteIndex)
        if upcomingIndex < manualQueueCount {
            manualQueueCount = max(0, manualQueueCount - 1)
        }
        queueLog("removeFromQueue upcomingIndex=\(upcomingIndex) manualCount=\(manualQueueCount) total=\(queue.count)")
        refreshQueuePredictionsAfterMutation()
    }

    /// Reorder items within the upcoming queue. Indices are 0-based within the upcoming slice.
    func moveQueue(from source: IndexSet, to destination: Int) {
        guard
            let currentIndex,
            queue.indices.contains(currentIndex)
        else {
            return
        }

        guard currentIndex + 1 < queue.endIndex else {
            return
        }

        var upcomingSlice = Array(queue[(currentIndex + 1)...])

        guard destination >= 0, destination <= upcomingSlice.count else {
            return
        }

        let validSource = source.filter { upcomingSlice.indices.contains($0) }
        guard !validSource.isEmpty else {
            return
        }

        // Manual reorder: collect moved elements, remove them, then insert at destination.
        let movedElements = validSource.map { upcomingSlice[$0] }
        var remaining = upcomingSlice.indices
            .filter { !validSource.contains($0) }
            .map { upcomingSlice[$0] }

        // Adjust destination for removed elements before it
        let removedBeforeDestination = validSource.filter { $0 < destination }.count
        let insertAt = max(0, min(destination - removedBeforeDestination, remaining.count))
        remaining.insert(contentsOf: movedElements, at: insertAt)
        upcomingSlice = remaining

        queue = Array(queue[...currentIndex]) + upcomingSlice

        queueLog("moveQueue manualCount=\(manualQueueCount) total=\(queue.count)")
        refreshQueuePredictionsAfterMutation()
    }

    /// The tracks currently upcoming (everything after the current track).
    var upcomingQueueTracks: [Track] {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return []
        }
        let nextIdx = currentIndex + 1
        guard nextIdx < queue.endIndex else {
            return []
        }
        return Array(queue[nextIdx...])
    }

    func previousTrack() {
        guard !isTrimPreviewActive else {
            return
        }

        guard
            let currentIndex,
            let previousIndex = previousQueueIndex(before: currentIndex)
        else {
            return
        }

        let requestedAt = currentTime
        let videoID = queue[previousIndex].youtubeVideoID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        log("Previous requested for \(videoID)")
        cancelUpcomingPreResolutionObservation()
        self.currentIndex = previousIndex
#if os(iOS)
        updateRemoteQueueCommands()
#endif
        startCurrentQueueTrack(requestStartedAt: requestedAt)
    }

    private func advanceToNextTrack(reason: String) {
        guard
            let currentIndex,
            let nextIndex = nextQueueIndex(after: currentIndex)
        else {
            return
        }

        let requestedAt = currentTime
        let nextTrack = queue[nextIndex]
        let videoID = nextTrack.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        if nextIndex == queue.startIndex, currentIndex == queue.index(before: queue.endIndex) {
            queueLog("wrapped to start")
        }
        log("\(reason) advance requested for \(videoID)")

        let preparedPlayback = takePreparedNextPlayback(
            queueIndex: nextIndex,
            track: nextTrack,
            videoID: videoID
        )
        cancelUpcomingPreResolutionObservation()
        // If the track we're advancing into is the first upcoming item (no wrap),
        // it may be a manual-queue item — consume one manual slot.
        if nextIndex == currentIndex + 1, manualQueueCount > 0 {
            manualQueueCount -= 1
            queueLog("manualQueueCount consumed=1 remaining=\(manualQueueCount)")
        }
        self.currentIndex = nextIndex
#if os(iOS)
        updateRemoteQueueCommands()
#endif
        startCurrentQueueTrack(
            preparedPlayback: preparedPlayback,
            requestStartedAt: requestedAt
        )
    }

    private func nextQueueIndex(after index: Int) -> Int? {
        guard queue.indices.contains(index) else {
            return nil
        }

        let nextIndex = index + 1
        if queue.indices.contains(nextIndex) {
            return nextIndex
        }

        guard
            repeatMode == .playlist,
            case .playlist = playbackOrigin,
            !queue.isEmpty
        else {
            return nil
        }

        return queue.startIndex
    }

    private func previousQueueIndex(before index: Int) -> Int? {
        guard queue.indices.contains(index) else {
            return nil
        }

        if index > queue.startIndex {
            return index - 1
        }

        guard
            repeatMode == .playlist,
            case .playlist = playbackOrigin,
            !queue.isEmpty
        else {
            return nil
        }

        return queue.index(before: queue.endIndex)
    }

    private func upcomingQueueIndices(after index: Int, limit: Int) -> [Int] {
        guard limit > 0, queue.indices.contains(index) else {
            return []
        }

        var indices: [Int] = []
        var visitedIndices: Set<Int> = [index]
        var cursor = index

        while indices.count < limit {
            guard
                let nextIndex = nextQueueIndex(after: cursor),
                visitedIndices.insert(nextIndex).inserted
            else {
                break
            }

            indices.append(nextIndex)
            cursor = nextIndex
        }

        return indices
    }

    private func uniquePlaylistQueue(
        _ orderedQueue: [Track],
        prioritizing selectedTrack: Track
    ) -> [Track] {
        let selectedIdentity = queueIdentity(for: selectedTrack)
        var seenIdentities: Set<QueueTrackIdentity> = []
        var uniqueTracks: [Track] = []

        for track in orderedQueue {
            let identity = queueIdentity(for: track)
            guard seenIdentities.insert(identity).inserted else {
                continue
            }

            uniqueTracks.append(identity == selectedIdentity ? selectedTrack : track)
        }

        if seenIdentities.insert(selectedIdentity).inserted {
            uniqueTracks.append(selectedTrack)
        }

        return uniqueTracks
    }

    private func uniqueQueue(_ orderedQueue: [Track]) -> [Track] {
        var seenIdentities: Set<QueueTrackIdentity> = []
        return orderedQueue.filter {
            seenIdentities.insert(queueIdentity(for: $0)).inserted
        }
    }

    private func queueStartingWithSelectedTrack(
        _ selectedTrack: Track,
        in stableOrder: [Track]
    ) -> [Track] {
        let selectedIdentity = queueIdentity(for: selectedTrack)
        let remainingTracks = stableOrder.filter {
            queueIdentity(for: $0) != selectedIdentity
        }
        return [selectedTrack] + remainingTracks
    }

    private func queueIdentity(for track: Track) -> QueueTrackIdentity {
        let videoID = normalizedVideoID(track.youtubeVideoID)
        if !videoID.isEmpty {
            return .videoID(videoID)
        }

        return .object(ObjectIdentifier(track))
    }

    private func refreshQueuePredictionsAfterMutation() {
        cancelUpcomingPreResolutionObservation()
#if os(iOS)
        updateRemoteQueueCommands()
#endif

        guard repeatMode != .one else {
            return
        }

        switch state {
        case .playing, .paused, .loading:
            beginPreResolvingNextTrack()
        case .idle, .resolving, .failed:
            break
        }
    }

    private func startCurrentQueueTrack(
        preparedPlayback: PreparedNextPlayback? = nil,
        requestStartedAt: TimeInterval? = nil
    ) {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            stop()
            return
        }

        let track = queue[currentIndex]
        hydrateRecommendationMetadataIfNeeded(for: track)
        startPlaybackContext(
            PlayableTrack(track: track),
            persistentTrack: track,
            preparedPlayback: preparedPlayback,
            requestStartedAt: requestStartedAt
        )
    }

    private func startPlaybackContext(
        _ playableTrack: PlayableTrack,
        persistentTrack: Track?,
        preparedPlayback: PreparedNextPlayback? = nil,
        requestStartedAt: TimeInterval? = nil
    ) {
        invalidateCurrentRequest()
        clearPlayer()

        let requestID = UUID()
        let requestStartedAt = requestStartedAt ?? currentTime
        let videoID = playableTrack.youtubeVideoID
            .trimmingCharacters(in: .whitespacesAndNewlines)

        activeRequestID = requestID
        currentTrack = persistentTrack
        currentPlayableTrack = playableTrack
#if os(iOS)
        if !isTrimPreviewActive {
            publishNowPlaying(playableTrack, requestID: requestID)
        }
#endif

        guard !videoID.isEmpty else {
            if let preparedPlayback {
                discard(preparedPlayback)
            }
            startupMetrics = nil
            state = .failed("This legacy track does not have a YouTube video ID.")
#if os(iOS)
            clearNowPlaying()
#endif
            return
        }

        if
            let preparedPlayback,
            preparedPlayback.queueIndex == currentIndex,
            preparedPlayback.track === persistentTrack,
            preparedPlayback.videoID == videoID
        {
            let wasFullyPrepared = preparedPlayback.readyAt != nil
            startupMetrics = StartupMetrics(
                videoID: videoID,
                streamSource: wasFullyPrepared
                    ? "Prepared next item"
                    : "Cached URL, item preparation in progress"
            )
            state = .loading

            if wasFullyPrepared {
                log("Using prepared item for \(videoID)")
            } else {
                log("Using cached URL but unprepared item for \(videoID)")
            }

            startPlayback(
                with: preparedPlayback.item,
                player: preparedPlayback.player,
                videoID: videoID,
                requestID: requestID,
                requestStartedAt: requestStartedAt,
                playerPreparationStartedAt: requestStartedAt,
                usedCachedStream: true,
                playbackRange: preparedPlayback.playbackRange,
                playbackStartTime: preparedPlayback.playbackRange.startTime
            )
            return
        }

        if let preparedPlayback {
            discard(preparedPlayback)
        }

        if let cachedURL = resolvedStreamCache[videoID] {
            markStreamAsNonSpeculative(videoID)
            startupMetrics = StartupMetrics(
                videoID: videoID,
                streamSource: "In-memory cache"
            )
            state = .loading
            log("Cache hit for \(videoID); skipping YouTubeKit resolution")
            log("Using cached URL but unprepared item for \(videoID)")
            logSelectedStream(
                videoID: videoID,
                diagnostics: resolvedStreamDiagnostics[videoID],
                source: .memoryCache
            )
            startPlayback(
                with: cachedURL,
                videoID: videoID,
                requestID: requestID,
                requestStartedAt: requestStartedAt,
                playerPreparationStartedAt: currentTime,
                usedCachedStream: true
            )
        } else {
            let isJoiningInFlightResolution = inFlightResolutions[videoID] != nil
            startupMetrics = StartupMetrics(
                videoID: videoID,
                streamSource: isJoiningInFlightResolution
                    ? "In-flight pre-resolution"
                    : "Fresh YouTubeKit resolution"
            )
            if isJoiningInFlightResolution {
                log("Joining in-flight resolution for \(videoID)")
            } else {
                log("Using normal foreground extraction for \(videoID)")
            }
            resolveAndStartPlayback(
                videoID: videoID,
                requestID: requestID,
                requestStartedAt: requestStartedAt,
                isJoiningInFlightResolution: isJoiningInFlightResolution
            )
        }
    }

    func pause() {
        if isTrimPreviewActive {
            pauseActiveTrimPreview()
            return
        }

        guard case .playing = state else {
            return
        }

        finishActiveListeningPeriod()
        player?.pause()
        state = .paused
#if os(iOS)
        synchronizeNowPlayingPlaybackState()
#endif
    }

    var currentPlaybackTime: TimeInterval? {
        let time = player?.currentTime().seconds
        guard let time, time.isFinite, time >= 0 else {
            return nil
        }

        return time
    }

    var currentEffectivePlaybackDuration: TimeInterval? {
        let playbackRange = effectivePlaybackRange(for: currentPlayableTrack)
        guard let endTime = playbackRange.endTime else {
            return nil
        }

        return validDuration(endTime - playbackRange.startTime)
    }

    var currentPlaybackProgressTime: TimeInterval? {
        guard
            let currentPlaybackTime,
            let currentEffectivePlaybackDuration
        else {
            return nil
        }

        let playbackRange = effectivePlaybackRange(for: currentPlayableTrack)
        return min(
            max(0, currentPlaybackTime - playbackRange.startTime),
            currentEffectivePlaybackDuration
        )
    }

    func seek(toPlaybackProgressTime time: TimeInterval) {
        guard time.isFinite else {
            return
        }

        let playbackRange = effectivePlaybackRange(for: currentPlayableTrack)
        seek(to: playbackRange.startTime + time)
    }

    func beginTrimPreview(
        _ track: Track,
        startTime: TimeInterval,
        endTime: TimeInterval,
        previewTime: TimeInterval
    ) {
        guard let playbackRange = validatedPlaybackRange(
            startTime: startTime,
            endTime: endTime,
            authoritativeDuration: track.duration
        ) else {
            return
        }

        if isTrimPreviewActive {
            guard trimPreviewRange?.track === track else {
                return
            }

            updateTrimPreviewRange(
                for: track,
                startTime: startTime,
                endTime: endTime
            )
            seekTrimPreview(for: track, to: previewTime)
            resumeTrimPreview(for: track)
            return
        }

        let suspendedContext = SuspendedPlaybackContext(
            currentTrack: currentTrack,
            currentPlayableTrack: currentPlayableTrack
        )
        if case .playing = state {
            pause()
        } else {
            finishActiveListeningPeriod()
            player?.pause()
        }

        cancelUpcomingPreResolutionObservation()
        pauseSpeculativeWarmupsForPlayback(
            requestedVideoID: normalizedVideoID(track.youtubeVideoID)
        )

        suspendedPlaybackContext = suspendedContext
        isTrimPreviewActive = true
#if os(iOS)
        updateRemoteQueueCommands()
#endif
        trimPreviewRange = (track, playbackRange)
        let clampedPreviewTime = clampedPlaybackTime(previewTime, to: playbackRange)
        trimPreviewTime = clampedPreviewTime
        pendingTrimPreviewStartTime = (track, clampedPreviewTime)
        startPlaybackContext(
            PlayableTrack(track: track),
            persistentTrack: track
        )
    }

    func updateTrimPreviewRange(
        for track: Track,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        guard
            isTrimPreviewActive,
            trimPreviewRange?.track === track,
            let playbackRange = validatedPlaybackRange(
                startTime: startTime,
                endTime: endTime,
                authoritativeDuration: track.duration
            )
        else {
            return
        }

        trimPreviewRange = (track, playbackRange)
        updateActivePlaybackRange(playbackRange)
    }

    func endTrimPreview(for track: Track) {
        guard
            isTrimPreviewActive,
            trimPreviewRange?.track === track
        else {
            return
        }

        let suspendedContext = suspendedPlaybackContext
        invalidateCurrentRequest()
        clearPlayer()

        isTrimPreviewActive = false
        trimPreviewTime = nil
        trimPreviewRange = nil
        pendingTrimPreviewStartTime = nil
        suspendedPlaybackContext = nil
        startupMetrics = nil

        currentTrack = suspendedContext?.currentTrack
        if suspendedContext?.currentTrack === track {
            currentPlayableTrack = PlayableTrack(track: track)
        } else {
            currentPlayableTrack = suspendedContext?.currentPlayableTrack
        }
        state = currentPlayableTrack == nil ? .idle : .paused

#if os(iOS)
        updateRemoteQueueCommands()
        if currentPlayableTrack == nil {
            clearNowPlaying()
        } else {
            synchronizeNowPlayingPlaybackState()
        }
#endif

        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func isTrimPreviewing(_ track: Track) -> Bool {
        isTrimPreviewActive && trimPreviewRange?.track === track
    }

    func pauseTrimPreview(for track: Track) {
        guard isTrimPreviewing(track) else {
            return
        }

        pauseActiveTrimPreview()
    }

    func resumeTrimPreview(for track: Track) {
        guard
            isTrimPreviewing(track),
            case .paused = state,
            let player,
            let requestID = activeRequestID,
            let playbackRange = trimPreviewRange?.range
        else {
            return
        }

        state = .loading
        let currentTime = trimPreviewTime ?? player.currentTime().seconds
        if
            let endTime = playbackRange.endTime,
            currentTime.isFinite,
            currentTime >= endTime - 0.05
        {
            trimPreviewTime = playbackRange.startTime
            beginPlayback(
                player,
                at: playbackRange.startTime,
                requestID: requestID
            )
        } else {
            player.play()
        }
    }

    func seekTrimPreview(for track: Track, to time: TimeInterval) {
        guard
            time.isFinite,
            isTrimPreviewing(track),
            let player,
            let requestID = activeRequestID,
            let playbackRange = trimPreviewRange?.range
        else {
            return
        }

        let targetTime = clampedPlaybackTime(time, to: playbackRange)
        trimPreviewTime = targetTime

        Task { [weak self] in
            guard let self else {
                return
            }

            let finished = await seekPlayer(player, to: targetTime)
            guard
                finished,
                isActive(requestID),
                self.player === player,
                isTrimPreviewActive
            else {
                return
            }

            trimPreviewTime = targetTime
        }
    }

    func resume() {
        if isTrimPreviewActive {
            guard let track = trimPreviewRange?.track else {
                return
            }
            resumeTrimPreview(for: track)
            return
        }

        guard case .paused = state else {
            return
        }

        guard let player else {
            restartCurrentPlayback()
            return
        }

        state = .loading
        player.play()
#if os(iOS)
        synchronizeNowPlayingPlaybackState()
#endif
    }

    func seek(to time: TimeInterval) {
        guard
            time.isFinite,
            let player,
            let requestID = activeRequestID,
            let currentPlayableTrack
        else {
            return
        }

        let playbackRange = effectivePlaybackRange(for: currentPlayableTrack)
        let targetTime = clampedPlaybackTime(time, to: playbackRange)

        finishActiveListeningPeriod()

        Task { [weak self] in
            guard let self else {
                return
            }

            let finished = await seekPlayer(player, to: targetTime)
            guard
                finished,
                isActive(requestID),
                self.player === player
            else {
                return
            }

            if player.timeControlStatus == .playing {
                beginActiveListeningPeriod(for: player, requestID: requestID)
            }
#if os(iOS)
            synchronizeNowPlayingPlaybackState()
#endif
        }
    }

    func stop() {
        if isTrimPreviewActive {
            endActiveTrimPreviewIfNeeded()
            return
        }

        cancelUpcomingPreResolutionObservation()
        endRecommendationSession(reason: "playback stopped")
        invalidateCurrentRequest()
        clearPlayer()
        queue = []
        currentIndex = nil
        playlistQueueInNormalOrder = []
        currentTrack = nil
        currentPlayableTrack = nil
        playbackOrigin = nil
        manualQueueCount = 0
        state = .idle
#if os(iOS)
        updateRemoteQueueCommands()
        clearNowPlaying()
#endif

        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func isCurrentTrack(_ track: Track) -> Bool {
        currentTrack === track
    }

    func isCurrentPlayable(_ youtubeVideoID: String) -> Bool {
        currentPlayableTrack?.youtubeVideoID == youtubeVideoID
    }

    private func resolveAndStartPlayback(
        videoID: String,
        requestID: UUID,
        requestStartedAt: TimeInterval,
        isJoiningInFlightResolution: Bool = false
    ) {
        state = .resolving
        let resolutionStartedAt = currentTime
        let resolutionTask = resolutionTask(for: videoID, source: .foreground)

        playbackTask = Task { [weak self] in
            do {
                let streamURL = try await resolutionTask.value

                try Task.checkCancellation()

                guard let self, isActive(requestID) else {
                    return
                }

                let resolutionFinishedAt = currentTime
                let resolutionTime = resolutionFinishedAt - resolutionStartedAt

                updateMetrics { metrics in
                    metrics.streamResolutionTime = resolutionTime
                }
                logTiming("Stream resolution", seconds: resolutionTime, videoID: videoID)

                playbackTask = nil
                state = .loading
                if isJoiningInFlightResolution {
                    log("Using cached URL but unprepared item for \(videoID)")
                }
                startPlayback(
                    with: streamURL,
                    videoID: videoID,
                    requestID: requestID,
                    requestStartedAt: requestStartedAt,
                    playerPreparationStartedAt: resolutionFinishedAt,
                    usedCachedStream: isJoiningInFlightResolution
                )
            } catch is CancellationError {
                guard
                    let self,
                    isJoiningInFlightResolution,
                    isActive(requestID),
                    !Task.isCancelled
                else {
                    return
                }

                playbackTask = nil
                log("Joined resolution was cancelled for \(videoID); retrying foreground once")
                resolveAndStartPlayback(
                    videoID: videoID,
                    requestID: requestID,
                    requestStartedAt: requestStartedAt
                )
            } catch {
                guard let self, isActive(requestID), !Task.isCancelled else {
                    return
                }

                if isJoiningInFlightResolution {
                    playbackTask = nil
                    log("Joined resolution failed for \(videoID); retrying foreground once")
                    resolveAndStartPlayback(
                        videoID: videoID,
                        requestID: requestID,
                        requestStartedAt: requestStartedAt
                    )
                    return
                }

                playbackTask = nil
                if case StreamResolutionError.noPlayableStream = error {
                    invalidateVideoResolutionIfNeeded(videoID: videoID)
                    state = .failed(
                        "YouTube did not provide an audio-only stream this iPhone can play."
                    )
                } else {
                    if Self.provesVideoIsUnplayable(error) {
                        invalidateVideoResolutionIfNeeded(videoID: videoID)
                    }
                    state = .failed(
                        "YouTube stream extraction failed: \(Self.errorMessage(for: error))"
                    )
                }
            }
        }
    }

    private func invalidateVideoResolutionIfNeeded(videoID: String) {
        guard let identity = cachedSongIdentity(for: videoID) else {
            return
        }
        let service = recommendationService
        Task {
            await service.invalidateVideoResolution(for: identity)
#if DEBUG
            print("[IDResolver] cacheEvicted reason=unplayable")
#endif
        }
    }

    private static func provesVideoIsUnplayable(_ error: Error) -> Bool {
        guard let error = error as? YouTubeKitError else {
            return false
        }
        switch error {
        case .videoUnavailable, .videoPrivate, .recordingUnavailable,
             .membersOnly, .videoRegionBlocked, .videoAgeRestricted:
            return true
        case .maxRetriesExceeded, .htmlParseError, .extractError,
             .regexMatchError, .liveStreamError:
            return false
        }
    }

    private func deduplicatedDashboardCandidates(
        _ candidates: [DashboardWarmupCandidate]
    ) -> [DashboardWarmupCandidate] {
        var seenVideoIDs: Set<String> = []

        return candidates.compactMap { candidate in
            let videoID = normalizedVideoID(candidate.videoID)
            guard !videoID.isEmpty, seenVideoIDs.insert(videoID).inserted else {
                return nil
            }

            return DashboardWarmupCandidate(
                playlistID: candidate.playlistID,
                videoID: videoID
            )
        }
    }

    private func deduplicatedVideoIDs(_ videoIDs: [String]) -> [String] {
        var seenVideoIDs: Set<String> = []

        return videoIDs.compactMap { rawVideoID in
            let videoID = normalizedVideoID(rawVideoID)
            guard !videoID.isEmpty, seenVideoIDs.insert(videoID).inserted else {
                return nil
            }

            return videoID
        }
    }

    private func replaceSearchPreResolution(with candidateVideoIDs: Set<String>) {
        _ = cancelSearchPreResolutionWork(
            preserving: candidateVideoIDs,
            cancelObsoleteResolution: true
        )

        let activePlaybackVideoIDs = Set(
            searchSpeculativeStreamIDs.filter(isNeededByActivePlayback)
        )
        let obsoleteVideoIDs = SearchPreResolutionPlan.obsoleteVideoIDs(
            previous: searchSpeculativeStreamIDs,
            retaining: candidateVideoIDs,
            nonSpeculative: nonSpeculativeStreamIDs,
            activePlayback: activePlaybackVideoIDs
        )
        for videoID in obsoleteVideoIDs {
            removeCachedStream(for: videoID)
        }

        let protectedVideoIDs = searchSpeculativeStreamIDs.subtracting(obsoleteVideoIDs)
        for videoID in protectedVideoIDs where !candidateVideoIDs.contains(videoID) {
            markStreamAsNonSpeculative(videoID)
        }

        searchSpeculativeStreamIDs.formIntersection(candidateVideoIDs)
    }

    @discardableResult
    private func cancelSearchPreResolutionWork(
        preserving preservedVideoIDs: Set<String> = [],
        cancelObsoleteResolution: Bool = false
    ) -> Bool {
        let hadActivePreResolution = activeSearchPreResolutionID != nil
        let activeVideoID = activeSearchResolutionVideoID
        activeSearchPreResolutionID = nil
        searchPreResolutionTask?.cancel()
        searchPreResolutionTask = nil

        if
            cancelObsoleteResolution,
            let activeVideoID,
            !preservedVideoIDs.contains(activeVideoID),
            !nonSpeculativeStreamIDs.contains(activeVideoID),
            !isNeededByActivePlayback(activeVideoID)
        {
            inFlightResolutions[activeVideoID]?.task.cancel()
            searchPreResolveLog("cancelled videoID=\(activeVideoID)")
        }

        activeSearchResolutionVideoID = nil
        return hadActivePreResolution
    }

    private func replaceDashboardWarmup(with candidateVideoIDs: Set<String>) {
        let hadActiveWarmup = cancelDashboardWarmupWork(
            preserving: candidateVideoIDs,
            cancelObsoleteResolution: true
        )

        let obsoleteVideoIDs = dashboardSpeculativeStreamIDs
            .subtracting(candidateVideoIDs)

        for videoID in obsoleteVideoIDs {
            if nonSpeculativeStreamIDs.contains(videoID) || isNeededByActivePlayback(videoID) {
                markStreamAsNonSpeculative(videoID)
                continue
            }

            removeCachedStream(for: videoID)
            dashboardLog("evicted speculative track=\(videoID)")
        }

        dashboardSpeculativeStreamIDs.formIntersection(candidateVideoIDs)

        if hadActiveWarmup {
            dashboardLog("cancelled old page")
        }
    }

    @discardableResult
    private func cancelDashboardWarmupWork(
        preserving preservedVideoIDs: Set<String> = [],
        cancelObsoleteResolution: Bool = false
    ) -> Bool {
        let hadActiveWarmup = activeDashboardWarmupID != nil
        activeDashboardWarmupID = nil
        dashboardWarmupTask?.cancel()
        dashboardWarmupTask = nil

        if cancelObsoleteResolution {
            if
                let videoID = activeDashboardResolutionVideoID,
                !preservedVideoIDs.contains(videoID),
                !nonSpeculativeStreamIDs.contains(videoID),
                !isNeededByActivePlayback(videoID)
            {
                inFlightResolutions[videoID]?.task.cancel()
            }

            activeDashboardResolutionVideoID = nil
        }

        return hadActiveWarmup
    }

    private func replacePlaylistWarmup(with candidateVideoIDs: Set<String>) {
        let hadActiveWarmup = cancelPlaylistWarmupWork(
            preserving: candidateVideoIDs,
            cancelObsoleteResolution: true
        )

        let obsoleteVideoIDs = playlistSpeculativeStreamIDs
            .subtracting(candidateVideoIDs)

        for videoID in obsoleteVideoIDs {
            if nonSpeculativeStreamIDs.contains(videoID) || isNeededByActivePlayback(videoID) {
                markStreamAsNonSpeculative(videoID)
                continue
            }

            removeCachedStream(for: videoID)
            playlistLog("evicted speculative track=\(videoID)")
        }

        playlistSpeculativeStreamIDs.formIntersection(candidateVideoIDs)

        if hadActiveWarmup {
            playlistLog("cancelled")
        }
    }

    @discardableResult
    private func cancelPlaylistWarmupWork(
        preserving preservedVideoIDs: Set<String> = [],
        cancelObsoleteResolution: Bool = false
    ) -> Bool {
        let hadActiveWarmup = activePlaylistWarmupID != nil
        activePlaylistWarmupID = nil
        playlistWarmupTask?.cancel()
        playlistWarmupTask = nil

        if cancelObsoleteResolution {
            if
                let videoID = activePlaylistResolutionVideoID,
                !preservedVideoIDs.contains(videoID),
                !nonSpeculativeStreamIDs.contains(videoID),
                !isNeededByActivePlayback(videoID)
            {
                inFlightResolutions[videoID]?.task.cancel()
            }

            activePlaylistResolutionVideoID = nil
        }

        return hadActiveWarmup
    }

    private func releaseDashboardWarmup(
        forPlaylistCandidates candidateVideoIDs: Set<String>
    ) {
        _ = cancelDashboardWarmupWork(
            preserving: candidateVideoIDs,
            cancelObsoleteResolution: true
        )

        let retainedVideoIDs = dashboardSpeculativeStreamIDs
            .intersection(candidateVideoIDs)
        let obsoleteVideoIDs = dashboardSpeculativeStreamIDs
            .subtracting(candidateVideoIDs)

        for videoID in obsoleteVideoIDs {
            if nonSpeculativeStreamIDs.contains(videoID) || isNeededByActivePlayback(videoID) {
                markStreamAsNonSpeculative(videoID)
            } else {
                removeCachedStream(for: videoID)
                dashboardLog("evicted speculative track=\(videoID)")
            }
        }

        dashboardSpeculativeStreamIDs.subtract(candidateVideoIDs)
        playlistSpeculativeStreamIDs.formUnion(retainedVideoIDs)
    }

    private func releasePlaylistWarmup(
        forDashboardCandidates candidateVideoIDs: Set<String>
    ) {
        _ = cancelPlaylistWarmupWork(
            preserving: candidateVideoIDs,
            cancelObsoleteResolution: true
        )

        let retainedVideoIDs = playlistSpeculativeStreamIDs
            .intersection(candidateVideoIDs)
        let obsoleteVideoIDs = playlistSpeculativeStreamIDs
            .subtracting(candidateVideoIDs)

        for videoID in obsoleteVideoIDs {
            if nonSpeculativeStreamIDs.contains(videoID) || isNeededByActivePlayback(videoID) {
                markStreamAsNonSpeculative(videoID)
            } else {
                removeCachedStream(for: videoID)
                playlistLog("evicted speculative track=\(videoID)")
            }
        }

        playlistSpeculativeStreamIDs.subtract(candidateVideoIDs)
        dashboardSpeculativeStreamIDs.formUnion(retainedVideoIDs)
    }

    private func pauseSpeculativeWarmupsForPlayback(requestedVideoID: String) {
        markStreamAsNonSpeculative(requestedVideoID)

        let hadActiveWarmup = activeDashboardWarmupID != nil
        activeDashboardWarmupID = nil
        dashboardWarmupTask?.cancel()
        dashboardWarmupTask = nil

        if
            let activeVideoID = activeDashboardResolutionVideoID,
            activeVideoID != requestedVideoID,
            !nonSpeculativeStreamIDs.contains(activeVideoID),
            !isNeededByActivePlayback(activeVideoID)
        {
            inFlightResolutions[activeVideoID]?.task.cancel()
        }
        activeDashboardResolutionVideoID = nil

        let hadActivePlaylistWarmup = activePlaylistWarmupID != nil
        activePlaylistWarmupID = nil
        playlistWarmupTask?.cancel()
        playlistWarmupTask = nil

        if
            let activeVideoID = activePlaylistResolutionVideoID,
            activeVideoID != requestedVideoID,
            !nonSpeculativeStreamIDs.contains(activeVideoID),
            !isNeededByActivePlayback(activeVideoID)
        {
            inFlightResolutions[activeVideoID]?.task.cancel()
        }
        activePlaylistResolutionVideoID = nil

        let hadActiveSearchPreResolution = cancelSearchPreResolutionWork(
            preserving: [requestedVideoID],
            cancelObsoleteResolution: true
        )

        if hadActiveWarmup {
            dashboardLog("cancelled for foreground playback")
        }

        if hadActivePlaylistWarmup {
            playlistLog("cancelled for foreground playback")
        }

        if hadActiveSearchPreResolution {
            searchPreResolveLog("cancelled for foreground playback")
        }
    }

    private func evictObsoleteSpeculativeEntries(
        from previousPlaylistID: PersistentIdentifier,
        for newPlaylistID: PersistentIdentifier,
        retaining newPlaylistVideoIDs: Set<String>
    ) {
        let consideredVideoIDs = playlistSpeculativeStreamIDs
        let promotedVideoIDs = consideredVideoIDs.intersection(nonSpeculativeStreamIDs)
        let activePlaybackVideoIDs = Set(
            consideredVideoIDs.filter(isNeededByActivePlayback)
        )
        let newPlaylistProtectedVideoIDs = consideredVideoIDs
            .intersection(newPlaylistVideoIDs)
        let protectedVideoIDs = promotedVideoIDs
            .union(activePlaybackVideoIDs)
            .union(newPlaylistProtectedVideoIDs)
        let obsoleteVideoIDs = consideredVideoIDs.subtracting(protectedVideoIDs)

        playlistLog(
            "switch previous=\(previousPlaylistID) new=\(newPlaylistID) "
                + "considered=\(consideredVideoIDs.sorted())"
        )

        if !protectedVideoIDs.isEmpty {
            playlistLog(
                "switch protected promoted=\(promotedVideoIDs.sorted()) "
                    + "active=\(activePlaybackVideoIDs.sorted()) "
                    + "new=\(newPlaylistProtectedVideoIDs.sorted())"
            )
        }

        var cancelledResolutionVideoIDs: [String] = []
        var evictedCachedVideoIDs: [String] = []

        for videoID in obsoleteVideoIDs {
            if let resolution = inFlightResolutions[videoID] {
                resolution.task.cancel()
                cancelledResolutionVideoIDs.append(videoID)
            }

            if resolvedStreamCache[videoID] != nil {
                evictedCachedVideoIDs.append(videoID)
            }

            removeCachedStream(for: videoID)
        }

        if !evictedCachedVideoIDs.isEmpty || !cancelledResolutionVideoIDs.isEmpty {
            playlistLog(
                "switch evicted=\(evictedCachedVideoIDs.sorted()) "
                    + "cancelled=\(cancelledResolutionVideoIDs.sorted())"
            )
        }
    }

    private func isNeededByActivePlayback(_ videoID: String) -> Bool {
        if normalizedVideoID(currentPlayableTrack?.youtubeVideoID ?? "") == videoID {
            return true
        }

        if preparedNextPlayback?.videoID == videoID || preparedNextVideoID == videoID {
            return true
        }

        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return false
        }

        let protectedIndices = [currentIndex] + upcomingQueueIndices(
            after: currentIndex,
            limit: streamLookaheadCount
        )
        return protectedIndices.contains {
            normalizedVideoID(queue[$0].youtubeVideoID) == videoID
        }
    }

    private func markStreamAsNonSpeculative(_ videoID: String) {
        guard !videoID.isEmpty else {
            return
        }

        nonSpeculativeStreamIDs.insert(videoID)
        dashboardSpeculativeStreamIDs.remove(videoID)
        playlistSpeculativeStreamIDs.remove(videoID)
        searchSpeculativeStreamIDs.remove(videoID)
    }

    private func removeCachedStream(for videoID: String) {
        resolvedStreamCache.removeValue(forKey: videoID)
        resolvedStreamDiagnostics.removeValue(forKey: videoID)
        dashboardSpeculativeStreamIDs.remove(videoID)
        playlistSpeculativeStreamIDs.remove(videoID)
        searchSpeculativeStreamIDs.remove(videoID)
        nonSpeculativeStreamIDs.remove(videoID)
    }

    private func normalizedVideoID(_ videoID: String) -> String {
        videoID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func playlistID(from origin: PlaybackOrigin?) -> PersistentIdentifier? {
        guard case let .playlist(playlistID) = origin else {
            return nil
        }

        return playlistID
    }

    private func resolutionTask(
        for videoID: String,
        source: StreamResolutionSource
    ) -> Task<URL, Error> {
        switch source {
        case .dashboardWarmup:
            if !nonSpeculativeStreamIDs.contains(videoID) {
                dashboardSpeculativeStreamIDs.insert(videoID)
            }
        case .playlistWarmup:
            if !nonSpeculativeStreamIDs.contains(videoID) {
                playlistSpeculativeStreamIDs.insert(videoID)
            }
        case .searchPreResolve:
            if !nonSpeculativeStreamIDs.contains(videoID) {
                searchSpeculativeStreamIDs.insert(videoID)
            }
        case .foreground, .preResolution, .lookahead, .memoryCache:
            markStreamAsNonSpeculative(videoID)
        }

        if let existingResolution = inFlightResolutions[videoID] {
            return existingResolution.task
        }

        let resolutionID = UUID()
        let task = Task { @MainActor [weak self] () throws -> URL in
            guard let self else {
                throw CancellationError()
            }

            defer {
                if inFlightResolutions[videoID]?.id == resolutionID {
                    inFlightResolutions[videoID] = nil
                }
            }

            let streams = try await YouTube(
                videoID: videoID,
                methods: [.local],
                audioOnlyM4AIsSufficient: true
            ).streams

            try Task.checkCancellation()

            let nativeAudioStreams = streams
                .filterAudioOnly()
                .filter(\.isNativelyPlayable)
            let stream = nativeAudioStreams
                .filter { $0.fileExtension == .m4a }
                .highestAudioBitrateStream()
                ?? nativeAudioStreams.highestAudioBitrateStream()

            guard let stream else {
                throw StreamResolutionError.noPlayableStream
            }

            let diagnostics = StreamDiagnostics(
                fileExtension: stream.fileExtension.rawValue,
                audioBitrate: stream.bitrate ?? stream.averageBitrate
            )
            logSelectedStream(videoID: videoID, diagnostics: diagnostics, source: source)
            resolvedStreamDiagnostics[videoID] = diagnostics
            resolvedStreamCache[videoID] = stream.url
            return stream.url
        }

        inFlightResolutions[videoID] = InFlightResolution(
            id: resolutionID,
            task: task
        )
        return task
    }

    private func beginPreResolvingNextTrack() {
        guard repeatMode != .one else {
            return
        }

        guard
            let currentIndex,
            let nextIndex = nextQueueIndex(after: currentIndex)
        else {
            return
        }

        let nextTrack = queue[nextIndex]
        let videoID = nextTrack.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preparedNextVideoID != videoID else {
            return
        }

        cancelUpcomingPreResolutionObservation()
        preparedNextVideoID = videoID
        let preResolutionID = UUID()
        activePreResolutionID = preResolutionID

        guard !videoID.isEmpty else {
            activePreResolutionID = nil
            beginLookaheadFill(from: currentIndex)
            return
        }

        if let cachedURL = resolvedStreamCache[videoID] {
            markStreamAsNonSpeculative(videoID)
            log("Pre-resolution cache already available for \(videoID) (\(nextTrack.title))")
            beginPreparingNextItem(
                with: cachedURL,
                track: nextTrack,
                queueIndex: nextIndex,
                videoID: videoID,
                preparationID: preResolutionID
            )
            return
        }

        let wasAlreadyInFlight = inFlightResolutions[videoID] != nil
        let resolutionTask = resolutionTask(for: videoID, source: .preResolution)
        let startedAt = currentTime

        if wasAlreadyInFlight {
            log("Pre-resolution already in progress for \(videoID) (\(nextTrack.title))")
        } else {
            log("Pre-resolution started for \(videoID) (\(nextTrack.title))")
        }

        preResolutionTask = Task { [weak self] in
            do {
                let streamURL = try await resolutionTask.value
                try Task.checkCancellation()

                guard
                    let self,
                    activePreResolutionID == preResolutionID,
                    isExpectedNextTrack(nextTrack, at: nextIndex, videoID: videoID)
                else {
                    return
                }

                let elapsedTime = currentTime - startedAt
                log(
                    "Pre-resolution completed for \(videoID) in "
                        + "\(String(format: "%.3f", elapsedTime)) s"
                )
                preResolutionTask = nil
                beginPreparingNextItem(
                    with: streamURL,
                    track: nextTrack,
                    queueIndex: nextIndex,
                    videoID: videoID,
                    preparationID: preResolutionID
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, activePreResolutionID == preResolutionID else {
                    return
                }

                let reason: String
                if case StreamResolutionError.noPlayableStream = error {
                    reason = "no natively playable audio-only stream was available"
                } else {
                    reason = Self.errorMessage(for: error)
                }

                log(
                    "Pre-resolution failed for \(videoID): "
                        + reason
                )
                activePreResolutionID = nil
                preResolutionTask = nil
                beginLookaheadFill(from: currentIndex)
            }
        }
    }

    private func cancelUpcomingPreResolutionObservation() {
        activePreResolutionID = nil
        preResolutionTask?.cancel()
        preResolutionTask = nil
        preparedNextVideoID = nil
        discardPreparedNextPlayback()
        cancelLookaheadFill()
    }

    private func beginPreparingNextItem(
        with streamURL: URL,
        track: Track,
        queueIndex: Int,
        videoID: String,
        preparationID: UUID
    ) {
        guard
            activePreResolutionID == preparationID,
            isExpectedNextTrack(track, at: queueIndex, videoID: videoID)
        else {
            return
        }

        discardPreparedNextPlayback()

        let preparationStartedAt = currentTime
        let asset = AVURLAsset(url: streamURL)
        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: [.isPlayable, .duration]
        )
        let playbackRange = effectivePlaybackRange(for: PlayableTrack(track: track))
        applyEffectiveEndTime(to: item, playbackRange: playbackRange)

        let preparationPlayer = AVPlayer(playerItem: item)
        preparedNextPlayback = PreparedNextPlayback(
            preparationID: preparationID,
            queueIndex: queueIndex,
            track: track,
            videoID: videoID,
            streamURL: streamURL,
            item: item,
            player: preparationPlayer,
            playbackRange: playbackRange,
            preparationStartedAt: preparationStartedAt,
            readyAt: nil
        )
        log("Next-item preparation started for \(videoID)")

        let managerReference = WeakReference(self)
        let itemReference = WeakReference(item)
        nextItemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
            [managerReference, itemReference] _, _ in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    let item = itemReference.value
                else {
                    return
                }

                self.handleNextItemStatus(
                    preparationPlayer,
                    item: item,
                    preparationID: preparationID,
                    videoID: videoID
                )
            }
        }

        if let currentIndex {
            beginLookaheadFill(from: currentIndex)
        }
    }

    private func beginLookaheadFill(from anchorIndex: Int) {
        guard repeatMode != .one else {
            return
        }

        guard
            currentIndex == anchorIndex,
            queue.indices.contains(anchorIndex)
        else {
            return
        }

        cancelLookaheadFill()

        let upcomingIndices = upcomingQueueIndices(
            after: anchorIndex,
            limit: streamLookaheadCount
        )
        var candidates: [(queueIndex: Int, track: Track, videoID: String)] = []
        var seenVideoIDs: Set<String> = []

        for (position, candidateIndex) in upcomingIndices.enumerated() {
            let track = queue[candidateIndex]
            let videoID = normalizedVideoID(track.youtubeVideoID)

            // Position one is handled by prepared-next. Later positions are URL-only lookahead.
            guard position > 0, !videoID.isEmpty, seenVideoIDs.insert(videoID).inserted else {
                continue
            }

            candidates.append(
                (queueIndex: candidateIndex, track: track, videoID: videoID)
            )
        }

        guard !candidates.isEmpty else {
            return
        }

        let lookaheadID = UUID()
        activeLookaheadID = lookaheadID
        log("Lookahead fill started from index \(anchorIndex)")

        lookaheadTask = Task { [weak self] in
            defer {
                if let self, activeLookaheadID == lookaheadID {
                    activeLookaheadID = nil
                    lookaheadTask = nil
                }
            }

            for (candidateOffset, candidate) in candidates.enumerated() {
                guard
                    let self,
                    !Task.isCancelled,
                    isActiveLookahead(
                        lookaheadID,
                        anchorIndex: anchorIndex,
                        candidate: candidate
                    )
                else {
                    return
                }

                let videoID = candidate.videoID
                let offset = candidateOffset + 2

                if resolvedStreamCache[videoID] != nil {
                    markStreamAsNonSpeculative(videoID)
                    log("Lookahead cache hit for \(videoID) at +\(offset)")
                    continue
                }

                let joinedExistingResolution = inFlightResolutions[videoID] != nil
                if joinedExistingResolution {
                    log("Lookahead joined existing resolution for \(videoID) at +\(offset)")
                } else {
                    log("Lookahead resolving \(videoID) at +\(offset)")
                }

                let startedAt = currentTime
                let resolutionTask = resolutionTask(for: videoID, source: .lookahead)

                do {
                    _ = try await resolutionTask.value

                    guard
                        !Task.isCancelled,
                        isActiveLookahead(
                            lookaheadID,
                            anchorIndex: anchorIndex,
                            candidate: candidate
                        )
                    else {
                        return
                    }

                    let elapsedTime = currentTime - startedAt
                    log(
                        "Lookahead resolved \(videoID) at +\(offset) in "
                            + "\(String(format: "%.3f", elapsedTime)) s"
                    )
                } catch {
                    guard
                        !Task.isCancelled,
                        isActiveLookahead(
                            lookaheadID,
                            anchorIndex: anchorIndex,
                            candidate: candidate
                        )
                    else {
                        return
                    }

                    log("Lookahead resolution failed for \(videoID) at +\(offset)")
                }
            }
        }
    }

    private func isActiveLookahead(
        _ lookaheadID: UUID,
        anchorIndex: Int,
        candidate: (queueIndex: Int, track: Track, videoID: String)
    ) -> Bool {
        guard
            activeLookaheadID == lookaheadID,
            currentIndex == anchorIndex,
            queue.indices.contains(candidate.queueIndex)
        else {
            return false
        }

        let queuedTrack = queue[candidate.queueIndex]
        return queuedTrack === candidate.track
            && queuedTrack.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
                == candidate.videoID
    }

    private func cancelLookaheadFill() {
        let hadActiveLookahead = activeLookaheadID != nil
        activeLookaheadID = nil
        lookaheadTask?.cancel()
        lookaheadTask = nil

        if hadActiveLookahead {
            log("Lookahead cancelled")
        }
    }

    private func handleNextItemStatus(
        _ preparationPlayer: AVPlayer,
        item: AVPlayerItem,
        preparationID: UUID,
        videoID: String
    ) {
        guard
            activePreResolutionID == preparationID,
            let preparedNextPlayback,
            preparedNextPlayback.preparationID == preparationID,
            preparedNextPlayback.player === preparationPlayer,
            preparedNextPlayback.item === item
        else {
            return
        }

        switch item.status {
        case .readyToPlay:
            beginPrerollingNextItem(
                preparationPlayer,
                item: item,
                preparationID: preparationID,
                videoID: videoID
            )

        case .failed:
            handlePreparedNextItemFailure(
                item,
                preparationID: preparationID,
                videoID: videoID
            )

        case .unknown:
            break

        @unknown default:
            break
        }
    }

    private func beginPrerollingNextItem(
        _ preparationPlayer: AVPlayer,
        item: AVPlayerItem,
        preparationID: UUID,
        videoID: String
    ) {
        guard
            nextItemPrerollTask == nil,
            let preparedNextPlayback,
            preparedNextPlayback.preparationID == preparationID,
            preparedNextPlayback.player === preparationPlayer,
            preparedNextPlayback.item === item
        else {
            return
        }

        let playbackRange = preparedNextPlayback.playbackRange
        nextItemPrerollTask = Task { [weak self] in
            guard let self else {
                return
            }

            if playbackRange.startTime > 0 {
                let seekFinished = await seekPlayer(
                    preparationPlayer,
                    to: playbackRange.startTime
                )
                guard seekFinished else {
                    nextItemPrerollTask = nil
                    log("Next-item crop seek did not finish for \(videoID)")
                    return
                }
            }

            guard
                !Task.isCancelled,
                activePreResolutionID == preparationID
            else {
                return
            }

            let finished = await preparationPlayer.preroll(atRate: 1)

            guard
                !Task.isCancelled,
                activePreResolutionID == preparationID,
                var preparedNextPlayback = self.preparedNextPlayback,
                preparedNextPlayback.preparationID == preparationID,
                preparedNextPlayback.player === preparationPlayer,
                preparedNextPlayback.item === item
            else {
                return
            }

            nextItemPrerollTask = nil

            if item.status == .failed {
                handlePreparedNextItemFailure(
                    item,
                    preparationID: preparationID,
                    videoID: videoID
                )
                return
            }

            guard finished else {
                log("Next-item preparation did not finish for \(videoID)")
                return
            }

            let readyAt = currentTime
            preparedNextPlayback.readyAt = readyAt
            self.preparedNextPlayback = preparedNextPlayback
            let preparationTime = readyAt - preparedNextPlayback.preparationStartedAt
            log(
                "Next-item preparation ready for \(videoID) in "
                    + "\(String(format: "%.3f", preparationTime)) s"
            )
        }
    }

    private func handlePreparedNextItemFailure(
        _ item: AVPlayerItem,
        preparationID: UUID,
        videoID: String
    ) {
        guard
            let preparedNextPlayback,
            preparedNextPlayback.preparationID == preparationID,
            preparedNextPlayback.item === item
        else {
            return
        }

        logPlayerItemFailureDiagnostics(for: item, videoID: videoID)

        if resolvedStreamCache[videoID] == preparedNextPlayback.streamURL {
            removeCachedStream(for: videoID)
            log("Next-item preparation failed for \(videoID); cached URL evicted")
        } else {
            log("Next-item preparation failed for \(videoID); stale item discarded")
        }

        activePreResolutionID = nil
        preResolutionTask = nil
        discardPreparedNextPlayback()
    }

    private func isExpectedNextTrack(
        _ track: Track,
        at queueIndex: Int,
        videoID: String
    ) -> Bool {
        guard
            let currentIndex,
            nextQueueIndex(after: currentIndex) == queueIndex,
            queue.indices.contains(queueIndex)
        else {
            return false
        }

        let queuedTrack = queue[queueIndex]
        return queuedTrack === track
            && queuedTrack.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines) == videoID
    }

    private func takePreparedNextPlayback(
        queueIndex: Int,
        track: Track,
        videoID: String
    ) -> PreparedNextPlayback? {
        guard
            let preparedNextPlayback,
            preparedNextPlayback.queueIndex == queueIndex,
            preparedNextPlayback.track === track,
            preparedNextPlayback.videoID == videoID
        else {
            return nil
        }

        self.preparedNextPlayback = nil
        nextItemStatusObservation = nil
        nextItemPrerollTask?.cancel()
        nextItemPrerollTask = nil
        preparedNextPlayback.player.cancelPendingPrerolls()
        activePreResolutionID = nil
        preparedNextVideoID = nil
        return preparedNextPlayback
    }

    private func discardPreparedNextPlayback() {
        guard let preparedNextPlayback else {
            nextItemStatusObservation = nil
            nextItemPrerollTask?.cancel()
            nextItemPrerollTask = nil
            return
        }

        self.preparedNextPlayback = nil
        nextItemStatusObservation = nil
        nextItemPrerollTask?.cancel()
        nextItemPrerollTask = nil
        discard(preparedNextPlayback)
    }

    private func discard(_ preparedPlayback: PreparedNextPlayback) {
        preparedPlayback.player.cancelPendingPrerolls()
        preparedPlayback.player.pause()
        preparedPlayback.player.replaceCurrentItem(with: nil)
    }

    private func startPlayback(
        with streamURL: URL,
        videoID: String,
        requestID: UUID,
        requestStartedAt: TimeInterval,
        playerPreparationStartedAt: TimeInterval,
        usedCachedStream: Bool
    ) {
        let item = AVPlayerItem(url: streamURL)
        let player = AVPlayer(playerItem: item)
        let playbackRange = effectivePlaybackRange(for: currentPlayableTrack)
        startPlayback(
            with: item,
            player: player,
            videoID: videoID,
            requestID: requestID,
            requestStartedAt: requestStartedAt,
            playerPreparationStartedAt: playerPreparationStartedAt,
            usedCachedStream: usedCachedStream,
            playbackRange: playbackRange,
            playbackStartTime: pendingTrimPreviewStartTime(for: currentTrack, in: playbackRange)
        )
    }

    private func startPlayback(
        with item: AVPlayerItem,
        player: AVPlayer,
        videoID: String,
        requestID: UUID,
        requestStartedAt: TimeInterval,
        playerPreparationStartedAt: TimeInterval,
        usedCachedStream: Bool,
        playbackRange: EffectivePlaybackRange,
        playbackStartTime: TimeInterval
    ) {
        guard isActive(requestID) else {
            return
        }

        do {
            try activateAudioSession()
        } catch {
            state = .failed("The audio session could not start: \(error.localizedDescription)")
            return
        }

        let managerReference = WeakReference(self)
        let itemReference = WeakReference(item)
        let trackDuration = currentPlayableTrack?.duration

        applyEffectiveEndTime(to: item, playbackRange: playbackRange)

        self.player = player
        installPlaybackBoundaryObserver(
            on: player,
            item: item,
            playbackRange: playbackRange,
            requestID: requestID
        )
        if isTrimPreviewActive {
            installTrimPreviewTimeObserver(
                on: player,
                playbackRange: playbackRange,
                requestID: requestID
            )
        } else {
            installListeningCheckpointObserver(on: player, requestID: requestID)
        }

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [managerReference, itemReference] _ in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    let item = itemReference.value
                else {
                    return
                }

                self.handlePlaybackCompletion(for: item, requestID: requestID)
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
            [managerReference] _, _ in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    self.isActive(requestID),
                    let item = self.player?.currentItem
                else {
                    return
                }

                switch item.status {
                case .readyToPlay:
                    self.logDurationDiagnostics(
                        for: item,
                        videoID: videoID,
                        trackDuration: trackDuration,
                        requestID: requestID
                    )
#if os(iOS)
                    self.synchronizeNowPlayingPlaybackState()
#endif

                case .failed:
                    self.handlePlayerFailure(
                        item,
                        videoID: videoID,
                        requestID: requestID,
                        requestStartedAt: requestStartedAt,
                        usedCachedStream: usedCachedStream
                    )

                case .unknown:
                    break

                @unknown default:
                    break
                }
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) {
            [managerReference] _, _ in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    self.isActive(requestID),
                    let player = self.player
                else {
                    return
                }

#if os(iOS)
                self.synchronizeNowPlayingPlaybackState()
#endif

                guard player.timeControlStatus == .playing else {
                    self.finishActiveListeningPeriod()
                    return
                }

                self.state = .playing
                guard !self.isTrimPreviewActive else {
                    return
                }

                self.reportPlaybackStartedIfNeeded(
                    requestID: requestID,
                    videoID: videoID
                )
                self.recordTrackPlaybackStartIfNeeded(requestID: requestID)
                self.recordListeningHistoryStartIfNeeded(
                    player: player,
                    requestID: requestID
                )
                self.beginActiveListeningPeriod(
                    for: player,
                    requestID: requestID
                )
                self.recordPlaybackStarted(
                    videoID: videoID,
                    requestStartedAt: requestStartedAt,
                    playerPreparationStartedAt: playerPreparationStartedAt
                )
                self.beginPreResolvingNextTrack()
            }
        }

        beginPlayback(
            player,
            at: playbackStartTime,
            requestID: requestID
        )
    }

    private func beginPlayback(
        _ player: AVPlayer,
        at startTime: TimeInterval,
        requestID: UUID
    ) {
        guard startTime > 0 else {
            player.play()
#if os(iOS)
            synchronizeNowPlayingPlaybackState()
#endif
            return
        }

        let currentTime = player.currentTime().seconds
        if currentTime.isFinite, abs(currentTime - startTime) < 0.05 {
            player.play()
#if os(iOS)
            synchronizeNowPlayingPlaybackState()
#endif
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            let finished = await seekPlayer(player, to: startTime)
            guard
                finished,
                isActive(requestID),
                self.player === player
            else {
                return
            }

#if os(iOS)
            synchronizeNowPlayingPlaybackState()
#endif
            player.play()
#if os(iOS)
            synchronizeNowPlayingPlaybackState()
#endif
        }
    }

    private func seekPlayer(_ player: AVPlayer, to time: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: time, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { finished in
                continuation.resume(returning: finished)
            }
        }
    }

    private func handlePlayerFailure(
        _ item: AVPlayerItem,
        videoID: String,
        requestID: UUID,
        requestStartedAt: TimeInterval,
        usedCachedStream: Bool
    ) {
        guard isActive(requestID) else {
            return
        }

        let error = item.error
        logPlayerItemFailureDiagnostics(for: item, videoID: videoID)

        let failedDuringPreparation = startupMetrics?.totalStartTime == nil
        removeCachedStream(for: videoID)
        cancelUpcomingPreResolutionObservation()
        clearPlayer()

        if usedCachedStream && failedDuringPreparation {
            log("Cached stream failed during preparation for \(videoID); evicting and resolving once")
            updateMetrics { metrics in
                metrics.streamSource = "Fresh resolution after cached URL failure"
                metrics.streamResolutionTime = nil
                metrics.playerStartTime = nil
                metrics.totalStartTime = nil
            }
            resolveAndStartPlayback(
                videoID: videoID,
                requestID: requestID,
                requestStartedAt: requestStartedAt
            )
            return
        }

        state = .failed(
            "AVPlayer could not play the resolved stream: "
                + (error?.localizedDescription ?? "Unknown playback error.")
        )
#if os(iOS)
        synchronizeNowPlayingPlaybackState()
#endif
    }

#if os(iOS)
    private func publishNowPlaying(_ track: PlayableTrack, requestID: UUID) {
        artworkTask?.cancel()
        artworkTask = nil
        let playbackRange = effectivePlaybackRange(for: track)

        var information: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackRange.startTime,
            MPNowPlayingInfoPropertyPlaybackRate: 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1
        ]

        if let channelTitle = track.channelTitle, !channelTitle.isEmpty {
            information[MPMediaItemPropertyArtist] = channelTitle
        }

        if let duration = intendedPlaybackDuration(for: track) {
            information[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if
            let thumbnailURL = track.thumbnailURL,
            thumbnailURL == cachedArtworkURL,
            let cachedArtwork
        {
            information[MPMediaItemPropertyArtwork] = cachedArtwork
        }

        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = information
        nowPlayingCenter.playbackState = .paused

        guard
            let thumbnailURL = track.thumbnailURL,
            information[MPMediaItemPropertyArtwork] == nil
        else {
            return
        }

        artworkTask = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: thumbnailURL)
                try Task.checkCancellation()

                guard
                    let httpResponse = response as? HTTPURLResponse,
                    (200..<300).contains(httpResponse.statusCode),
                    let image = UIImage(data: data),
                    let self,
                    self.isActive(requestID)
                else {
                    return
                }

                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                cachedArtworkURL = thumbnailURL
                cachedArtwork = artwork

                var currentInformation = nowPlayingCenter.nowPlayingInfo ?? [:]
                currentInformation[MPMediaItemPropertyArtwork] = artwork
                nowPlayingCenter.nowPlayingInfo = currentInformation
            } catch {
                // Artwork is optional and must never interrupt audio playback.
            }
        }
    }

    private func synchronizeNowPlayingPlaybackState() {
        guard !isTrimPreviewActive, currentPlayableTrack != nil else {
            return
        }

        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        var information = nowPlayingCenter.nowPlayingInfo ?? [:]

        if let player {
            let elapsedTime = player.currentTime().seconds
            if elapsedTime.isFinite, elapsedTime >= 0 {
                let playbackRange = effectivePlaybackRange(for: currentPlayableTrack)
                information[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
                    clampedPlaybackTime(elapsedTime, to: playbackRange)
            }

            if let intendedDuration = intendedPlaybackDuration(for: currentPlayableTrack) {
                information[MPMediaItemPropertyPlaybackDuration] = intendedDuration
            } else if let playerDuration = validDuration(player.currentItem?.duration.seconds) {
                information[MPMediaItemPropertyPlaybackDuration] = playerDuration
            }

            let playbackRate = player.timeControlStatus == .playing ? player.rate : 0
            information[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
            nowPlayingCenter.playbackState = playbackRate > 0 ? .playing : .paused
        } else {
            information[MPNowPlayingInfoPropertyPlaybackRate] = 0
            nowPlayingCenter.playbackState = .paused
        }

        nowPlayingCenter.nowPlayingInfo = information
    }

    private func clearNowPlaying() {
        artworkTask?.cancel()
        artworkTask = nil

        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.playbackState = .stopped
        nowPlayingCenter.nowPlayingInfo = nil
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        updateRemoteQueueCommands()

        remoteCommandTargets = [
            commandCenter.playCommand.addTarget { [weak self] _ in
                guard let self else {
                    return .noSuchContent
                }

                return self.handleRemotePlayCommand()
            },
            commandCenter.pauseCommand.addTarget { [weak self] _ in
                guard let self else {
                    return .noSuchContent
                }

                return self.handleRemotePauseCommand()
            },
            commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let self else {
                    return .noSuchContent
                }

                return self.handleRemoteTogglePlayPauseCommand()
            },
            commandCenter.nextTrackCommand.addTarget { [weak self] _ in
                guard let self else {
                    return .noSuchContent
                }

                return self.handleRemoteNextCommand()
            },
            commandCenter.previousTrackCommand.addTarget { [weak self] _ in
                guard let self else {
                    return .noSuchContent
                }

                return self.handleRemotePreviousCommand()
            }
        ]
    }

    private func updateRemoteQueueCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.nextTrackCommand.isEnabled = !isTrimPreviewActive && hasNextTrack
        commandCenter.previousTrackCommand.isEnabled = !isTrimPreviewActive && hasPreviousTrack
    }

    private func handleRemotePlayCommand() -> MPRemoteCommandHandlerStatus {
        guard !isTrimPreviewActive, currentPlayableTrack != nil else {
            return .noSuchContent
        }

        switch state {
        case .paused:
            resume()
        case .failed, .idle:
            restartCurrentPlayback()
        case .resolving, .loading, .playing:
            break
        }

        return .success
    }

    private func handleRemotePauseCommand() -> MPRemoteCommandHandlerStatus {
        guard !isTrimPreviewActive, currentPlayableTrack != nil else {
            return .noSuchContent
        }

        switch state {
        case .playing:
            pause()
            return .success
        case .paused:
            return .success
        case .idle, .resolving, .loading, .failed:
            return .commandFailed
        }
    }

    private func handleRemoteTogglePlayPauseCommand() -> MPRemoteCommandHandlerStatus {
        guard !isTrimPreviewActive, currentPlayableTrack != nil else {
            return .noSuchContent
        }

        switch state {
        case .playing:
            pause()
        case .paused:
            resume()
        case .failed, .idle:
            restartCurrentPlayback()
        case .resolving, .loading:
            return .commandFailed
        }

        return .success
    }

    private func handleRemoteNextCommand() -> MPRemoteCommandHandlerStatus {
        guard !isTrimPreviewActive, currentPlayableTrack != nil else {
            return .noSuchContent
        }

        guard hasNextTrack else {
            return .commandFailed
        }

        nextTrack()
        return .success
    }

    private func handleRemotePreviousCommand() -> MPRemoteCommandHandlerStatus {
        guard !isTrimPreviewActive, currentPlayableTrack != nil else {
            return .noSuchContent
        }

        guard hasPreviousTrack else {
            return .commandFailed
        }

        previousTrack()
        return .success
    }

#endif

    private func restartCurrentPlayback() {
        if currentTrack != nil {
            startCurrentQueueTrack()
        } else if let currentPlayableTrack {
            startPlaybackContext(currentPlayableTrack, persistentTrack: nil)
        }
    }

    private func intendedPlaybackDuration(for track: PlayableTrack?) -> TimeInterval? {
        validDuration(track?.duration)
    }

    private func effectivePlaybackRange(
        for track: PlayableTrack?
    ) -> EffectivePlaybackRange {
        guard let track else {
            return EffectivePlaybackRange(startTime: 0, endTime: nil)
        }

        if
            let trimPreviewRange,
            trimPreviewRange.track === currentTrack,
            normalizedVideoID(track.youtubeVideoID)
                == normalizedVideoID(trimPreviewRange.track.youtubeVideoID)
        {
            return trimPreviewRange.range
        }

        let authoritativeDuration = validDuration(track.duration)
        let fullTrackRange = EffectivePlaybackRange(startTime: 0, endTime: authoritativeDuration)
        guard let authoritativeDuration else {
            return fullTrackRange
        }

        let startTime = track.playbackStartTime ?? 0
        let endTime = track.playbackEndTime ?? authoritativeDuration
        return validatedPlaybackRange(
            startTime: startTime,
            endTime: endTime,
            authoritativeDuration: authoritativeDuration
        ) ?? fullTrackRange
    }

    private func validatedPlaybackRange(
        startTime: TimeInterval,
        endTime: TimeInterval,
        authoritativeDuration: TimeInterval?
    ) -> EffectivePlaybackRange? {
        guard
            let authoritativeDuration = validDuration(authoritativeDuration),
            startTime.isFinite,
            endTime.isFinite,
            startTime >= 0,
            startTime < endTime,
            endTime <= authoritativeDuration
        else {
            return nil
        }

        return EffectivePlaybackRange(startTime: startTime, endTime: endTime)
    }

    private func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else {
            return nil
        }

        return duration
    }

    private func clampedPlaybackTime(
        _ time: TimeInterval,
        to playbackRange: EffectivePlaybackRange
    ) -> TimeInterval {
        var clampedTime = max(time, playbackRange.startTime)
        if let endTime = playbackRange.endTime {
            clampedTime = min(clampedTime, endTime)
        }
        return clampedTime
    }

    private func pendingTrimPreviewStartTime(
        for track: Track?,
        in playbackRange: EffectivePlaybackRange
    ) -> TimeInterval {
        guard
            let track,
            let pendingTrimPreviewStartTime,
            pendingTrimPreviewStartTime.track === track
        else {
            return playbackRange.startTime
        }

        self.pendingTrimPreviewStartTime = nil
        return clampedPlaybackTime(pendingTrimPreviewStartTime.time, to: playbackRange)
    }

    private func applyEffectiveEndTime(
        to item: AVPlayerItem,
        playbackRange: EffectivePlaybackRange
    ) {
        guard let endTime = playbackRange.endTime else {
            return
        }

        item.forwardPlaybackEndTime = CMTime(
            seconds: endTime,
            preferredTimescale: 600
        )
    }

    private func updateActivePlaybackRange(_ playbackRange: EffectivePlaybackRange) {
        guard
            let player,
            let item = player.currentItem,
            let requestID = activeRequestID
        else {
            return
        }

        applyEffectiveEndTime(to: item, playbackRange: playbackRange)
        installPlaybackBoundaryObserver(
            on: player,
            item: item,
            playbackRange: playbackRange,
            requestID: requestID
        )

        if isTrimPreviewActive, let track = trimPreviewRange?.track {
            let currentTime = currentPlaybackTime ?? trimPreviewTime ?? playbackRange.startTime
            let clampedTime = clampedPlaybackTime(currentTime, to: playbackRange)
            trimPreviewTime = clampedTime

            if let endTime = playbackRange.endTime, currentTime > endTime {
                pauseActiveTrimPreview()
                seekTrimPreview(for: track, to: endTime)
            } else if currentTime < playbackRange.startTime {
                seekTrimPreview(for: track, to: playbackRange.startTime)
            }
        } else if let currentPlaybackTime {
            let clampedTime = clampedPlaybackTime(currentPlaybackTime, to: playbackRange)
            if abs(currentPlaybackTime - clampedTime) > 0.05 {
                seek(to: clampedTime)
            }
        }

#if os(iOS)
        synchronizeNowPlayingPlaybackState()
#endif
    }

    private func installPlaybackBoundaryObserver(
        on player: AVPlayer,
        item: AVPlayerItem,
        playbackRange: EffectivePlaybackRange,
        requestID: UUID
    ) {
        if let playbackBoundaryObserver {
            player.removeTimeObserver(playbackBoundaryObserver)
            self.playbackBoundaryObserver = nil
        }

        guard let effectiveEndTime = playbackRange.endTime else {
            return
        }

        let managerReference = WeakReference(self)
        let itemReference = WeakReference(item)
        let boundaryTime = CMTime(seconds: effectiveEndTime, preferredTimescale: 600)
        playbackBoundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: boundaryTime)],
            queue: .main
        ) { [managerReference, itemReference] in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    let item = itemReference.value
                else {
                    return
                }

                self.handlePlaybackCompletion(for: item, requestID: requestID)
            }
        }
    }

    private func installTrimPreviewTimeObserver(
        on player: AVPlayer,
        playbackRange: EffectivePlaybackRange,
        requestID: UUID
    ) {
        removeTrimPreviewTimeObserver()

        let managerReference = WeakReference(self)
        let playerReference = WeakReference(player)
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        let token = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [managerReference, playerReference] time in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    let observedPlayer = playerReference.value,
                    self.isTrimPreviewActive,
                    self.isActive(requestID),
                    self.player === observedPlayer,
                    time.seconds.isFinite
                else {
                    return
                }

                let currentRange = self.trimPreviewRange?.range ?? playbackRange
                self.trimPreviewTime = self.clampedPlaybackTime(
                    time.seconds,
                    to: currentRange
                )
            }
        }

        trimPreviewTimeObserver = (player, token)
    }

    private func removeTrimPreviewTimeObserver() {
        guard let trimPreviewTimeObserver else {
            return
        }

        trimPreviewTimeObserver.player.removeTimeObserver(trimPreviewTimeObserver.token)
        self.trimPreviewTimeObserver = nil
    }

    private func pauseActiveTrimPreview(atEnd: Bool = false) {
        guard isTrimPreviewActive else {
            return
        }

        player?.pause()
        if
            atEnd,
            let endTime = trimPreviewRange?.range.endTime
        {
            trimPreviewTime = endTime
        } else if
            let currentPlaybackTime,
            let playbackRange = trimPreviewRange?.range
        {
            trimPreviewTime = clampedPlaybackTime(
                currentPlaybackTime,
                to: playbackRange
            )
        }
        state = .paused
    }

    private func endActiveTrimPreviewIfNeeded() {
        guard let track = trimPreviewRange?.track else {
            return
        }

        endTrimPreview(for: track)
    }

    private func handlePlaybackCompletion(for item: AVPlayerItem, requestID: UUID) {
        guard isActive(requestID), player?.currentItem === item else {
            return
        }

        if isTrimPreviewActive {
            pauseActiveTrimPreview(atEnd: true)
            return
        }

        if repeatMode == .one {
            queueLog("repeating current track")
            restartCurrentPlayback()
            return
        }

        if hasNextTrack {
            advanceToNextTrack(reason: "Natural")
        } else {
            log("Final item completed; stopping playback")
            stop()
        }
    }

    private func logDurationDiagnostics(
        for item: AVPlayerItem,
        videoID: String,
        trackDuration: TimeInterval?,
        requestID: UUID
    ) {
        let itemDuration = validDuration(item.duration.seconds)
        let seekableRanges = seekableTimeRangesDescription(for: item)

        Task { [weak self] in
            let assetTime = try? await item.asset.load(.duration)

            guard
                let self,
                isActive(requestID),
                player?.currentItem === item
            else {
                return
            }

            let assetDuration = assetTime.flatMap { self.validDuration($0.seconds) }
            log(
                "Duration diagnostics for \(videoID): "
                    + "Track.duration=\(durationDescription(trackDuration)), "
                    + "AVPlayerItem.duration=\(durationDescription(itemDuration)), "
                    + "asset.duration=\(durationDescription(assetDuration)), "
                    + "seekableTimeRanges=\(seekableRanges)"
            )

            if
                let trackDuration = validDuration(trackDuration),
                let itemDuration,
                abs(itemDuration - trackDuration) > 2
            {
                log(
                    "Duration mismatch for \(videoID); using Track.duration "
                        + "\(durationDescription(trackDuration)) as the playback boundary"
                )
            }
        }
    }

    private func seekableTimeRangesDescription(for item: AVPlayerItem) -> String {
        let ranges = item.seekableTimeRanges.compactMap { value -> String? in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let duration = range.duration.seconds
            guard start.isFinite, duration.isFinite, duration >= 0 else {
                return nil
            }

            return String(format: "%.3f...%.3f s", start, start + duration)
        }

        return ranges.isEmpty ? "none" : "[\(ranges.joined(separator: ", "))]"
    }

    private func durationDescription(_ duration: TimeInterval?) -> String {
        guard let duration else {
            return "unavailable"
        }

        return String(format: "%.3f s", duration)
    }

    private func logSelectedStream(
        videoID: String,
        diagnostics: StreamDiagnostics?,
        source: StreamResolutionSource
    ) {
        let fileExtension = diagnostics?.fileExtension ?? "unavailable"
        let audioBitrate = diagnostics?.audioBitrate.map { "\($0) bps" } ?? "unavailable"

        log(
            "Selected audio stream for \(videoID): "
                + "source=\(source.rawValue), "
                + "itag=unavailable, "
                + "fileExtension=\(fileExtension), "
                + "audioBitrate=\(audioBitrate)"
        )
    }

    private func logPlayerItemFailureDiagnostics(
        for item: AVPlayerItem,
        videoID: String
    ) {
        if let error = item.error as NSError? {
            log(
                "AVPlayerItem failed for \(videoID): "
                    + "domain=\(Self.redactedDiagnosticText(error.domain)), "
                    + "code=\(error.code), "
                    + "description=\(Self.redactedDiagnosticText(error.localizedDescription))"
            )

            if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                log(
                    "AVPlayerItem underlying error for \(videoID): "
                        + "domain=\(Self.redactedDiagnosticText(underlyingError.domain)), "
                        + "code=\(underlyingError.code), "
                        + "description="
                        + Self.redactedDiagnosticText(underlyingError.localizedDescription)
                )
            }
        } else {
            log("AVPlayerItem failed for \(videoID): error unavailable")
        }

        guard let errorLog = item.errorLog(), !errorLog.events.isEmpty else {
            log("AVPlayerItem error log for \(videoID): no events")
            return
        }

        for (index, event) in errorLog.events.enumerated() {
            let comment = event.errorComment.map(Self.redactedDiagnosticText) ?? "unavailable"
            let uriHost = event.uri.flatMap { URLComponents(string: $0)?.host } ?? "unavailable"
            log(
                "AVPlayerItem error log event \(index + 1) for \(videoID): "
                    + "statusCode=\(event.errorStatusCode), "
                    + "domain=\(Self.redactedDiagnosticText(event.errorDomain)), "
                    + "comment=\(comment), "
                    + "uriHost=\(uriHost)"
            )
        }
    }

    private func recordPlaybackStarted(
        videoID: String,
        requestStartedAt: TimeInterval,
        playerPreparationStartedAt: TimeInterval
    ) {
        guard startupMetrics?.totalStartTime == nil else {
            return
        }

        let playbackStartedAt = currentTime
        let playerStartTime = playbackStartedAt - playerPreparationStartedAt
        let totalStartTime = playbackStartedAt - requestStartedAt
        let streamSource = startupMetrics?.streamSource ?? "unknown"

        updateMetrics { metrics in
            metrics.playerStartTime = playerStartTime
            metrics.totalStartTime = totalStartTime
        }
        logTiming("Player preparation/start", seconds: playerStartTime, videoID: videoID)
        logTiming("Total startup", seconds: totalStartTime, videoID: videoID)
        if streamSource == "Prepared next item" {
            log(
                "Prepared transition for \(videoID): "
                    + "\(String(format: "%.3f", totalStartTime)) s"
            )
        } else {
            log(
                "Transition to \(videoID) reached playing in "
                    + "\(String(format: "%.3f", totalStartTime)) s "
                    + "(source: \(streamSource))"
            )
        }
    }

    private func reportPlaybackStartedIfNeeded(requestID: UUID, videoID: String) {
        guard
            !isTrimPreviewActive,
            lastReportedPlaybackRequestID != requestID,
            let playbackOrigin
        else {
            return
        }

        lastReportedPlaybackRequestID = requestID
        playbackStartEvent = PlaybackStartEvent(
            id: requestID,
            origin: playbackOrigin,
            trackID: videoID
        )

        learnCurrentVideoResolution(
            videoID: videoID,
            origin: playbackOrigin
        )

        handleConfirmedRecommendationPlaybackStart(
            playableTrack: currentPlayableTrack,
            sourceTrack: currentTrack,
            origin: playbackOrigin
        )

#if DEBUG
        if case .playlist(let playlistID) = playbackOrigin {
            print("[PlaybackContext] playlist=\(playlistID)")
        }
#endif
    }

    private func learnCurrentVideoResolution(
        videoID: String,
        origin: PlaybackOrigin
    ) {
        guard
            let playableTrack = currentPlayableTrack,
            normalizedVideoID(playableTrack.youtubeVideoID) == normalizedVideoID(videoID)
        else {
            return
        }
        let metadata = YouTubeResolutionMetadata(
            title: playableTrack.title,
            channel: playableTrack.channelTitle,
            thumbnailURL: playableTrack.thumbnailURL,
            duration: playableTrack.duration
        )
        if let identity = recommendationTransportMetadata[videoID]?.canonicalIdentity {
            Task {
                await YouTubeResolutionKnowledgeTeacher.learnAuthoritative(
                    identity: identity,
                    videoID: videoID,
                    metadata: metadata,
                    source: .lastFMRecommendation
                )
            }
            return
        }

        let source: YouTubeResolutionKnowledgeSource
        switch origin {
        case .search, .recommendations:
            source = .manualSearch
        case .library:
            source = .library
        case .playlist:
            source = .playlist
        }
        let track = currentTrack
        Task {
            await YouTubeResolutionKnowledgeTeacher.learnIfConfident(
                videoID: videoID,
                rawTitle: track?.title ?? playableTrack.title,
                displayedArtist: track?.displayArtist ?? playableTrack.channelTitle,
                sourceChannel: track?.channelTitle ?? playableTrack.channelTitle,
                userArtistOverride: track?.userArtistOverride,
                metadata: metadata,
                source: source
            )
        }
    }

    private func cachedSongIdentity(for videoID: String) -> SongIdentity? {
        if let identity = recommendationTransportMetadata[videoID]?.canonicalIdentity {
            return identity
        }
        if let manual = recommendationManualSeeds[videoID] {
            return manual.confidentSongIdentityForCaching
        }
        guard
            let playableTrack = currentPlayableTrack,
            normalizedVideoID(playableTrack.youtubeVideoID) == normalizedVideoID(videoID)
        else {
            return nil
        }
        return RecommendationSeed(
            youtubeVideoID: videoID,
            rawTitle: currentTrack?.title ?? playableTrack.title,
            displayedArtist: currentTrack?.displayArtist ?? playableTrack.channelTitle,
            sourceChannel: currentTrack?.channelTitle ?? playableTrack.channelTitle,
            userArtistOverride: currentTrack?.userArtistOverride
        ).confidentSongIdentityForCaching
    }

    private func startRecommendationSession(anchor: RecommendationSeed) {
        endRecommendationSession(reason: "new Search playback")

        let seedVideoID = normalizedVideoID(anchor.youtubeVideoID)
        let session = RecommendationRadioSession(anchor: anchor)
        recommendationSessionID = session.id
        recommendationRadioSession = session
        recommendationSeenVideoIDs = seedVideoID.isEmpty ? [] : [seedVideoID]
        recommendationSeenVideoIDOrder = seedVideoID.isEmpty ? [] : [seedVideoID]
        recommendationSeenSongIdentities = [anchor.songIdentity]
        recommendationTransportMetadata = [:]
        recommendationManualSeeds = [:]
        recommendationLog("session started token=\(session.id) seed=\(seedVideoID)")
    }

    private func endRecommendationSession(reason: String) {
        guard recommendationSessionID != nil else {
            return
        }

        for task in recommendationTasks.values {
            task.cancel()
        }
        for task in recommendationMetadataTasks.values {
            task.cancel()
        }
        recommendationRefillTask?.cancel()
        recommendationTasks = [:]
        recommendationRefillTask = nil
        recommendationRefillID = nil
        recommendationMetadataTasks = [:]
        recommendationSessionID = nil
        recommendationRadioSession = nil
        recommendationSeenVideoIDs = []
        recommendationSeenVideoIDOrder = []
        recommendationSeenSongIdentities = []
        recommendationTransportMetadata = [:]
        recommendationManualSeeds = [:]
        recommendationMetadataRequestedIDs = []
        recommendationLog("mode ended for \(reason)")
    }

    private func hydrateRecommendationMetadataIfNeeded(for track: Track) {
        guard
            playbackOrigin == .recommendations,
            validDuration(track.duration) == nil
        else {
            return
        }

        let videoID = normalizedVideoID(track.youtubeVideoID)
        guard
            !videoID.isEmpty,
            let sessionID = recommendationSessionID,
            recommendationMetadataRequestedIDs.insert(videoID).inserted
        else {
            return
        }

        recommendationMetadataTasks[videoID] = Task { [weak self] in
            do {
                let metadata = try await metadataClient.metadata(for: videoID)
                guard let self else {
                    return
                }
                if recommendationSessionID == sessionID {
                    recommendationMetadataTasks[videoID] = nil
                }

                track.thumbnailURL = metadata.thumbnailURL ?? track.thumbnailURL
                track.duration = metadata.duration
                track.metadataLastRefreshed = .now

                guard currentTrack === track else {
                    return
                }

                currentPlayableTrack = PlayableTrack(track: track)
                updateActivePlaybackRange(
                    effectivePlaybackRange(for: currentPlayableTrack)
                )
#if os(iOS)
                if let activeRequestID, let currentPlayableTrack {
                    publishNowPlaying(currentPlayableTrack, requestID: activeRequestID)
                }
#endif
                recommendationLog("metadata ready track=\(videoID)")
            } catch is CancellationError {
                guard let self else {
                    return
                }
                if recommendationSessionID == sessionID {
                    recommendationMetadataTasks[videoID] = nil
                }
            } catch {
                guard let self else {
                    return
                }
                if recommendationSessionID == sessionID {
                    recommendationMetadataTasks[videoID] = nil
                }
                recommendationLog("metadata failed track=\(videoID)")
            }
        }
    }

    private func handleConfirmedRecommendationPlaybackStart(
        playableTrack: PlayableTrack?,
        sourceTrack: Track?,
        origin: PlaybackOrigin
    ) {
        guard origin == .search || origin == .recommendations else {
            recommendationLog("wrong playback origin=\(String(describing: origin))")
            return
        }
        guard
            let sessionID = recommendationSessionID,
            var radioSession = recommendationRadioSession,
            radioSession.id == sessionID
        else {
            recommendationLog("queue insertion skipped=missing recommendation session")
            return
        }
        guard let playableTrack else {
            recommendationLog("queue insertion skipped=missing confirmed playable track")
            return
        }

        let seedVideoID = normalizedVideoID(playableTrack.youtubeVideoID)
        guard !seedVideoID.isEmpty else {
            recommendationLog("queue insertion skipped=blank seed video ID")
            return
        }
        recordSeenRecommendationVideoID(seedVideoID)
        let seed = recommendationSeed(
            videoID: seedVideoID,
            playableTrack: playableTrack,
            sourceTrack: sourceTrack
        )
        recommendationSeenSongIdentities.insert(seed.songIdentity)
        radioSession.recordSeen(seed.songIdentity)

        if origin == .search {
            recommendationRadioSession = radioSession
            beginRecommendationEpoch(
                anchor: radioSession.epoch.anchor,
                epochID: radioSession.epoch.id,
                sessionID: sessionID,
                seedTrack: playableTrack
            )
            return
        }

        let action = radioSession.confirmedRecommendationPlayback(seed: seed)
        recommendationRadioSession = radioSession
        switch action {
        case .ignore:
            recommendationLog("playback progress skipped=already consumed")
        case .replenish(let epochID):
            recommendationLog(
                "epoch progress=\(radioSession.epoch.consumedRecommendationCount)"
            )
            beginRecommendationReservoirRefill(
                sessionID: sessionID,
                epochID: epochID,
                seed: playableTrack
            )
        case .startNewEpoch(let epochID, let anchor):
            recommendationLog(
                "epoch transition anchor=\(anchor.cleanedArtist) - \(anchor.cleanedTitle)"
            )
            recommendationRefillTask?.cancel()
            recommendationRefillTask = nil
            recommendationRefillID = nil
            for task in recommendationTasks.values {
                task.cancel()
            }
            recommendationTasks = [:]
            beginRecommendationEpoch(
                anchor: anchor,
                epochID: epochID,
                sessionID: sessionID,
                seedTrack: playableTrack
            )
        }
    }

    private func recommendationSeed(
        videoID: String,
        playableTrack: PlayableTrack,
        sourceTrack: Track?
    ) -> RecommendationSeed {
        if let metadata = recommendationTransportMetadata[videoID] {
            return RecommendationSeed(
                youtubeVideoID: videoID,
                canonicalIdentity: metadata.canonicalIdentity,
                youtubeTitle: metadata.youtubeTitle,
                youtubeChannel: metadata.youtubeChannel
            )
        }
        if let manualSeed = recommendationManualSeeds[videoID] {
            return manualSeed
        }
        return RecommendationSeed(
            youtubeVideoID: videoID,
            rawTitle: sourceTrack?.title ?? playableTrack.title,
            displayedArtist: sourceTrack?.displayArtist ?? playableTrack.channelTitle,
            sourceChannel: sourceTrack?.channelTitle ?? playableTrack.channelTitle,
            userArtistOverride: sourceTrack?.userArtistOverride
        )
    }

    private func beginRecommendationEpoch(
        anchor: RecommendationSeed,
        epochID: UUID,
        sessionID: UUID,
        seedTrack: PlayableTrack
    ) {
        let taskKey = epochID.uuidString
        guard
            recommendationTasks[taskKey] == nil,
            recommendationRadioSession?.markEpochCandidateRequestStarted(epochID: epochID) == true
        else {
            recommendationLog("generation skipped=epoch request already active")
            return
        }
        let excludedVideoIDs = recommendationSeenVideoIDs
        let excludedSongIdentities = recommendationSeenSongIdentities
        let resolutionContext = RecommendationResolutionContext(
            sessionID: sessionID,
            epochID: epochID,
            upcomingCount: recommendationUpcomingCount,
            currentUpcomingCount: { [weak self] in
                self?.recommendationUpcomingCount ?? Int.max
            },
            isActive: { [weak self] in
                self?.isCurrentRecommendationEpoch(
                    sessionID: sessionID,
                    epochID: epochID
                ) == true
            }
        )
        let service = recommendationService

        recommendationLog(
            "epoch request anchor=\(anchor.cleanedArtist) - \(anchor.cleanedTitle)"
        )
        recommendationTasks[taskKey] = Task { [weak self] in
            do {
                let batch = try await service.recommendations(
                    for: anchor,
                    excludingVideoIDs: excludedVideoIDs,
                    excludingSongIdentities: excludedSongIdentities,
                    context: resolutionContext
                )
                guard let self else {
                    return
                }
                recommendationTasks[taskKey] = nil
                guard isCurrentRecommendationEpoch(sessionID: sessionID, epochID: epochID) else {
                    recommendationLog("stale epoch result ignored")
                    return
                }
                _ = recommendationRadioSession?.replaceReservoir(
                    batch.reservoirCandidates,
                    epochID: epochID
                )
                recommendationLog(
                    "reservoir available=\(recommendationRadioSession?.reservoirCount ?? 0)"
                )
                appendRecommendations(batch.recommendations, seed: seedTrack)
                beginRecommendationReservoirRefill(
                    sessionID: sessionID,
                    epochID: epochID,
                    seed: seedTrack
                )
            } catch is CancellationError {
                guard let self else {
                    return
                }
                recommendationTasks[taskKey] = nil
                recommendationLog("stale epoch result ignored")
            } catch {
                guard let self else {
                    return
                }
                recommendationTasks[taskKey] = nil
                recommendationLog(
                    "epoch request failed anchor=\(anchor.youtubeVideoID) "
                        + "error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func beginRecommendationReservoirRefill(
        sessionID: UUID,
        epochID: UUID,
        seed: PlayableTrack
    ) {
        let neededCount = max(
            0,
            recommendationUpcomingWatermark - recommendationUpcomingCount
        )
        recommendationLog("upcomingCount=\(recommendationUpcomingCount)")
        guard
            neededCount > 0,
            recommendationRefillTask == nil,
            var radioSession = recommendationRadioSession,
            radioSession.id == sessionID
        else {
            return
        }

        let candidates = radioSession.takeReservoirCandidates(
            upTo: RecommendationRadioPolicy.candidatePoolSize,
            epochID: epochID
        )
        recommendationRadioSession = radioSession
        guard !candidates.isEmpty else {
            beginEarlyRecommendationEpochIfNeeded(
                sessionID: sessionID,
                epochID: epochID
            )
            return
        }
        recommendationLog(
            "reservoir available=\(radioSession.reservoirCount + candidates.count) used=\(candidates.count)"
        )

        let service = recommendationService
        let excludedVideoIDs = recommendationSeenVideoIDs
        let excludedSongIdentities = recommendationSeenSongIdentities
        let resolutionContext = RecommendationResolutionContext(
            sessionID: sessionID,
            epochID: epochID,
            upcomingCount: recommendationUpcomingCount,
            currentUpcomingCount: { [weak self] in
                self?.recommendationUpcomingCount ?? Int.max
            },
            isActive: { [weak self] in
                self?.isCurrentRecommendationEpoch(
                    sessionID: sessionID,
                    epochID: epochID
                ) == true
            }
        )
        let refillID = UUID()
        recommendationRefillID = refillID
        recommendationRefillTask = Task { [weak self] in
            do {
                let resolution = try await service.resolveReservoirCandidates(
                    candidates,
                    desiredCount: neededCount,
                    excludingVideoIDs: excludedVideoIDs,
                    excludingSongIdentities: excludedSongIdentities,
                    context: resolutionContext
                )
                guard let self else {
                    return
                }
                if recommendationRefillID == refillID {
                    recommendationRefillTask = nil
                    recommendationRefillID = nil
                }
                guard isCurrentRecommendationEpoch(sessionID: sessionID, epochID: epochID) else {
                    recommendationLog("stale reservoir result ignored")
                    return
                }
                _ = recommendationRadioSession?.returnUnusedReservoirCandidates(
                    resolution.unusedCandidates,
                    epochID: epochID
                )
                appendRecommendations(resolution.recommendations, seed: seed)
                if resolution.exhaustedCurrentPaths,
                   resolution.recommendations.isEmpty {
                    beginEarlyRecommendationEpochIfNeeded(
                        sessionID: sessionID,
                        epochID: epochID
                    )
                }
            } catch is CancellationError {
                guard let self else {
                    return
                }
                if recommendationRefillID == refillID {
                    recommendationRefillTask = nil
                    recommendationRefillID = nil
                }
                recommendationLog("stale reservoir result ignored")
            } catch {
                guard let self else {
                    return
                }
                if recommendationRefillID == refillID {
                    recommendationRefillTask = nil
                    recommendationRefillID = nil
                }
                recommendationLog("reservoir resolution failed=\(error.localizedDescription)")
            }
        }
    }

    private func beginEarlyRecommendationEpochIfNeeded(
        sessionID: UUID,
        epochID: UUID
    ) {
        guard
            recommendationRefillTask == nil,
            recommendationTasks[epochID.uuidString] == nil,
            recommendationUpcomingCount == 0,
            isCurrentRecommendationEpoch(sessionID: sessionID, epochID: epochID),
            let playableTrack = currentPlayableTrack,
            var radioSession = recommendationRadioSession,
            radioSession.id == sessionID,
            radioSession.epoch.id == epochID
        else {
            return
        }
        let videoID = normalizedVideoID(playableTrack.youtubeVideoID)
        guard !videoID.isEmpty else {
            return
        }
        let sourceTrack = currentTrack.flatMap {
            normalizedVideoID($0.youtubeVideoID) == videoID ? $0 : nil
        }
        let anchor = recommendationSeed(
            videoID: videoID,
            playableTrack: playableTrack,
            sourceTrack: sourceTrack
        )
        guard case .startNewEpoch(let newEpochID, let newAnchor)? =
            radioSession.startEarlyEpochIfPossible(anchor: anchor)
        else {
            return
        }
        recommendationRadioSession = radioSession
        recommendationLog("earlyEpochRollover=true reason=reservoirExhausted")
        beginRecommendationEpoch(
            anchor: newAnchor,
            epochID: newEpochID,
            sessionID: sessionID,
            seedTrack: playableTrack
        )
    }

    private func isCurrentRecommendationEpoch(sessionID: UUID, epochID: UUID) -> Bool {
        RecommendationSessionValidity.accepts(
            expectedToken: sessionID,
            activeToken: recommendationSessionID,
            origin: playbackOrigin
        ) && recommendationRadioSession?.epoch.id == epochID
    }

    private var recommendationUpcomingCount: Int {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return 0
        }
        let totalUpcoming = max(0, queue.count - currentIndex - 1)
        // Exclude manual-queue items so they don't suppress radio refill.
        return max(0, totalUpcoming - manualQueueCount)
    }

    private func appendRecommendations(
        _ results: [ResolvedRecommendation],
        seed: PlayableTrack
    ) {
        let queueCountBeforeInsertion = queue.count
        recommendationLog("queue before=\(queueCountBeforeInsertion)")
        let uniqueResults = results.filter { result in
            let videoID = normalizedVideoID(result.youtubeResult.youtubeVideoID)
            guard
                !videoID.isEmpty,
                !recommendationSeenVideoIDs.contains(videoID),
                !recommendationSeenSongIdentities.contains(result.songIdentity)
            else {
                return false
            }
            recordSeenRecommendationVideoID(videoID)
            recommendationSeenSongIdentities.insert(result.songIdentity)
            return true
        }
        let newTracks = uniqueResults.map(transientRecommendationTrack(for:))
        for result in uniqueResults {
            let videoID = normalizedVideoID(result.youtubeResult.youtubeVideoID)
            recommendationTransportMetadata[videoID] = result.transportMetadata
            recommendationRadioSession?.recordSeen(result.songIdentity)
        }
        if let radioSession = recommendationRadioSession {
            recommendationSeenSongIdentities = radioSession.globalPlayedSongIdentities
        }

        guard !newTracks.isEmpty else {
            recommendationLog("queue insertion skipped=no unique resolved recommendations")
            recommendationLog("queue after=\(queue.count)")
            recommendationLog("hasNextTrack=\(hasNextTrack)")
            return
        }

        if currentIndex == nil {
            queue = [transientRecommendationTrack(for: seed)]
            currentIndex = queue.startIndex
        }

        guard let currentIndex, queue.indices.contains(currentIndex) else {
            recommendationLog("queue insertion skipped=invalid current queue index")
            return
        }

        let historyStart = max(queue.startIndex, currentIndex - recommendationHistoryLimit + 1)
        let history = Array(queue[historyStart...currentIndex])
        let existingUpcoming: [Track]
        if currentIndex < queue.index(before: queue.endIndex) {
            existingUpcoming = Array(queue[queue.index(after: currentIndex)...])
        } else {
            existingUpcoming = []
        }

        // Separate the manual-queue items (front of upcoming) from the
        // auto-upcoming items so radio additions never displace them.
        let clampedManualCount = min(manualQueueCount, existingUpcoming.count)
        let manualItems = Array(existingUpcoming.prefix(clampedManualCount))
        let autoItems = Array(existingUpcoming.dropFirst(clampedManualCount))

        let autoUpcoming = Array(
            (autoItems + newTracks)
                .prefix(recommendationUpcomingLimit)
        )
        let upcoming = manualItems + autoUpcoming

        queue = history + upcoming
        self.currentIndex = history.count - 1
        // manualQueueCount is unchanged — the manual items are still there.
        let retainedVideoIDs = Set(queue.map { normalizedVideoID($0.youtubeVideoID) })
        recommendationTransportMetadata = recommendationTransportMetadata.filter {
            retainedVideoIDs.contains($0.key)
        }
        playbackOrigin = .recommendations
#if os(iOS)
        updateRemoteQueueCommands()
#endif
        refreshQueuePredictionsAfterMutation()
        recommendationLog(
            "selected=\(uniqueResults.map(\.youtubeResult.youtubeVideoID).joined(separator: ","))"
        )
        recommendationLog("queue after=\(queue.count)")
        recommendationLog("hasNextTrack=\(hasNextTrack)")
        recommendationLog("upcomingCount=\(recommendationUpcomingCount)")
    }

    private func recordSeenRecommendationVideoID(_ videoID: String) {
        let videoID = normalizedVideoID(videoID)
        guard !videoID.isEmpty, recommendationSeenVideoIDs.insert(videoID).inserted else {
            return
        }
        recommendationSeenVideoIDOrder.append(videoID)
        while recommendationSeenVideoIDOrder.count > RecommendationRadioPolicy.sessionIdentityLimit {
            recommendationSeenVideoIDs.remove(recommendationSeenVideoIDOrder.removeFirst())
        }
    }

    private func transientRecommendationTrack(
        for result: ResolvedRecommendation
    ) -> Track {
        Track(
            title: result.title,
            youtubeURL: youtubeWatchURL(for: result.youtubeResult.youtubeVideoID),
            youtubeVideoID: result.youtubeResult.youtubeVideoID,
            channelTitle: result.artist,
            thumbnailURL: result.youtubeResult.thumbnailURL,
            duration: result.youtubeResult.duration,
            metadataLastRefreshed: .now
        )
    }

    private func transientRecommendationTrack(for track: PlayableTrack) -> Track {
        Track(
            title: track.title,
            youtubeURL: youtubeWatchURL(for: track.youtubeVideoID),
            youtubeVideoID: track.youtubeVideoID,
            channelTitle: track.channelTitle,
            thumbnailURL: track.thumbnailURL,
            duration: track.duration,
            metadataLastRefreshed: .now,
            playbackStartTime: track.playbackStartTime,
            playbackEndTime: track.playbackEndTime
        )
    }

    private func youtubeWatchURL(for videoID: String) -> URL {
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url!
    }

    private func recommendationLog(_ message: String) {
#if DEBUG
        print("[Recommendations] \(message)")
#endif
    }

    private func recordTrackPlaybackStartIfNeeded(requestID: UUID) {
        guard
            !isTrimPreviewActive,
            lastRecordedTrackPlaybackRequestID != requestID
        else {
            return
        }

        lastRecordedTrackPlaybackRequestID = requestID
        currentTrack?.playCount += 1
        currentTrack?.lastPlayedAt = .now
    }

    private func recordListeningHistoryStartIfNeeded(
        player: AVPlayer,
        requestID: UUID
    ) {
        guard
            !isTrimPreviewActive,
            let playableTrack = currentPlayableTrack,
            let origin = playbackOrigin
        else {
            return
        }

        let videoID = normalizedVideoID(playableTrack.youtubeVideoID)
        let seed = recommendationSeed(
            videoID: videoID,
            playableTrack: playableTrack,
            sourceTrack: currentTrack
        )
        let identity = seed.songIdentity
        let snapshot = ListeningHistorySnapshot(
            youtubeVideoID: videoID,
            identity: identity,
            artworkURL: playableTrack.thumbnailURL,
            source: ListeningHistoryPlaybackSource(origin),
            genres: currentTrack?.cachedGenreTags ?? []
        )
        listeningHistoryRecorder?.confirmPlayback(
            requestID: requestID,
            snapshot: snapshot,
            mediaTime: player.currentTime().seconds
        )
    }

    private func beginActiveListeningPeriod(
        for player: AVPlayer,
        requestID: UUID
    ) {
        guard
            !isTrimPreviewActive,
            activeListeningPeriod?.requestID != requestID,
            player.currentTime().seconds.isFinite,
            player.currentTime().seconds >= 0
        else {
            return
        }

        finishActiveListeningPeriod()

        let startedAt = player.currentTime().seconds
        guard startedAt.isFinite, startedAt >= 0 else {
            return
        }

        activeListeningPeriod = ActiveListeningPeriod(
            requestID: requestID,
            track: currentTrack,
            player: player,
            startedAt: startedAt
        )
        listeningHistoryRecorder?.beginSegment(
            requestID: requestID,
            mediaTime: startedAt
        )
    }

    private func finishActiveListeningPeriod() {
        guard let activeListeningPeriod else {
            return
        }

        self.activeListeningPeriod = nil

        let finishedAt = activeListeningPeriod.player.currentTime().seconds
        guard finishedAt.isFinite, finishedAt >= activeListeningPeriod.startedAt else {
            return
        }

        listeningHistoryRecorder?.closeSegment(
            requestID: activeListeningPeriod.requestID,
            mediaTime: finishedAt
        )
        if let track = activeListeningPeriod.track {
            track.totalListenedDuration += finishedAt - activeListeningPeriod.startedAt
            scheduleGenreLookupIfNeeded(for: track)
        }
    }

    private func scheduleGenreLookupIfNeeded(for track: Track) {
        guard
            !isTrimPreviewActive,
            track.modelContext != nil,
            track.totalListenedDuration >= GenreStatsPolicy.meaningfulListeningThreshold
        else {
#if DEBUG
            if track.totalListenedDuration < GenreStatsPolicy.meaningfulListeningThreshold {
                print("[GenreStats] lookup skipped=insufficient listening")
            }
#endif
            return
        }

        let seed = RecommendationSeed(
            youtubeVideoID: track.youtubeVideoID,
            rawTitle: track.title,
            displayedArtist: track.displayArtist,
            sourceChannel: track.channelTitle,
            userArtistOverride: track.userArtistOverride
        )
        let identity = seed.songIdentity
        guard !identity.artist.isEmpty, !identity.title.isEmpty else {
            return
        }

        let cacheState = track.genreTagCacheState
        let service = genreTagService
        Task { [weak self, track] in
            guard let self else {
                return
            }

            let result = await genreLookupCoordinator.lookup(
                cacheState: cacheState,
                cacheKey: identity.cacheKey,
                artist: identity.artist,
                title: identity.title,
                fetcher: service
            )
            guard !Task.isCancelled, track.modelContext != nil else {
                return
            }

            switch result {
            case .success(let genres):
                track.storeGenreTags(genres)
#if DEBUG
                print("[GenreStats] cached genres=\(genres.joined(separator: ", "))")
#endif
            case .cached:
#if DEBUG
                print("[GenreStats] cache hit track=\(identity.title)")
#endif
            case .failed:
                track.genreTagsLastAttemptAt = .now
#if DEBUG
                print("[GenreStats] lookup failed=optional enrichment")
#endif
            case .inFlight, .retryDeferred:
                break
            }
        }
    }

    private func activateAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback)
        try audioSession.setActive(true)
    }

    private func invalidateCurrentRequest() {
        activeRequestID = nil
        playbackTask?.cancel()
        playbackTask = nil
    }

    private func clearPlayer() {
        finishActiveListeningPeriod()
        listeningHistoryRecorder?.finalize(requestID: activeRequestID)
        removeTrimPreviewTimeObserver()
        removeListeningCheckpointObserver()

        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }

        itemStatusObservation = nil
        timeControlStatusObservation = nil

        if let playbackBoundaryObserver {
            player?.removeTimeObserver(playbackBoundaryObserver)
            self.playbackBoundaryObserver = nil
        }

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func installListeningCheckpointObserver(
        on player: AVPlayer,
        requestID: UUID
    ) {
        removeListeningCheckpointObserver()
        let interval = CMTime(
            seconds: ListeningHistoryPolicy.checkpointInterval,
            preferredTimescale: 600
        )
        let managerReference = WeakReference(self)
        let token = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    self.isActive(requestID),
                    self.player === player,
                    player.timeControlStatus == .playing,
                    self.activeListeningPeriod?.requestID == requestID
                else {
                    return
                }
                self.finishActiveListeningPeriod()
                self.beginActiveListeningPeriod(for: player, requestID: requestID)
            }
        }
        listeningCheckpointObserver = (player, token)
    }

    private func removeListeningCheckpointObserver() {
        guard let listeningCheckpointObserver else {
            return
        }
        listeningCheckpointObserver.player.removeTimeObserver(
            listeningCheckpointObserver.token
        )
        self.listeningCheckpointObserver = nil
    }

    private func isActive(_ requestID: UUID) -> Bool {
        activeRequestID == requestID
    }

    private func updateMetrics(_ update: (inout StartupMetrics) -> Void) {
        guard var metrics = startupMetrics else {
            return
        }

        update(&metrics)
        startupMetrics = metrics
    }

    private var currentTime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func logTiming(_ label: String, seconds: TimeInterval, videoID: String) {
        log("\(label) for \(videoID): \(String(format: "%.3f", seconds)) s")
    }

    private func log(_ message: String) {
        print("[Playback] \(message)")
    }

    private func dashboardLog(_ message: String) {
#if DEBUG
        print("[DashboardWarmup] \(message)")
#endif
    }

    private func playlistLog(_ message: String) {
#if DEBUG
        print("[PlaylistWarmup] \(message)")
#endif
    }

    private func searchPreResolveLog(_ message: String) {
#if DEBUG
        print("[SearchPreResolve] \(message)")
#endif
    }

#if DEBUG
    /// Seed internal queue state for unit tests only. Does NOT start playback.
    func seedQueueForTesting(
        tracks: [Track],
        currentIndex: Int,
        manualQueueCount: Int = 0
    ) {
        self.queue = tracks
        self.currentIndex = currentIndex
        self.manualQueueCount = manualQueueCount
        // Set a fake currentPlayableTrack so queue mutation guards pass.
        if tracks.indices.contains(currentIndex) {
            self.currentPlayableTrack = PlayableTrack(track: tracks[currentIndex])
        }
    }
#endif

    private func queueLog(_ message: String) {
#if DEBUG
        print("[Queue] \(message)")
#endif
    }

    private static func errorMessage(for error: Error) -> String {
        if
            let localizedError = error as? LocalizedError,
            let description = localizedError.errorDescription,
            !description.isEmpty
        {
            return description
        }

        return error.localizedDescription
    }

    private static func redactedDiagnosticText(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s<>\"']+"#
        ) else {
            return "unavailable"
        }

        var redactedText = text
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: fullRange)

        for match in matches.reversed() {
            guard
                let textRange = Range(match.range, in: redactedText),
                let originalRange = Range(match.range, in: text)
            else {
                continue
            }

            let uri = String(text[originalRange])
            let host = URLComponents(string: uri)?.host
            let replacement = host.map { "<URI host=\($0)>" } ?? "<URI redacted>"
            redactedText.replaceSubrange(textRange, with: replacement)
        }

        return redactedText
    }
}
