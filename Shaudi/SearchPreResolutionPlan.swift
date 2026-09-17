//
//  SearchPreResolutionPlan.swift
//  Shaudi
//

import Foundation

struct SearchPreResolutionCandidate: Equatable {
    let videoID: String
    let duration: TimeInterval?
    let rank: Int
}

enum SearchPreResolutionPlan {
    static let maximumCandidates = 3

    static func candidates(
        from results: [YouTubeSearchResult]
    ) -> [SearchPreResolutionCandidate] {
        var seenVideoIDs: Set<String> = []
        var candidates: [SearchPreResolutionCandidate] = []

        for result in results {
            let videoID = result.youtubeVideoID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !videoID.isEmpty, seenVideoIDs.insert(videoID).inserted else {
                continue
            }

            candidates.append(
                SearchPreResolutionCandidate(
                    videoID: videoID,
                    duration: result.duration,
                    rank: candidates.count + 1
                )
            )
            if candidates.count == maximumCandidates {
                break
            }
        }

        return candidates
    }

    static func obsoleteVideoIDs(
        previous: Set<String>,
        retaining requested: Set<String>,
        nonSpeculative: Set<String>,
        activePlayback: Set<String>
    ) -> Set<String> {
        previous
            .subtracting(requested)
            .subtracting(nonSpeculative)
            .subtracting(activePlayback)
    }
}
