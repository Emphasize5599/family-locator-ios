import SwiftUI
import UIKit

/// "Move and Scale" for a new profile photo, like the Contacts app: the photo sits behind a circle; drag to
/// move it and pinch to zoom, then Choose. The photo always fills the circle, so there are never empty edges.
struct AvatarCropView: View {
    let image: UIImage
    let onChoose: (Data) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    /// Largest zoom, relative to "just fills the circle".
    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height) - 2 * Spacing.large
            let baseScale = max(diameter / image.size.width, diameter / image.size.height)
            let liveScale = clampedScale(scale * pinch)
            let liveOffset = clampedOffset(CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
                                           scale: liveScale, baseScale: baseScale, diameter: diameter)
            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .frame(width: image.size.width * baseScale * liveScale, height: image.size.height * baseScale * liveScale)
                    .offset(liveOffset)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                // Dim everything outside the circle, and outline the circle itself.
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .mask(
                        ZStack {
                            Rectangle()
                            Circle().frame(width: diameter, height: diameter).blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    )
                    .allowsHitTesting(false)
                Circle()
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
                    .frame(width: diameter, height: diameter)
                    .allowsHitTesting(false)

                VStack {
                    Text("Move and Scale")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.top, Spacing.large)
                    Spacer()
                    HStack {
                        Button("Cancel", action: onCancel).tint(.zoodYellow)
                        Spacer()
                        Button("Choose") {
                            if let jpeg = crop(scale: liveScale, offset: liveOffset, baseScale: baseScale, diameter: diameter) {
                                onChoose(jpeg)
                            }
                        }
                        .font(.body.weight(.semibold))
                    }
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(minHeight: 44)
                    .padding(.horizontal, Spacing.xLarge)
                    .padding(.bottom, Spacing.large)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { value in scale = clampedScale(scale * value) },
                    DragGesture()
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            offset = clampedOffset(CGSize(width: offset.width + value.translation.width,
                                                          height: offset.height + value.translation.height),
                                                   scale: scale, baseScale: baseScale, diameter: diameter)
                        }
                )
            )
            .compatOnChange(of: scale) { _ in
                // Zooming out can leave an edge showing; pull the photo back so it still fills the circle.
                withAnimation(.easeOut(duration: 0.2)) {
                    offset = clampedOffset(offset, scale: scale, baseScale: baseScale, diameter: diameter)
                }
            }
        }
        .statusBarHidden()
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), maxScale)
    }

    /// Keeps the photo covering the whole circle.
    private func clampedOffset(_ proposed: CGSize, scale: CGFloat, baseScale: CGFloat, diameter: CGFloat) -> CGSize {
        let width = image.size.width * baseScale * scale
        let height = image.size.height * baseScale * scale
        let maxX = max(0, (width - diameter) / 2)
        let maxY = max(0, (height - diameter) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    /// The square of the photo under the circle, as a 256×256 JPEG (the size Zood avatars use).
    private func crop(scale: CGFloat, offset: CGSize, baseScale: CGFloat, diameter: CGFloat) -> Data? {
        let pointsPerPixel = baseScale * scale
        let displayed = CGSize(width: image.size.width * pointsPerPixel, height: image.size.height * pointsPerPixel)
        let side = diameter / pointsPerPixel
        let origin = CGPoint(x: ((displayed.width - diameter) / 2 - offset.width) / pointsPerPixel,
                             y: ((displayed.height - diameter) / 2 - offset.height) / pointsPerPixel)
        let output: CGFloat = 256
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let result = UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format).image { _ in
            let factor = output / side
            image.draw(in: CGRect(x: -origin.x * factor, y: -origin.y * factor,
                                  width: image.size.width * factor, height: image.size.height * factor))
        }
        return result.jpegData(compressionQuality: 0.8)
    }
}
