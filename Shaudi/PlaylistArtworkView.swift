//
//  PlaylistArtworkView.swift
//  Shaudi
//

import SwiftUI
import UIKit

struct PlaylistArtworkView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let playlist: Playlist

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ShaudiTheme.dashboardCard

                if
                    let artworkID = playlist.artworkID,
                    let cover = ArtworkStorage.playlistCover(for: artworkID)
                {
                    playlistCover(cover)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else if let thumbnailURL = playlist.tracksInPlaybackOrder
                    .first?.thumbnailURL
                {
                    AsyncImage(url: thumbnailURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private func playlistCover(_ cover: PlaylistCoverMedia) -> some View {
        switch cover {
        case .image(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        case .animatedGIF(let image):
            AnimatedPlaylistCoverImage(
                image: image,
                showsFirstFrameOnly: reduceMotion
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var placeholder: some View {
        Image(systemName: "rectangle.stack.fill")
            .font(.title2)
            .foregroundStyle(ShaudiTheme.accent)
    }
}

private struct AnimatedPlaylistCoverImage: UIViewRepresentable {
    let image: UIImage
    let showsFirstFrameOnly: Bool

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        let displayedImage = showsFirstFrameOnly ? (image.images?.first ?? image) : image
        if imageView.image !== displayedImage {
            imageView.image = displayedImage
        }

        if showsFirstFrameOnly {
            imageView.stopAnimating()
        } else {
            imageView.startAnimating()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIImageView,
        context: Context
    ) -> CGSize {
        CGSize(
            width: proposal.width ?? image.size.width,
            height: proposal.height ?? image.size.height
        )
    }

    static func dismantleUIView(_ imageView: UIImageView, coordinator: ()) {
        imageView.stopAnimating()
        imageView.image = nil
    }
}
