//
//  ManualTrackAdditionView.swift
//  Shaudi
//

import SwiftData
import SwiftUI

struct ManualTrackAdditionView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var tracks: [Track]

    var body: some View {
        TrackEditorView(
            title: "New Track",
            actionTitle: "Create"
        ) { request in
            guard !tracks.contains(where: { $0.youtubeVideoID == request.youtubeVideo.id }) else {
                return "This YouTube video is already in Library."
            }

            guard let metadata = request.metadata else {
                return "Fetch the YouTube metadata before creating this track."
            }

            let track = Track(
                title: metadata.title,
                youtubeURL: request.youtubeVideo.url,
                youtubeVideoID: request.youtubeVideo.id,
                channelTitle: metadata.channelTitle,
                thumbnailURL: metadata.thumbnailURL,
                duration: metadata.duration,
                metadataLastRefreshed: .now
            )
            modelContext.insert(track)
            Task {
                await YouTubeResolutionKnowledgeTeacher.learnIfConfident(
                    videoID: request.youtubeVideo.id,
                    rawTitle: metadata.title,
                    displayedArtist: metadata.channelTitle,
                    sourceChannel: metadata.channelTitle,
                    userArtistOverride: nil,
                    metadata: YouTubeResolutionMetadata(
                        title: metadata.title,
                        channel: metadata.channelTitle,
                        thumbnailURL: metadata.thumbnailURL,
                        duration: metadata.duration
                    ),
                    source: .pastedURL
                )
            }

            return nil
        }
    }
}
