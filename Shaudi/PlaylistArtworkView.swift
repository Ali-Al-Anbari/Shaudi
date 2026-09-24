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
                    playlistCover(cover, in: geometry.size)
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
    private func playlistCover(
        _ cover: PlaylistCoverMedia,
        in viewportSize: CGSize
    ) -> some View {
        switch cover {
        case .image(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        case .animatedGIF(let image, let crop):
#if DEBUG
            let _ = print(
                "[PlaylistArtworkView] .animatedGIF"
                    + " frames=\(image.images?.count ?? 0)"
                    + " reduceMotion=\(reduceMotion)"
                    + " viewport=\(viewportSize)"
            )
#endif
            let baseSize = baseImageSize(for: image.size, in: viewportSize)
            let effectiveScale = max(1, crop.scale)
            let scaledSize = CGSize(
                width: baseSize.width * effectiveScale,
                height: baseSize.height * effectiveScale
            )
            let offset = clampedOffset(
                for: crop,
                scaledSize: scaledSize,
                viewportSize: viewportSize
            )

            AnimatedPlaylistCoverImage(
                image: image,
                showsFirstFrameOnly: reduceMotion
            )
            .frame(width: baseSize.width, height: baseSize.height)
            .scaleEffect(effectiveScale)
            .offset(offset)
            .frame(width: viewportSize.width, height: viewportSize.height)
            .clipped()
        }
    }

    private func baseImageSize(
        for imageSize: CGSize,
        in viewportSize: CGSize
    ) -> CGSize {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return .zero
        }
        let imageAspectRatio = imageSize.width / max(1, imageSize.height)
        let viewportAspectRatio = viewportSize.width / max(1, viewportSize.height)

        if imageAspectRatio > viewportAspectRatio {
            return CGSize(
                width: viewportSize.height * imageAspectRatio,
                height: viewportSize.height
            )
        } else {
            return CGSize(
                width: viewportSize.width,
                height: viewportSize.width / max(imageAspectRatio, 0.001)
            )
        }
    }

    private func clampedOffset(
        for crop: ArtworkCrop,
        scaledSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        let proposedOffset = CGSize(
            width: crop.normalizedOffsetX * viewportSize.width,
            height: crop.normalizedOffsetY * viewportSize.height
        )
        let maximumX = max(0, (scaledSize.width - viewportSize.width) / 2)
        let maximumY = max(0, (scaledSize.height - viewportSize.height) / 2)

        return CGSize(
            width: min(max(proposedOffset.width, -maximumX), maximumX),
            height: min(max(proposedOffset.height, -maximumY), maximumY)
        )
    }

    private var placeholder: some View {
        Image(systemName: "rectangle.stack.fill")
            .font(.title2)
            .foregroundStyle(ShaudiTheme.accent)
    }
}

struct AnimatedPlaylistCoverImage: UIViewRepresentable {
    let image: UIImage
    let showsFirstFrameOnly: Bool

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
#if DEBUG
        print(
            "[AnimatedPlaylistCoverImage] makeUIView"
                + " frames=\(image.images?.count ?? 0)"
                + " showsFirstFrameOnly=\(showsFirstFrameOnly)"
                + " window=\(imageView.window != nil)"
        )
#endif
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
#if DEBUG
        print(
            "[AnimatedPlaylistCoverImage] updateUIView"
                + " frames=\(image.images?.count ?? 0)"
                + " showsFirstFrameOnly=\(showsFirstFrameOnly)"
                + " window=\(imageView.window != nil)"
                + " isAnimating=\(imageView.isAnimating)"
                + " existingFrames=\(imageView.animationImages?.count ?? 0)"
        )
#endif
        let frames = image.images
        if !showsFirstFrameOnly, let frames, frames.count > 1 {
            // Use the UIImageView animation API — setting UIImage.animatedImage on
            // the .image property does NOT reliably start animation in UIKit.
            if imageView.animationImages?.count != frames.count
                || imageView.animationImages?.first !== frames.first
            {
                imageView.animationImages = frames
                imageView.animationDuration = image.duration
                imageView.image = frames.first
#if DEBUG
                print("[AnimatedPlaylistCoverImage] → assigned animationImages, calling startAnimating, window=\(imageView.window != nil)")
#endif
            }
            if !imageView.isAnimating {
                imageView.startAnimating()
#if DEBUG
                print("[AnimatedPlaylistCoverImage] → startAnimating called, window=\(imageView.window != nil), isAnimating after=\(imageView.isAnimating)")
#endif
            }
        } else {
            // Static or reduce-motion: show the first frame (or the image itself).
            let stillImage = frames?.first ?? image
            if imageView.image !== stillImage {
                imageView.image = stillImage
            }
            if imageView.isAnimating {
                imageView.stopAnimating()
            }
            if imageView.animationImages != nil {
                imageView.animationImages = nil
            }
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
        imageView.animationImages = nil
        imageView.image = nil
    }
}
