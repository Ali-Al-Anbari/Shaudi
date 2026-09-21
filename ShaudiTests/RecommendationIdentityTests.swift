//
//  RecommendationIdentityTests.swift
//  ShaudiTests
//

import XCTest
@testable import Shaudi

@MainActor
final class RecommendationIdentityTests: XCTestCase {
    func testParamoreOfficialVideoIdentity() {
        let seed = manualSeed(
            title: "Paramore - That's What You Get [OFFICIAL VIDEO]",
            channel: "Paramore"
        )

        XCTAssertEqual(seed.cleanedArtist, "Paramore")
        XCTAssertEqual(seed.cleanedTitle, "That's What You Get")
    }

    func testShakiraLyricsUploadUsesMusicalIdentity() {
        let seed = manualSeed(
            title: "Shakira - Hips Don't Lie (Lyrics) ft. Wyclef Jean",
            channel: "7clouds Rock"
        )

        XCTAssertEqual(seed.cleanedArtist, "Shakira")
        XCTAssertEqual(seed.cleanedTitle, "Hips Don't Lie")
        XCTAssertEqual(seed.fallbackTitle, "Hips Don't Lie ft. Wyclef Jean")
    }

    func testBanditUsesTitleArtistInsteadOfUploader() {
        let seed = manualSeed(
            title: "Juice WRLD - Bandit ft. NBA Youngboy (Official Music Video)",
            channel: "Lyrical Lemonade"
        )

        XCTAssertEqual(seed.cleanedArtist, "Juice WRLD")
        XCTAssertEqual(seed.cleanedTitle, "Bandit")
    }

    func testRealDeviceWainedSongFirstIdentityRejectsUploader() {
        let seed = manualSeed(
            title: "wained // lana del rey",
            channel: "melancholia"
        )

        XCTAssertEqual(seed.cleanedArtist, "Lana Del Rey")
        XCTAssertEqual(seed.cleanedTitle, "wained")
        XCTAssertEqual(seed.artistSource, .titleSongArtist)
        XCTAssertEqual(seed.identityConfidence, .high)
    }

    func testRealDeviceWayamayaCompactDashIdentityRejectsUploader() {
        let seed = manualSeed(
            title: "Lana Del Rey- Wayamaya",
            channel: "zumra del rey"
        )

        XCTAssertEqual(seed.cleanedArtist, "Lana Del Rey")
        XCTAssertEqual(seed.cleanedTitle, "Wayamaya")
        XCTAssertEqual(seed.artistSource, .titleArtistSong)
        XCTAssertEqual(seed.identityConfidence, .high)
    }

    func testArtistFirstDashSpacingVariants() {
        for title in [
            "Lana Del Rey - Wayamaya",
            "Lana Del Rey- Wayamaya",
            "Lana Del Rey -Wayamaya",
            "Lana Del Rey-Wayamaya"
        ] {
            let seed = manualSeed(title: title, channel: "Archive Uploader")
            XCTAssertEqual(seed.cleanedArtist, "Lana Del Rey", title)
            XCTAssertEqual(seed.cleanedTitle, "Wayamaya", title)
        }
    }

    func testArtistFirstUnicodeDashVariants() {
        for title in [
            "Lana Del Rey – Wayamaya",
            "Lana Del Rey–Wayamaya",
            "Lana Del Rey — Wayamaya",
            "Lana Del Rey—Wayamaya"
        ] {
            let seed = manualSeed(title: title, channel: "Archive Uploader")
            XCTAssertEqual(seed.cleanedArtist, "Lana Del Rey", title)
            XCTAssertEqual(seed.cleanedTitle, "Wayamaya", title)
        }
    }

    func testHyphenatedArtistNamesUseStructuralBoundary() {
        let blink = manualSeed(
            title: "blink-182 - All the Small Things",
            channel: "Fan Archive"
        )
        let jayZ = manualSeed(
            title: "Jay-Z - 99 Problems",
            channel: "Fan Archive"
        )

        XCTAssertEqual(blink.cleanedArtist, "blink-182")
        XCTAssertEqual(blink.cleanedTitle, "All the Small Things")
        XCTAssertEqual(jayZ.cleanedArtist, "Jay-Z")
        XCTAssertEqual(jayZ.cleanedTitle, "99 Problems")
    }

    func testSongFirstSeparatorsResolveArtistOnRight() {
        for title in [
            "West Coast // Lana Del Rey",
            "West Coast | Lana Del Rey",
            "West Coast • Lana Del Rey",
            "West Coast by Lana Del Rey"
        ] {
            let seed = manualSeed(title: title, channel: "melancholia")
            XCTAssertEqual(seed.cleanedArtist, "Lana Del Rey", title)
            XCTAssertEqual(seed.cleanedTitle, "West Coast", title)
            XCTAssertEqual(seed.artistSource, .titleSongArtist, title)
        }
    }

    func testColonArtistFirstPattern() {
        let seed = manualSeed(
            title: "Lana Del Rey: West Coast",
            channel: "Archive"
        )

        XCTAssertEqual(seed.cleanedArtist, "Lana Del Rey")
        XCTAssertEqual(seed.cleanedTitle, "West Coast")
    }

    func testChannelAgreementCanResolveAmbiguousDashAsSongFirst() {
        let seed = manualSeed(
            title: "West Coast - Lana Del Rey",
            channel: "Lana Del Rey"
        )

        XCTAssertEqual(seed.cleanedArtist, "Lana Del Rey")
        XCTAssertEqual(seed.cleanedTitle, "West Coast")
        XCTAssertEqual(seed.artistSource, .titleSongArtist)
        XCTAssertEqual(seed.identityConfidence, .high)
    }

    func testStructuredArtistMetadataOutranksConflictingTitleAndUploader() {
        let seed = RecommendationSeed(
            youtubeVideoID: "structured1",
            rawTitle: "Wrong Artist - West Coast",
            displayedArtist: "Uploader",
            sourceChannel: "Uploader",
            userArtistOverride: nil,
            structuredArtist: "Lana Del Rey"
        )

        XCTAssertEqual(seed.cleanedArtist, "Lana Del Rey")
        XCTAssertEqual(seed.artistSource, .structuredArtist)
        XCTAssertEqual(seed.identityConfidence, .high)
    }

    func testVEVOChannelProvidesConservativeHighConfidenceArtist() {
        let seed = manualSeed(title: "West Coast", channel: "LanaDelReyVEVO")

        XCTAssertEqual(seed.cleanedArtist, "Lana Del Rey")
        XCTAssertEqual(seed.cleanedTitle, "West Coast")
        XCTAssertEqual(seed.artistSource, .vevoChannel)
        XCTAssertEqual(seed.identityConfidence, .high)
    }

    func testFanUploaderDoesNotBecomeCanonicalArtist() {
        let seed = manualSeed(title: "West Coast", channel: "melancholia")

        XCTAssertEqual(seed.cleanedArtist, "")
        XCTAssertEqual(seed.cleanedTitle, "West Coast")
        XCTAssertEqual(seed.artistSource, .channelFallback)
        XCTAssertEqual(seed.identityConfidence, .low)
        XCTAssertNil(seed.confidentSongIdentityForCaching)
    }

    func testOfficialLabelsArePresentationOnlyDuringIdentityResolution() {
        for title in [
            "Lana Del Rey - West Coast (Official Audio)",
            "Lana Del Rey - West Coast [Official Video]"
        ] {
            let seed = manualSeed(title: title, channel: "Uploader")
            XCTAssertEqual(seed.cleanedArtist, "Lana Del Rey", title)
            XCTAssertEqual(seed.cleanedTitle, "West Coast", title)
        }
    }

    func testFeatureAndProducerCreditsNeverBecomePrimaryArtist() {
        let featured = manualSeed(
            title: "Artist - Song (feat. Guest)",
            channel: "Uploader"
        )
        let produced = manualSeed(
            title: "Artist - Song (prod. Producer)",
            channel: "Uploader"
        )
        let producedDash = manualSeed(
            title: "Artist - Song - Produced by Producer",
            channel: "Uploader"
        )

        XCTAssertEqual(featured.cleanedArtist, "Artist")
        XCTAssertEqual(featured.cleanedTitle, "Song")
        XCTAssertEqual(produced.cleanedArtist, "Artist")
        XCTAssertEqual(produced.cleanedTitle, "Song")
        XCTAssertEqual(producedDash.cleanedArtist, "Artist")
        XCTAssertEqual(producedDash.cleanedTitle, "Song")
    }

    func testCollaborativeArtistStringsRemainIntact() {
        for artist in ["Artist A & Artist B", "Artist A x Artist B"] {
            let seed = manualSeed(title: "\(artist) - Song", channel: "Uploader")
            XCTAssertEqual(seed.cleanedArtist, artist)
            XCTAssertEqual(seed.cleanedTitle, "Song")
        }
    }

    func testVersionMarkersDoNotCorruptArtistRecognition() {
        for version in [
            "Live", "Remix", "Demo", "Unreleased", "Leak", "Slowed", "Sped-Up"
        ] {
            let seed = manualSeed(
                title: "Lana Del Rey - West Coast (\(version))",
                channel: "Uploader"
            )
            XCTAssertEqual(seed.cleanedArtist, "Lana Del Rey", version)
            XCTAssertTrue(seed.cleanedTitle.contains("West Coast"), version)
        }
    }

    func testAmbiguousSingleWordDashIdentityIsNotPersistable() {
        let seed = manualSeed(title: "Midnight - Phoenix", channel: "Archive")

        XCTAssertEqual(seed.cleanedArtist, "Midnight")
        XCTAssertEqual(seed.cleanedTitle, "Phoenix")
        XCTAssertEqual(seed.identityConfidence, .medium)
        XCTAssertNil(seed.confidentSongIdentityForCaching)
    }

    func testManualSearchQueryCanStrengthenCompactSingleWordBoundary() {
        let seed = manualSeed(
            title: "Artist-Song",
            channel: "Archive",
            searchQuery: "artist song"
        )

        XCTAssertEqual(seed.cleanedArtist, "Artist")
        XCTAssertEqual(seed.cleanedTitle, "Song")
        XCTAssertEqual(seed.identityConfidence, .high)
    }

    func testFamousDexTrailingProductionCreditIsRemoved() {
        for credit in [
            "(Prod. JGramm)", "(prod. JGramm)",
            "(Produced by JGramm)", "[Prod. JGramm]"
        ] {
            let seed = manualSeed(
                title: "Famous Dex - Japan \(credit) [Official Lyric Video]",
                channel: "Famous Dex"
            )

            XCTAssertEqual(seed.cleanedArtist, "Famous Dex")
            XCTAssertEqual(seed.cleanedTitle, "Japan")
        }
    }

    func testProductionCleanupDoesNotStripMusicalVersions() {
        for version in [
            "Acoustic", "Remix", "Live", "Remastered 2011", "From \"Movie\""
        ] {
            let seed = manualSeed(
                title: "Artist - Song (\(version))",
                channel: "Artist"
            )
            XCTAssertEqual(seed.cleanedTitle, "Song (\(version))")
        }
    }

    func testLastFMIdentityIsNotReparsed() {
        let seed = RecommendationSeed(
            youtubeVideoID: "abcdefghijk",
            canonicalIdentity: SongIdentity(
                artist: "Lil Peep",
                title: "Falling Down - Bonus Track"
            ),
            youtubeTitle: "Falling Down - Bonus Track",
            youtubeChannel: "Lil Peep"
        )

        XCTAssertEqual(seed.cleanedArtist, "Lil Peep")
        XCTAssertEqual(seed.cleanedTitle, "Falling Down - Bonus Track")
        XCTAssertEqual(seed.artistSource, .lastFM)
    }

    func testLastFMIdentityRemainsAuthoritativeThroughConfirmedPlayback() {
        var session = RecommendationRadioSession(anchor: banditSeed())
        for index in 1..<RecommendationRadioPolicy.epochLength {
            _ = session.confirmedRecommendationPlayback(seed: canonicalSeed(index: index))
        }
        let fallingDown = RecommendationSeed(
            youtubeVideoID: "falling0001",
            canonicalIdentity: SongIdentity(
                artist: "Lil Peep",
                title: "Falling Down - Bonus Track"
            ),
            youtubeTitle: "Lil Peep & XXXTENTACION - Falling Down (Official Video)",
            youtubeChannel: "Lil Peep"
        )

        guard case .startNewEpoch(_, let anchor) =
            session.confirmedRecommendationPlayback(seed: fallingDown) else {
            return XCTFail("Expected the confirmed track to become the next epoch anchor")
        }
        XCTAssertEqual(anchor.cleanedArtist, "Lil Peep")
        XCTAssertEqual(anchor.cleanedTitle, "Falling Down - Bonus Track")
        XCTAssertEqual(anchor.artistSource, .lastFM)
    }

    func testTopicChannelSuffixIsRemoved() {
        let seed = manualSeed(title: "A Song", channel: "Artist Name - Topic")

        XCTAssertEqual(seed.cleanedArtist, "Artist Name")
        XCTAssertEqual(seed.cleanedTitle, "A Song")
        XCTAssertEqual(seed.artistSource, .topicChannel)
    }

    func testCanonicalTitleContainingHyphenIsPreserved() {
        let seed = RecommendationSeed(
            youtubeVideoID: "abcdefghijk",
            canonicalIdentity: SongIdentity(
                artist: "An Artist",
                title: "Part One - Part Two"
            ),
            youtubeTitle: "Part One - Part Two",
            youtubeChannel: "An Artist"
        )

        XCTAssertEqual(seed.cleanedArtist, "An Artist")
        XCTAssertEqual(seed.cleanedTitle, "Part One - Part Two")
    }

    func testExplicitArtistOverridePreventsHyphenReparse() {
        let seed = RecommendationSeed(
            youtubeVideoID: "abcdefghijk",
            rawTitle: "Falling Down - Bonus Track",
            displayedArtist: "Uploader",
            sourceChannel: "Uploader",
            userArtistOverride: "Lil Peep"
        )

        XCTAssertEqual(seed.cleanedArtist, "Lil Peep")
        XCTAssertEqual(seed.cleanedTitle, "Falling Down - Bonus Track")
        XCTAssertEqual(seed.artistSource, .userOverride)
    }

    func testOfficialAudioAndVisualizerArePresentationOnly() {
        XCTAssertEqual(
            manualSeed(title: "Artist - Song (Official Audio)", channel: "Uploader").cleanedTitle,
            "Song"
        )
        XCTAssertEqual(
            manualSeed(title: "Artist - Song [Visualizer]", channel: "Uploader").cleanedTitle,
            "Song"
        )
    }

    func testFeaturedArtistProducesOneBoundedAlternate() {
        let seed = manualSeed(
            title: "Artist - Song feat. Guest",
            channel: "Uploader"
        )

        XCTAssertEqual(seed.cleanedTitle, "Song")
        XCTAssertEqual(seed.fallbackTitle, "Song feat. Guest")
        XCTAssertEqual(
            SongNormalization.baseTitle("Song (feat. Guest)"),
            SongNormalization.baseTitle("Song")
        )
    }

    func testHTMLEntitiesAndTypographyNormalizeForIdentity() {
        let html = SongIdentity(artist: "Guns N&#39; Roses", title: "Don&#39;t Cry")
        let unicode = SongIdentity(artist: "Guns N’ Roses", title: "Don’t Cry")

        XCTAssertEqual(html.artist, "Guns N' Roses")
        XCTAssertEqual(html, unicode)
        XCTAssertEqual(
            manualSeed(title: "Artist — Song [4K]", channel: "Uploader").cleanedTitle,
            "Song"
        )
    }

    func testTrackNotFoundPermitsOnlyBoundedSeedFallback() {
        let error = LastFMRecommendationService.ServiceError.api(
            code: 6,
            message: "Track not found"
        )
        let networkError = LastFMRecommendationService.ServiceError.network("offline")

        XCTAssertTrue(error.permitsAlternateSeedRetry)
        XCTAssertFalse(networkError.permitsAlternateSeedRetry)
    }

    func testYouTubeCanonicalMatchMissingIsRejected() {
        let wrongSong = YouTubeSearchResult(
            youtubeVideoID: "abcdefghijk",
            title: "Artist - Completely Different Song (Official Video)",
            channelTitle: "Artist",
            thumbnailURL: nil
        )
        let target = LastFMSimilarTrack(
            artist: "Artist",
            title: "Wanted Song",
            match: 1,
            url: nil
        )

        XCTAssertNil(RecommendationService().youtubeScore(wrongSong, target: target))
    }

    func testHarmlessYouTubeFormattingStillMatchesCanonicalSong() {
        let result = YouTubeSearchResult(
            youtubeVideoID: "abcdefghijk",
            title: "Guns N’ Roses – Sweet Child O&#39; Mine (Official 4K Video)",
            channelTitle: "Guns N' Roses",
            thumbnailURL: nil
        )
        let target = LastFMSimilarTrack(
            artist: "Guns N' Roses",
            title: "Sweet Child O' Mine",
            match: 1,
            url: nil
        )

        XCTAssertNotNil(RecommendationService().youtubeScore(result, target: target))
    }

}
