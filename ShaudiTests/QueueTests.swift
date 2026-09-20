import XCTest
@testable import Shaudi

/// Unit tests for the user-manageable playback queue feature.
/// All tests run on MainActor because PlaybackManager is isolated to MainActor.
@MainActor
final class QueueTests: XCTestCase {

    // MARK: - Helpers

    private func makeTrack(id: String = UUID().uuidString) -> Track {
        Track(
            title: "Track \(id)",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!,
            youtubeVideoID: id
        )
    }

    private func makeManager(
        tracks: [Track],
        currentIndex: Int = 0,
        manualQueueCount: Int = 0
    ) -> PlaybackManager {
        let manager = PlaybackManager()
        manager.seedQueueForTesting(
            tracks: tracks,
            currentIndex: currentIndex,
            manualQueueCount: manualQueueCount
        )
        return manager
    }

    // MARK: - 1. playNext inserts immediately after current track

    func testPlayNextInsertsAtFrontOfUpcoming() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "t1")
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t0, t1, t2], currentIndex: 0)

        let newTrack = makeTrack(id: "new")
        manager.playNext(newTrack)

        let upcoming = manager.upcomingQueueTracks
        XCTAssertEqual(upcoming.first?.youtubeVideoID, "new",
                       "playNext should make the new track immediately next")
        XCTAssertEqual(upcoming[1].youtubeVideoID, "t1",
                       "Original next track should be displaced to second upcoming slot")
    }

    // MARK: - 2. addToQueue appends after manual section

    func testAddToQueueAppendsAfterManualSection() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "t1")
        let manager = makeManager(tracks: [t0, t1], currentIndex: 0)

        manager.addToQueue(makeTrack(id: "first"))
        manager.addToQueue(makeTrack(id: "second"))

        let upcoming = manager.upcomingQueueTracks
        XCTAssertEqual(upcoming[0].youtubeVideoID, "first")
        XCTAssertEqual(upcoming[1].youtubeVideoID, "second",
                       "addToQueue should maintain insertion order")
    }

    // MARK: - 3. Multiple playNext puts most-recently-added track at front

    func testMultiplePlayNextMostRecentlyAddedIsFirst() {
        let t0 = makeTrack(id: "t0")
        let manager = makeManager(tracks: [t0], currentIndex: 0)

        manager.playNext(makeTrack(id: "A"))
        manager.playNext(makeTrack(id: "B"))

        let upcoming = manager.upcomingQueueTracks
        XCTAssertEqual(upcoming.first?.youtubeVideoID, "B",
                       "Most recent playNext should be immediately next")
        XCTAssertEqual(upcoming[1].youtubeVideoID, "A")
    }

    // MARK: - 4. manualQueueCount tracks correctly after playNext

    func testManualQueueCountAfterPlayNext() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "t1")
        let manager = makeManager(tracks: [t0, t1], currentIndex: 0)

        manager.playNext(makeTrack(id: "A"))
        manager.playNext(makeTrack(id: "B"))

        XCTAssertEqual(manager.manualQueueCount, 2)
    }

    // MARK: - 5. manualQueueCount tracks correctly after addToQueue

    func testManualQueueCountAfterAddToQueue() {
        let t0 = makeTrack(id: "t0")
        let manager = makeManager(tracks: [t0], currentIndex: 0)

        manager.addToQueue(makeTrack(id: "A"))
        manager.addToQueue(makeTrack(id: "B"))

        XCTAssertEqual(manager.manualQueueCount, 2)
    }

    // MARK: - 6. upcomingQueueTracks empty when no upcoming tracks

    func testUpcomingQueueTracksEmptyAtEndOfQueue() {
        let t0 = makeTrack(id: "t0")
        let manager = makeManager(tracks: [t0], currentIndex: 0)

        XCTAssertTrue(manager.upcomingQueueTracks.isEmpty)
    }

    // MARK: - 7. upcomingQueueTracks reflects all tracks after current

    func testUpcomingQueueTracksReflectsAllAfterCurrent() {
        let tracks = (0..<5).map { makeTrack(id: "t\($0)") }
        let manager = makeManager(tracks: tracks, currentIndex: 2)

        XCTAssertEqual(manager.upcomingQueueTracks.count, 2)
        XCTAssertEqual(manager.upcomingQueueTracks[0].youtubeVideoID, "t3")
        XCTAssertEqual(manager.upcomingQueueTracks[1].youtubeVideoID, "t4")
    }

    // MARK: - 8. removeFromQueue removes the correct track

    func testRemoveFromQueueRemovesCorrectTrack() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "t1")
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t0, t1, t2], currentIndex: 0)

        manager.removeFromQueue(upcomingIndex: 0) // remove t1

        XCTAssertEqual(manager.upcomingQueueTracks.count, 1)
        XCTAssertEqual(manager.upcomingQueueTracks[0].youtubeVideoID, "t2")
    }

    // MARK: - 9. removeFromQueue decrements manualQueueCount if removing manual item

    func testRemoveManualItemDecrementsManualQueueCount() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "t1")
        let manager = makeManager(tracks: [t0, t1], currentIndex: 0)

        manager.playNext(makeTrack(id: "manual"))
        XCTAssertEqual(manager.manualQueueCount, 1)

        manager.removeFromQueue(upcomingIndex: 0) // remove the manual item
        XCTAssertEqual(manager.manualQueueCount, 0)
    }

    // MARK: - 10. removeFromQueue does not decrement count for auto items

    func testRemoveAutoItemDoesNotDecrementManualQueueCount() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "t1")
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t0, t1, t2], currentIndex: 0, manualQueueCount: 1)

        // t1 is manual, t2 is auto. Remove t2 (upcomingIndex 1).
        manager.removeFromQueue(upcomingIndex: 1)
        XCTAssertEqual(manager.manualQueueCount, 1, "Removing auto item should not change manual count")
    }

    // MARK: - 11. removeFromQueue out of bounds is a no-op

    func testRemoveFromQueueOutOfBoundsIsNoOp() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "t1")
        let manager = makeManager(tracks: [t0, t1], currentIndex: 0)

        let beforeCount = manager.upcomingQueueTracks.count
        manager.removeFromQueue(upcomingIndex: 99) // out of bounds
        XCTAssertEqual(manager.upcomingQueueTracks.count, beforeCount)
    }

    // MARK: - 12. moveQueue: move one item forward

    func testMoveQueueOneItemForward() {
        let t0 = makeTrack(id: "current")
        let t1 = makeTrack(id: "u0")
        let t2 = makeTrack(id: "u1")
        let t3 = makeTrack(id: "u2")
        let manager = makeManager(tracks: [t0, t1, t2, t3], currentIndex: 0)

        // Move u0 from index 0 to index 2 (between u1 and u2)
        manager.moveQueue(from: IndexSet([0]), to: 2)

        let upcoming = manager.upcomingQueueTracks
        XCTAssertEqual(upcoming.map(\.youtubeVideoID), ["u1", "u0", "u2"])
        XCTAssertEqual(manager.currentPlayableTrack?.youtubeVideoID, "current",
                       "Current playing item must remain untouched")
    }

    // MARK: - 12b. moveQueue: move one item backward

    func testMoveQueueOneItemBackward() {
        let t0 = makeTrack(id: "current")
        let t1 = makeTrack(id: "u0")
        let t2 = makeTrack(id: "u1")
        let t3 = makeTrack(id: "u2")
        let manager = makeManager(tracks: [t0, t1, t2, t3], currentIndex: 0)

        // Move u2 from index 2 to index 0 (to the top)
        manager.moveQueue(from: IndexSet([2]), to: 0)

        let upcoming = manager.upcomingQueueTracks
        XCTAssertEqual(upcoming.map(\.youtubeVideoID), ["u2", "u0", "u1"])
        XCTAssertEqual(manager.currentPlayableTrack?.youtubeVideoID, "current")
    }

    // MARK: - 12c. moveQueue: move first upcoming item to end

    func testMoveQueueFirstUpcomingToEnd() {
        let t0 = makeTrack(id: "current")
        let t1 = makeTrack(id: "u0")
        let t2 = makeTrack(id: "u1")
        let t3 = makeTrack(id: "u2")
        let manager = makeManager(tracks: [t0, t1, t2, t3], currentIndex: 0)

        // Move u0 from index 0 to destination 3 (end of upcoming list)
        manager.moveQueue(from: IndexSet([0]), to: 3)

        let upcoming = manager.upcomingQueueTracks
        XCTAssertEqual(upcoming.map(\.youtubeVideoID), ["u1", "u2", "u0"])
        XCTAssertEqual(manager.currentPlayableTrack?.youtubeVideoID, "current")
    }

    // MARK: - 12d. moveQueue: move last upcoming item to front

    func testMoveQueueLastUpcomingToFront() {
        let t0 = makeTrack(id: "current")
        let t1 = makeTrack(id: "u0")
        let t2 = makeTrack(id: "u1")
        let t3 = makeTrack(id: "u2")
        let manager = makeManager(tracks: [t0, t1, t2, t3], currentIndex: 0)

        // Move u2 from index 2 to index 0
        manager.moveQueue(from: IndexSet([2]), to: 0)

        let upcoming = manager.upcomingQueueTracks
        XCTAssertEqual(upcoming.map(\.youtubeVideoID), ["u2", "u0", "u1"])
        XCTAssertEqual(manager.currentPlayableTrack?.youtubeVideoID, "current")
    }

    // MARK: - 12e. moveQueue: move multiple selected offsets

    func testMoveQueueMultipleSelectedOffsets() {
        let t0 = makeTrack(id: "current")
        let t1 = makeTrack(id: "u0")
        let t2 = makeTrack(id: "u1")
        let t3 = makeTrack(id: "u2")
        let t4 = makeTrack(id: "u3")
        let manager = makeManager(tracks: [t0, t1, t2, t3, t4], currentIndex: 0)

        // Move [u0, u2] (offsets 0 and 2) to destination 4 (end)
        manager.moveQueue(from: IndexSet([0, 2]), to: 4)

        let upcoming = manager.upcomingQueueTracks
        XCTAssertEqual(upcoming.map(\.youtubeVideoID), ["u1", "u3", "u0", "u2"])
        XCTAssertEqual(manager.currentPlayableTrack?.youtubeVideoID, "current")
    }

    // MARK: - 12f. moveQueue: out of bounds or negative destinations are safe no-ops

    func testMoveQueueOutOfBoundsIsSafeNoOp() {
        let t0 = makeTrack(id: "current")
        let t1 = makeTrack(id: "u0")
        let t2 = makeTrack(id: "u1")
        let manager = makeManager(tracks: [t0, t1, t2], currentIndex: 0)

        manager.moveQueue(from: IndexSet([0]), to: 99)
        XCTAssertEqual(manager.upcomingQueueTracks.map(\.youtubeVideoID), ["u0", "u1"])

        manager.moveQueue(from: IndexSet([0]), to: -1)
        XCTAssertEqual(manager.upcomingQueueTracks.map(\.youtubeVideoID), ["u0", "u1"])

        manager.moveQueue(from: IndexSet([99]), to: 0)
        XCTAssertEqual(manager.upcomingQueueTracks.map(\.youtubeVideoID), ["u0", "u1"])
    }

    // MARK: - 13. jumpToQueueItem updates currentIndex correctly

    func testJumpToQueueItemUpdatesCurrentIndex() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "t1")
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t0, t1, t2], currentIndex: 0)

        manager.jumpToQueueItem(upcomingIndex: 1) // jump to t2

        XCTAssertEqual(manager.currentIndex, 2)
    }

    // MARK: - 14. Queue ownership survives jumps and mixed reorders

    func testJumpingToSecondManualItemLeavesNoUpcomingManualItems() {
        let current = makeTrack(id: "current")
        let manualA = makeTrack(id: "manual-a")
        let manualB = makeTrack(id: "manual-b")
        let automaticC = makeTrack(id: "automatic-c")
        let manager = makeManager(
            tracks: [current, manualA, manualB, automaticC],
            currentIndex: 0,
            manualQueueCount: 2
        )

        manager.jumpToQueueItem(upcomingIndex: 1)

        XCTAssertEqual(manager.queue[manager.currentIndex!].youtubeVideoID, "manual-b")
        XCTAssertEqual(manager.upcomingQueueTracks.map(\.youtubeVideoID), ["automatic-c"])
        XCTAssertEqual(
            manager.manualQueueCount,
            0,
            "The manual item that became current is no longer an upcoming manual item"
        )
    }

    func testJumpingPastManualPrefixIntoAutomaticItemConsumesAllManualOwnership() {
        let current = makeTrack(id: "current")
        let manualA = makeTrack(id: "manual-a")
        let manualB = makeTrack(id: "manual-b")
        let automaticC = makeTrack(id: "automatic-c")
        let automaticD = makeTrack(id: "automatic-d")
        let manager = makeManager(
            tracks: [current, manualA, manualB, automaticC, automaticD],
            currentIndex: 0,
            manualQueueCount: 2
        )

        manager.jumpToQueueItem(upcomingIndex: 2)

        XCTAssertEqual(manager.queue[manager.currentIndex!].youtubeVideoID, "automatic-c")
        XCTAssertEqual(manager.upcomingQueueTracks.map(\.youtubeVideoID), ["automatic-d"])
        XCTAssertEqual(manager.manualQueueCount, 0)
    }

    func testAutomaticItemMovedBeforeManualItemRemainsAutomaticForFeedbackRemoval() {
        let blockedIdentity = SongIdentity(artist: "Blocked Automatic Artist", title: "Blocked Auto")
        let manager = makeRecommendationManager(
            upcoming: [
                ("manual-a", SongIdentity(artist: "Manual Artist", title: "Manual A")),
                ("automatic-blocked", blockedIdentity),
                ("automatic-other", SongIdentity(artist: "Other Artist", title: "Other Auto"))
            ],
            manualQueueCount: 1
        )

        manager.moveQueue(from: IndexSet(integer: 1), to: 0)
        recordArtistExclusion(blockedIdentity, on: manager)

        XCTAssertEqual(
            manager.upcomingQueueTracks.map(\.youtubeVideoID),
            ["manual-a", "automatic-other"],
            "Moving an automatic item must not grant it manual-queue protection"
        )
        XCTAssertEqual(manager.manualQueueCount, 1)
    }

    func testManualItemMovedAfterAutomaticItemsRemainsManualForFeedbackRemoval() {
        let manualIdentity = SongIdentity(artist: "Blocked Manual Artist", title: "Manual A")
        let manager = makeRecommendationManager(
            upcoming: [
                ("manual-a", manualIdentity),
                ("automatic-c", SongIdentity(artist: "Automatic C Artist", title: "Automatic C")),
                ("automatic-d", SongIdentity(artist: "Automatic D Artist", title: "Automatic D"))
            ],
            manualQueueCount: 1
        )

        manager.moveQueue(from: IndexSet(integer: 0), to: 3)
        recordArtistExclusion(manualIdentity, on: manager)

        XCTAssertEqual(
            manager.upcomingQueueTracks.map(\.youtubeVideoID),
            ["automatic-c", "automatic-d", "manual-a"],
            "Manual provenance must follow the item when it is reordered"
        )
        XCTAssertEqual(manager.manualQueueCount, 1)
    }

    func testRecommendationRefillCountAfterJumpCountsRemainingAutomaticItem() {
        let current = makeTrack(id: "current")
        let manualA = makeTrack(id: "manual-a")
        let manualB = makeTrack(id: "manual-b")
        let automaticC = makeTrack(id: "automatic-c")
        let manager = makeManager(
            tracks: [current, manualA, manualB, automaticC],
            currentIndex: 0,
            manualQueueCount: 2
        )

        manager.jumpToQueueItem(upcomingIndex: 1)

        XCTAssertEqual(
            manager.recommendationUpcomingCountForTesting,
            1,
            "The production refill count must recognize Automatic C as automatic"
        )
    }

    func testFeedbackAfterJumpRemovesRemainingAutomaticRecommendation() {
        let automaticIdentity = SongIdentity(
            artist: "Jump Feedback Artist",
            title: "Automatic C"
        )
        let manager = makeRecommendationManager(
            upcoming: [
                ("manual-a", SongIdentity(artist: "Manual Artist A", title: "Manual A")),
                ("manual-b", SongIdentity(artist: "Manual Artist B", title: "Manual B")),
                ("automatic-c", automaticIdentity)
            ],
            manualQueueCount: 2
        )

        manager.jumpToQueueItem(upcomingIndex: 1)
        recordArtistExclusion(automaticIdentity, on: manager)

        XCTAssertTrue(
            manager.upcomingQueueTracks.isEmpty,
            "The remaining automatic recommendation must not be protected by stale manual ownership"
        )
    }

    // MARK: - 15. jumpToQueueItem out of bounds is a no-op

    func testJumpToQueueItemOutOfBoundsIsNoOp() {
        let t0 = makeTrack(id: "t0")
        let manager = makeManager(tracks: [t0], currentIndex: 0)

        manager.jumpToQueueItem(upcomingIndex: 5) // nothing there
        XCTAssertEqual(manager.currentIndex, 0, "Index should remain unchanged")
    }

    // MARK: - 16. Same song can be queued multiple times

    func testSameSongCanBeQueuedMultipleTimes() {
        let t0 = makeTrack(id: "t0")
        let repeated = makeTrack(id: "repeat")
        let manager = makeManager(tracks: [t0], currentIndex: 0)

        manager.addToQueue(repeated)
        manager.addToQueue(repeated)
        manager.addToQueue(repeated)

        XCTAssertEqual(manager.upcomingQueueTracks.count, 3)
        XCTAssertEqual(manager.manualQueueCount, 3)
    }

    // MARK: - 17. manualQueueCount resets to zero after seedQueueForTesting with no manual count

    func testManualQueueCountResetsOnFreshSeed() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "t1")
        let manager = makeManager(tracks: [t0, t1], currentIndex: 0, manualQueueCount: 3)

        // Re-seed as a completely fresh queue
        manager.seedQueueForTesting(tracks: [t0], currentIndex: 0)
        XCTAssertEqual(manager.manualQueueCount, 0)
    }

    // MARK: - 18. addToQueue inserts AFTER manual section (before auto items)

    func testAddToQueueInsertsAfterManualBeforeAuto() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "auto1")
        let t2 = makeTrack(id: "auto2")
        // Set up: 0 manual items, 2 auto items
        let manager = makeManager(tracks: [t0, t1, t2], currentIndex: 0, manualQueueCount: 0)

        manager.addToQueue(makeTrack(id: "manual1"))

        let upcoming = manager.upcomingQueueTracks
        // manual1 goes at position 0 (before auto items)
        XCTAssertEqual(upcoming[0].youtubeVideoID, "manual1")
        XCTAssertEqual(upcoming[1].youtubeVideoID, "auto1")
        XCTAssertEqual(upcoming[2].youtubeVideoID, "auto2")
    }

    // MARK: - 19. playNext with no active playback is a no-op

    func testPlayNextWithNoActivePlaybackIsNoOp() {
        let manager = PlaybackManager() // no seeding — no currentPlayableTrack
        let track = makeTrack(id: "t0")

        manager.playNext(track)

        XCTAssertTrue(manager.queue.isEmpty, "playNext should be no-op when nothing is playing")
        XCTAssertEqual(manager.manualQueueCount, 0)
    }

    // MARK: - 20. manualQueueCount does not go below zero on excess removes

    func testManualQueueCountDoesNotGoBelowZero() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "t1")
        let manager = makeManager(tracks: [t0, t1], currentIndex: 0, manualQueueCount: 0)

        // Remove the one auto item — manualQueueCount stays 0 (not -1)
        manager.removeFromQueue(upcomingIndex: 0)
        XCTAssertEqual(manager.manualQueueCount, 0)
    }

    // MARK: - Per-occurrence provenance regressions

    func testDuplicateSongOccurrencesRetainIndependentProvenanceThroughReorderAndRemoval() {
        let current = makeTrack(id: "current")
        let duplicate = makeTrack(id: "duplicate")
        let duplicateIdentity = SongIdentity(
            artist: "Duplicate Artist",
            title: "Duplicate Song"
        )
        let manager = PlaybackManager()
        manager.seedRecommendationQueueForTesting(
            tracks: [current, duplicate, duplicate],
            currentIndex: 0,
            manualQueueCount: 1,
            identitiesByVideoID: ["duplicate": duplicateIdentity]
        )

        manager.moveQueue(from: IndexSet(integer: 1), to: 0)
        recordArtistExclusion(duplicateIdentity, on: manager)

        XCTAssertEqual(manager.upcomingQueueTracks.count, 1)
        XCTAssertTrue(manager.upcomingQueueTracks[0] === duplicate)
        XCTAssertEqual(
            manager.manualQueueCount,
            1,
            "Removing the automatic duplicate must leave the manual occurrence manual"
        )

        manager.removeFromQueue(upcomingIndex: 0)
        XCTAssertTrue(manager.upcomingQueueTracks.isEmpty)
        XCTAssertEqual(manager.manualQueueCount, 0)
    }

    func testRecommendationAppendCreatesAutomaticOccurrence() {
        let current = makeTrack(id: "current")
        let manager = makeManager(tracks: [current])
        let recommendation = makeResolvedRecommendation(
            artist: "Radio Artist",
            title: "Radio Song",
            videoID: "radio-song"
        )

        manager.appendRecommendationsForTesting(
            [recommendation],
            seed: PlayableTrack(track: current)
        )

        XCTAssertEqual(manager.upcomingQueueTracks.map(\.youtubeVideoID), ["radio-song"])
        XCTAssertEqual(manager.manualQueueCount, 0)
        XCTAssertEqual(manager.recommendationUpcomingCountForTesting, 1)
    }

    func testQueueAdvancementPreservesRemainingOccurrenceProvenance() {
        let manager = makeRecommendationManager(
            upcoming: [
                ("manual-a", SongIdentity(artist: "Manual Artist", title: "Manual A")),
                ("automatic-c", SongIdentity(artist: "Automatic Artist", title: "Automatic C")),
                ("automatic-d", SongIdentity(artist: "Automatic Artist", title: "Automatic D"))
            ],
            manualQueueCount: 1
        )
        manager.moveQueue(from: IndexSet(integer: 1), to: 0)

        manager.nextTrack()

        XCTAssertEqual(manager.queue[manager.currentIndex!].youtubeVideoID, "automatic-c")
        XCTAssertEqual(
            manager.upcomingQueueTracks.map(\.youtubeVideoID),
            ["manual-a", "automatic-d"]
        )
        XCTAssertEqual(manager.manualQueueCount, 1)
        XCTAssertEqual(manager.recommendationUpcomingCountForTesting, 1)
    }

    func testStopClearsQueueOccurrenceProvenance() {
        let current = makeTrack(id: "current")
        let manager = makeManager(tracks: [current])
        manager.playNext(makeTrack(id: "manual"))
        XCTAssertEqual(manager.manualQueueCount, 1)

        manager.stop()

        XCTAssertTrue(manager.queue.isEmpty)
        XCTAssertTrue(manager.upcomingQueueTracks.isEmpty)
        XCTAssertEqual(manager.manualQueueCount, 0)
        XCTAssertEqual(manager.recommendationUpcomingCountForTesting, 0)
    }

    func testRecommendationRefillCountAfterReorderUsesOccurrenceProvenance() {
        let manager = makeRecommendationManager(
            upcoming: [
                ("manual-a", SongIdentity(artist: "Manual Artist", title: "Manual A")),
                ("automatic-c", SongIdentity(artist: "Automatic Artist", title: "Automatic C")),
                ("automatic-d", SongIdentity(artist: "Automatic Artist", title: "Automatic D"))
            ],
            manualQueueCount: 1
        )

        manager.moveQueue(from: IndexSet(integer: 1), to: 0)

        XCTAssertEqual(
            manager.upcomingQueueTracks.map(\.youtubeVideoID),
            ["automatic-c", "manual-a", "automatic-d"]
        )
        XCTAssertEqual(manager.manualQueueCount, 1)
        XCTAssertEqual(manager.recommendationUpcomingCountForTesting, 2)
    }

    private func makeRecommendationManager(
        upcoming: [(videoID: String, identity: SongIdentity)],
        manualQueueCount: Int
    ) -> PlaybackManager {
        let current = makeTrack(id: "current")
        let tracks = [current] + upcoming.map { makeTrack(id: $0.videoID) }
        let manager = PlaybackManager()
        manager.seedRecommendationQueueForTesting(
            tracks: tracks,
            currentIndex: 0,
            manualQueueCount: manualQueueCount,
            identitiesByVideoID: Dictionary(
                uniqueKeysWithValues: upcoming.map { ($0.videoID, $0.identity) }
            )
        )
        return manager
    }

    private func recordArtistExclusion(
        _ identity: SongIdentity,
        on manager: PlaybackManager
    ) {
        RecommendationFeedbackStore.shared.clearAll()
        manager.recordRecommendationFeedback(.dontRecommendArtist, for: identity)
        RecommendationFeedbackStore.shared.clearAll()
    }

    private func makeResolvedRecommendation(
        artist: String,
        title: String,
        videoID: String
    ) -> ResolvedRecommendation {
        ResolvedRecommendation(
            artist: artist,
            title: title,
            match: 0.9,
            youtubeResult: YouTubeSearchResult(
                youtubeVideoID: videoID,
                title: "\(artist) - \(title)",
                channelTitle: artist,
                thumbnailURL: nil,
                duration: 180
            )
        )
    }
}
