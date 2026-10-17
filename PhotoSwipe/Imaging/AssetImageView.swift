import PhotoSwipeCore
import SwiftUI
import UIKit

/// Affiche une photo de la photothèque à la résolution de sa zone d'affichage.
/// Gère la récupération iCloud (visible et contrôlée) et les photos devenues introuvables.
struct AssetImageView: View {
    let id: AssetID
    let pointSize: CGSize
    var zoomFactor: CGFloat = 1
    var onUnavailable: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var imageID: AssetID?
    @State private var isDegraded = false
    @State private var status: Status = .loading
    @State private var downloadProgress: Double?
    @State private var allowsNetworkOnce = false

    private enum Status {
        case loading
        case loaded
        case requiresNetwork
        case unavailable
        case failed
    }

    private struct RequestKey: Hashable {
        let id: AssetID
        let width: Int
        let height: Int
        let allowNetwork: Bool
    }

    var body: some View {
        ZStack {
            if let image, imageID == id {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
            }
            statusOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: requestKey) {
            await load()
        }
    }

    private var pixelSize: CGSize {
        DisplayGeometry.pixelSize(for: pointSize, scale: displayScale, zoomFactor: zoomFactor)
    }

    private var allowNetwork: Bool {
        environment.settings.allowsNetworkForDisplay || allowsNetworkOnce
    }

    private var requestKey: RequestKey {
        RequestKey(id: id, width: Int(pixelSize.width), height: Int(pixelSize.height), allowNetwork: allowNetwork)
    }

    private var hasImage: Bool { image != nil && imageID == id }

    @ViewBuilder
    private var statusOverlay: some View {
        switch status {
        case .loading:
            if !hasImage {
                ProgressView()
            } else if let downloadProgress {
                DownloadProgressBadge(progress: downloadProgress)
            }
        case .loaded:
            if isDegraded, let downloadProgress {
                DownloadProgressBadge(progress: downloadProgress)
            }
        case .requiresNetwork:
            if hasImage {
                VStack {
                    Spacer()
                    Button {
                        allowsNetworkOnce = true
                    } label: {
                        Label("Version réduite · Télécharger depuis iCloud", systemImage: "icloud.and.arrow.down")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 12)
                }
            } else {
                StatusMessage(
                    systemImage: "icloud.and.arrow.down",
                    title: "Photo stockée dans iCloud",
                    message: "Elle n'est pas disponible sur cet iPhone. Le téléchargement peut utiliser des données mobiles.",
                    actionTitle: "Télécharger",
                    action: { allowsNetworkOnce = true }
                )
            }
        case .unavailable:
            StatusMessage(
                systemImage: "photo.badge.exclamationmark",
                title: "Photo introuvable",
                message: "Elle a peut-être été supprimée ou n'est plus autorisée.",
                actionTitle: onUnavailable == nil ? nil : "Continuer",
                action: onUnavailable
            )
        case .failed:
            if !hasImage {
                StatusMessage(
                    systemImage: "exclamationmark.triangle",
                    title: "Affichage impossible",
                    message: "Cette photo ne peut pas être affichée pour le moment.",
                    actionTitle: nil,
                    action: nil
                )
            }
        }
    }

    private func load() async {
        guard pixelSize != .zero else { return }
        if imageID != id {
            image = nil
            isDegraded = false
        }
        status = .loading
        downloadProgress = nil
        let events = environment.images.images(for: id, targetPixelSize: pixelSize, allowNetwork: allowNetwork)
        for await event in events {
            switch event {
            case .progress(let value):
                downloadProgress = value
            case .image(let newImage, let degraded):
                image = newImage
                imageID = id
                isDegraded = degraded
                if !degraded {
                    status = .loaded
                    downloadProgress = nil
                }
            case .requiresNetwork:
                status = .requiresNetwork
            case .unavailable:
                status = .unavailable
            case .failed:
                status = hasImage ? .loaded : .failed
            }
        }
        if status == .loading {
            status = hasImage ? .loaded : .failed
        }
    }
}

private struct DownloadProgressBadge: View {
    let progress: Double

    var body: some View {
        VStack {
            Spacer()
            Label {
                Text("iCloud · \(Int((progress * 100).rounded())) %")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "icloud.and.arrow.down")
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, 12)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusMessage: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actionTitle: LocalizedStringKey?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
    }
}
