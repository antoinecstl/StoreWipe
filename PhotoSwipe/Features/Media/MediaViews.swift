import AVKit
import Photos
import PhotoSwipeCore
import SwiftUI

/// Pastille d'information d'un élément : durée pour une vidéo, taille si elle est connue.
struct MediaBadge: View {
    let asset: AssetSummary

    var body: some View {
        if let text {
            HStack(spacing: 4) {
                if asset.mediaKind == .video {
                    Image(systemName: "video.fill")
                        .accessibilityHidden(true)
                }
                Text(verbatim: text)
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: accessibilityText))
        }
    }

    private var text: String? {
        var parts: [String] = []
        if asset.mediaKind == .video, let duration = asset.duration {
            parts.append(DisplayFormat.duration(duration))
        }
        if let bytes = asset.byteSize {
            parts.append(DisplayFormat.byteCount(bytes))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        let kind = asset.mediaKind == .video ? String(localized: "Vidéo") : String(localized: "Photo")
        return [kind, text].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Lecture plein écran d'une vidéo de la photothèque (le téléchargement iCloud suit le réglage d'affichage).
struct VideoPlayerScreen: View {
    let id: AssetID

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
            } else if didFail {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Lecture impossible")
                        .font(.headline)
                    Text("La vidéo n'est peut-être pas sur cet iPhone. Activez le téléchargement iCloud dans les Réglages pour la lire.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(32)
            } else {
                ProgressView().tint(.white)
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
        .task {
            await load()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func load() async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject else {
            didFail = true
            return
        }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = environment.settings.allowsNetworkForDisplay
        options.deliveryMode = .automatic
        let item: AVPlayerItem? = await withCheckedContinuation { continuation in
            let gate = ResumeOnce()
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                guard gate.claim() else { return }
                continuation.resume(returning: item)
            }
        }
        if let item {
            player = AVPlayer(playerItem: item)
        } else {
            didFail = true
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
