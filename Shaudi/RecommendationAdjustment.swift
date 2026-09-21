import Foundation

/// The preference contribution shared by Radio and playlist ranking.
struct RecommendationAdjustment {
    let explicit: Double
    let passive: RecommendationPersonalizationAdjustment
    let combined: Double

    init(
        identity: SongIdentity,
        feedback: RecommendationFeedbackSnapshot,
        personalization: RecommendationPersonalizationProfile
    ) {
        let explicit = feedback.scoreAdjustment(for: identity)
        let passive = personalization.adjustment(for: identity)
        self.explicit = explicit
        self.passive = passive

        // Passive evidence may refine explicit intent, but cannot reverse it.
        // Opposing passive evidence can offset at most half of an explicit signal.
        if explicit > 0, passive.total < 0 {
            combined = explicit + max(passive.total, -explicit / 2)
        } else if explicit < 0, passive.total > 0 {
            combined = explicit + min(passive.total, -explicit / 2)
        } else {
            combined = explicit + passive.total
        }
    }
}
