//
//  ImageCropEditor.swift
//  Shaudi
//

import SwiftUI
import UIKit

struct ImageCropEditor: View {
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let title: String
    let cropAspectRatio: CGFloat
    let outputSize: CGSize
    let cornerRadius: CGFloat
    var onSave: ((UIImage) -> Void)? = nil
    var onSaveCrop: ((ArtworkCrop) -> Void)? = nil

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero

    private let maximumScale: CGFloat = 5

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let viewportSize = cropSize(in: geometry.size)
                let effectiveScale = clampedScale(scale * gestureScale)
                let effectiveOffset = clampedOffset(
                    CGSize(
                        width: offset.width + dragTranslation.width,
                        height: offset.height + dragTranslation.height
                    ),
                    scale: effectiveScale,
                    viewportSize: viewportSize
                )
                let imageSize = baseImageSize(for: viewportSize)

                VStack(spacing: 20) {
                    Spacer(minLength: 12)

                    Group {
                        if image.images != nil {
                            AnimatedPlaylistCoverImage(
                                image: image,
                                showsFirstFrameOnly: false
                            )
                        } else {
                            Image(uiImage: image)
                                .resizable()
                                .interpolation(.high)
                        }
                    }
                    .frame(width: imageSize.width, height: imageSize.height)
                    .scaleEffect(effectiveScale)
                    .offset(effectiveOffset)
                    .frame(width: viewportSize.width, height: viewportSize.height)
                    .clipped()
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: cornerRadius,
                            style: .continuous
                        )
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        dragGesture(viewportSize: viewportSize)
                            .simultaneously(with: magnificationGesture(viewportSize: viewportSize))
                    )

                    Text("Drag and pinch to position your photo")
                        .font(ShaudiTheme.bodyFont(size: 16))
                        .foregroundStyle(ShaudiTheme.dashboardSecondaryText)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let finalOffset = clampedOffset(
                                offset,
                                scale: scale,
                                viewportSize: viewportSize
                            )
                            if let onSaveCrop {
                                let crop = ArtworkCrop(
                                    scale: scale,
                                    normalizedOffsetX: viewportSize.width > 0
                                        ? finalOffset.width / viewportSize.width
                                        : 0,
                                    normalizedOffsetY: viewportSize.height > 0
                                        ? finalOffset.height / viewportSize.height
                                        : 0
                                )
                                onSaveCrop(crop)
                            } else if let onSave {
                                onSave(
                                    renderCroppedImage(
                                        viewportSize: viewportSize,
                                        scale: scale,
                                        offset: finalOffset
                                    )
                                )
                            }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .background(ShaudiTheme.dashboardBackground)
        }
        .presentationDragIndicator(.visible)
    }

    private func cropSize(in availableSize: CGSize) -> CGSize {
        let maximumWidth = max(1, availableSize.width - 32)
        let maximumHeight = max(1, availableSize.height - 100)
        let widthForMaximumHeight = maximumHeight * cropAspectRatio

        if widthForMaximumHeight < maximumWidth {
            return CGSize(width: widthForMaximumHeight, height: maximumHeight)
        }

        return CGSize(width: maximumWidth, height: maximumWidth / cropAspectRatio)
    }

    private func baseImageSize(for viewportSize: CGSize) -> CGSize {
        let imageAspectRatio = image.size.width / max(1, image.size.height)

        if imageAspectRatio > cropAspectRatio {
            return CGSize(
                width: viewportSize.height * imageAspectRatio,
                height: viewportSize.height
            )
        }

        return CGSize(
            width: viewportSize.width,
            height: viewportSize.width / max(imageAspectRatio, 0.001)
        )
    }

    private func clampedScale(_ proposedScale: CGFloat) -> CGFloat {
        min(max(proposedScale, 1), maximumScale)
    }

    private func clampedOffset(
        _ proposedOffset: CGSize,
        scale: CGFloat,
        viewportSize: CGSize
    ) -> CGSize {
        let imageSize = baseImageSize(for: viewportSize)
        let maximumX = max(0, (imageSize.width * scale - viewportSize.width) / 2)
        let maximumY = max(0, (imageSize.height * scale - viewportSize.height) / 2)

        return CGSize(
            width: min(max(proposedOffset.width, -maximumX), maximumX),
            height: min(max(proposedOffset.height, -maximumY), maximumY)
        )
    }

    private func dragGesture(viewportSize: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset = clampedOffset(
                    CGSize(
                        width: offset.width + value.translation.width,
                        height: offset.height + value.translation.height
                    ),
                    scale: scale,
                    viewportSize: viewportSize
                )
            }
    }

    private func magnificationGesture(viewportSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($gestureScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                scale = clampedScale(scale * value)
                offset = clampedOffset(
                    offset,
                    scale: scale,
                    viewportSize: viewportSize
                )
            }
    }

    private func renderCroppedImage(
        viewportSize: CGSize,
        scale: CGFloat,
        offset: CGSize
    ) -> UIImage {
        let imageSize = baseImageSize(for: viewportSize)
        let renderedImageSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        let horizontalOutputScale = outputSize.width / viewportSize.width
        let verticalOutputScale = outputSize.height / viewportSize.height
        let drawRect = CGRect(
            x: ((viewportSize.width - renderedImageSize.width) / 2 + offset.width)
                * horizontalOutputScale,
            y: ((viewportSize.height - renderedImageSize.height) / 2 + offset.height)
                * verticalOutputScale,
            width: renderedImageSize.width * horizontalOutputScale,
            height: renderedImageSize.height * verticalOutputScale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: outputSize))
            image.draw(in: drawRect)
        }
    }
}
