import PhotoSwipeCore
import SwiftUI

/// Aperçu plein écran d'une photo ou d'une vidéo, sans rien décider.
struct MediaPreviewScreen: View {
    let asset: AssetSummary

    var body: some View {
        if asset.mediaKind == .video {
            VideoPlayerScreen(id: asset.id)
        } else {
            PhotoPreviewScreen(id: asset.id)
        }
    }
}

/// Photo en plein écran : pincement pour zoomer, glissement pour déplacer, double touche pour revenir.
struct PhotoPreviewScreen: View {
    let id: AssetID

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private static let maximumScale: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                AssetImageView(id: id, pointSize: proxy.size, zoomFactor: scale > 1.5 ? 2.5 : 1)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnify)
                    .simultaneousGesture(pan)
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.3)) { reset() }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .padding(16)
            }
            .accessibilityLabel(Text("Fermer"))
        }
        .statusBarHidden()
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(baseScale * value.magnification, 1), Self.maximumScale)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1.01 { reset() }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.01 else { return }
                offset = CGSize(
                    width: baseOffset.width + value.translation.width,
                    height: baseOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}
